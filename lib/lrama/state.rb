# frozen_string_literal: true

require_relative "state/reduce"
require_relative "state/reduce_reduce_conflict"
require_relative "state/resolved_conflict"
require_relative "state/shift"
require_relative "state/shift_reduce_conflict"
require_relative "state/inadequacy_annotation"

module Lrama
  class State
    attr_reader :id, :accessing_symbol, :kernels, :conflicts, :resolved_conflicts,
                :default_reduction_rule, :closure, :items, :annotation_list, :predecessors
    attr_accessor :shifts, :reduces, :ielr_isocores, :lalr_isocore, :lookaheads_recomputed

    def initialize(id, accessing_symbol, kernels)
      @id = id
      @accessing_symbol = accessing_symbol
      @kernels = kernels.freeze
      @items = @kernels
      # Manage relationships between items to state
      # to resolve next state
      @items_to_state = {}
      @conflicts = []
      @resolved_conflicts = []
      @default_reduction_rule = nil
      @predecessors = []
      @lalr_isocore = self
      @ielr_isocores = [self]
      @internal_dependencies = {}
      @successor_dependencies = {}
      @always_follows = {}
      @annotation_list = []
      @lookaheads_recomputed = false
    end

    def closure=(closure)
      @closure = closure
      @items = @kernels + @closure
    end

    def non_default_reduces
      reduces.reject do |reduce|
        reduce.rule == @default_reduction_rule
      end
    end

    def compute_shifts_reduces
      _shifts = {}
      reduces = []
      items.each do |item|
        # TODO: Consider what should be pushed
        if item.end_of_rule?
          reduces << Reduce.new(item)
        else
          key = item.next_sym
          _shifts[key] ||= []
          _shifts[key] << item.new_by_next_position
        end
      end

      # It seems Bison 3.8.2 iterates transitions order by symbol number
      shifts = _shifts.sort_by do |next_sym, new_items|
        next_sym.number
      end.map do |next_sym, new_items|
        Shift.new(next_sym, new_items.flatten)
      end
      self.shifts = shifts.freeze
      self.reduces = reduces.freeze
    end

    def set_items_to_state(items, next_state)
      @items_to_state[items] = next_state
    end

    def set_look_ahead(rule, look_ahead)
      reduce = reduces.find do |r|
        r.rule == rule
      end

      reduce.look_ahead = look_ahead
    end

    def nterm_transitions
      @nterm_transitions ||= transitions.select {|shift, _| shift.next_sym.nterm? }
    end

    def term_transitions
      @term_transitions ||= transitions.select {|shift, _| shift.next_sym.term? }
    end

    def transitions
      @transitions ||= shifts.map {|shift| [shift, @items_to_state[shift.next_items]] }
    end

    def update_transition(shift, next_state)
      set_items_to_state(shift.next_items, next_state)
      next_state.append_predecessor(self)
      clear_transitions_cache
    end

    def clear_transitions_cache
      @nterm_transitions = nil
      @term_transitions = nil
      @transitions = nil
    end

    def selected_term_transitions
      term_transitions.reject do |shift, next_state|
        shift.not_selected
      end
    end

    # Move to next state by sym
    def transition(sym)
      result = nil

      if sym.term?
        term_transitions.each do |shift, next_state|
          term = shift.next_sym
          result = next_state if term == sym
        end
      else
        nterm_transitions.each do |shift, next_state|
          nterm = shift.next_sym
          result = next_state if nterm == sym
        end
      end

      raise "Can not transit by #{sym} #{self}" if result.nil?

      result
    end

    def find_reduce_by_item!(item)
      reduces.find do |r|
        r.item == item
      end || (raise "reduce is not found. #{item}")
    end

    def default_reduction_rule=(default_reduction_rule)
      @default_reduction_rule = default_reduction_rule

      reduces.each do |r|
        if r.rule == default_reduction_rule
          r.default_reduction = true
        end
      end
    end

    def has_conflicts?
      !@conflicts.empty?
    end

    def sr_conflicts
      @conflicts.select do |conflict|
        conflict.type == :shift_reduce
      end
    end

    def rr_conflicts
      @conflicts.select do |conflict|
        conflict.type == :reduce_reduce
      end
    end

    # Definition 3.40 (propagate_lookaheads)
    def propagate_lookaheads(next_state)
      next_state.kernels.map {|next_kernel|
        lookahead_sets =
          if next_kernel.position > 1
            kernel = kernels.find {|k| k.predecessor_item_of?(next_kernel) }
            item_lookahead_set[kernel]
          else
            goto_follow_set(next_kernel.lhs)
          end

        [next_kernel, lookahead_sets & next_state.lookahead_set_filters[next_kernel]]
      }.to_h
    end

    # Definition 3.43 (is_compatible)
    def is_compatible?(filtered_lookahead)
      !lookaheads_recomputed ||
        @lalr_isocore.annotation_list.all? {|annotation|
          a = annotation.dominant_contribution(item_lookahead_set)
          b = annotation.dominant_contribution(filtered_lookahead)
          a.nil? || b.nil? || a == b
        }
    end

    # Definition 3.38 (lookahead_set_filters)
    def lookahead_set_filters
      kernels.map {|kernel|
        [kernel, @lalr_isocore.annotation_list.select {|annotation| annotation.contributed?(kernel) }.map(&:token)]
      }.to_h
    end

    # Definition 3.27 (inadequacy_lists)
    def inadequacy_list
      return @inadequacy_list if @inadequacy_list

      @inadequacy_list = {}

      shifts.each do |shift|
        next unless shift.next_sym.term?

        @inadequacy_list[shift.next_sym] ||= []
        @inadequacy_list[shift.next_sym] << shift.dup
      end
      reduces.each do |reduce|
        next if reduce.look_ahead.nil?

        reduce.look_ahead.each do |token|
          @inadequacy_list[token] ||= []
          @inadequacy_list[token] << reduce.dup
        end
      end

      @inadequacy_list = @inadequacy_list.select {|token, actions| actions.size > 1 }
    end

    def annotate_manifestation
      inadequacy_list.each {|token, actions|
        contribution_matrix = actions.map {|action|
          if action.is_a?(Shift)
            [action, nil]
          else
            [action, action.rule.empty_rule? ? lhs_contributions(action.rule.lhs, token) : kernels.map {|k| [k, k.end_of_rule?] }.to_h]
          end
        }.to_h
        if (annotation = @annotation_list.find {|a| a.state == self && a.token == token && a.actions == actions })
          annotation.merge_matrix(contribution_matrix)
        else
          @annotation_list << InadequacyAnnotation.new(self, token, actions, contribution_matrix)
        end
      }
    end

    # Definition 3.32 (annotate_predecessor)
    def annotate_predecessor(next_state)
      next_state.annotation_list.each do |annotation|
        contribution_matrix = annotation.contribution_matrix.map {|action, contributions|
          if contributions.nil?
            [action, nil]
          elsif next_state.kernels.any? {|k| contributions[k] && k.position == 1 && lhs_contributions(k.lhs, annotation.token).nil? }
            [action, nil]
          else
            cs = kernels.map {|k|
              c = contributions.any? {|item, contributed| contributed && (
                (item.rule == k.rule && item.position == k.position + 1) ||
                (item.position == 1 && lhs_contributions(item.lhs, annotation.token).nil?)
              ) }
              [k, c]
            }.to_h
            [action, cs]
          end
        }.to_h
        if (at = @annotation_list.find {|a| a.state == annotation.state && a.token == annotation.token && a.actions == annotation.actions })
          at.merge_matrix(contribution_matrix)
        else
          @annotation_list << InadequacyAnnotation.new(annotation.state, annotation.token, annotation.actions, contribution_matrix)
        end
      end
    end

    # Definition 3.31 (compute_lhs_contributions)
    def lhs_contributions(sym, token)
      shift, next_state = nterm_transitions.find {|sh, _| sh.next_sym == sym }
      if always_follows(shift, next_state).include?(token)
        nil
      else
        kernels.map {|kernel| [kernel, follow_kernel_items(shift, next_state, kernel) && item_lookahead_set[kernel].include?(token)] }.to_h
      end
    end

    # Definition 3.16 (follow_kernel_items)
    def follow_kernel_items(shift, next_state, kernel)
      queue = [[self, shift, next_state]]
      until queue.empty?
        st, sh, next_st = queue.pop
        return true if kernel.next_sym == sh.next_sym && kernel.symbols_after_transition.all?(&:nullable)
        st.internal_dependencies(sh, next_st).each {|v| queue << v }
      end
      false
    end

    # Definition 3.26 (item_lookahead_sets)
    def item_lookahead_set
      return @item_lookahead_set if @item_lookahead_set

      @item_lookahead_set = kernels.map {|k| [k, []] }.to_h
      @item_lookahead_set.map {|kernel, _|
        value =
          if kernel.lhs.accept_symbol?
            []
          elsif kernel.position > 1
            prev_items = predecessors_with_item(kernel)
            prev_items.map {|st, i| st.item_lookahead_set[i] }.reduce([]) {|acc, syms| acc |= syms }
          elsif kernel.position == 1
            prev_state = @predecessors.find {|p| p.shifts.any? {|shift| shift.next_sym == kernel.lhs } }
            shift, next_state = prev_state.nterm_transitions.find {|shift, _| shift.next_sym == kernel.lhs }
            prev_state.goto_follows(shift, next_state)
          end
        [kernel, value]
      }.to_h
    end

    def item_lookahead_set=(k)
      @item_lookahead_set = k
    end

    def predecessors_with_item(item)
      result = []
      @predecessors.each do |pre|
        pre.items.each do |i|
          result << [pre, i] if i.predecessor_item_of?(item)
        end
      end
      result
    end

    def append_predecessor(prev_state)
      @predecessors << prev_state
      @predecessors.uniq!
    end

    # Definition 3.39 (compute_goto_follow_set)
    def goto_follow_set(nterm_token)
      return [] if nterm_token.accept_symbol?
      shift, next_state = @lalr_isocore.nterm_transitions.find {|sh, _| sh.next_sym == nterm_token }

      @kernels
        .select {|kernel| follow_kernel_items(shift, next_state, kernel) }
        .map {|kernel| item_lookahead_set[kernel] }
        .reduce(always_follows(shift, next_state)) {|result, terms| result |= terms }
    end

    # Definition 3.24 (goto_follows, via always_follows)
    def goto_follows(shift, next_state)
      queue = internal_dependencies(shift, next_state) + predecessor_dependencies(shift, next_state)
      terms = always_follows(shift, next_state)
      until queue.empty?
        st, sh, next_st = queue.pop
        terms |= st.always_follows(sh, next_st)
        st.internal_dependencies(sh, next_st).each {|v| queue << v }
        st.predecessor_dependencies(sh, next_st).each {|v| queue << v }
      end
      terms
    end

    # Definition 3.20 (always_follows, one closure)
    def always_follows(shift, next_state)
      return @always_follows[[shift, next_state]] if @always_follows[[shift, next_state]]

      queue = internal_dependencies(shift, next_state) + successor_dependencies(shift, next_state)
      terms = []
      until queue.empty?
        st, sh, next_st = queue.pop
        terms |= next_st.term_transitions.map {|sh, _| sh.next_sym }
        st.internal_dependencies(sh, next_st).each {|v| queue << v }
        st.successor_dependencies(sh, next_st).each {|v| queue << v }
      end
      @always_follows[[shift, next_state]] = terms
    end

    # Definition 3.8 (Goto Follows Internal Relation)
    def internal_dependencies(shift, next_state)
      return @internal_dependencies[[shift, next_state]] if @internal_dependencies[[shift, next_state]]

      syms = @items.select {|i|
        i.next_sym == shift.next_sym && i.symbols_after_transition.all?(&:nullable) && i.position == 0
      }.map(&:lhs).uniq
      @internal_dependencies[[shift, next_state]] = nterm_transitions.select {|goto, _| syms.include?(goto.next_sym) }.map {|goto| [self, *goto] }
    end

    # Definition 3.5 (Goto Follows Successor Relation)
    def successor_dependencies(shift, next_state)
      return @successor_dependencies[[shift, next_state]] if @successor_dependencies[[shift, next_state]]

      @successor_dependencies[[shift, next_state]] =
        next_state.nterm_transitions
        .select {|next_shift, _| next_shift.next_sym.nullable }
        .map {|transition| [next_state, *transition] }
    end

    # Definition 3.9 (Goto Follows Predecessor Relation)
    def predecessor_dependencies(shift, next_state)
      state_items = []
      @kernels.select {|kernel|
        kernel.next_sym == shift.next_sym && kernel.symbols_after_transition.all?(&:nullable)
      }.each do |item|
        queue = predecessors_with_item(item)
        until queue.empty?
          st, i = queue.pop
          if i.position == 0
            state_items << [st, i]
          else
            st.predecessors_with_item(i).each {|v| queue << v }
          end
        end
      end

      state_items.map {|state, item|
        sh, next_st = state.nterm_transitions.find {|shi, _| shi.next_sym == item.lhs }
        [state, sh, next_st]
      }
    end
  end
end

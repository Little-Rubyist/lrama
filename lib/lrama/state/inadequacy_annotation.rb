# rbs_inline: enabled
# frozen_string_literal: true

module Lrama
  class State
    class InadequacyAnnotation
      attr_accessor :state #: State
      attr_accessor :token #: Grammar::Symbol
      attr_accessor :actions # :Array[Shift | Reduce]
      attr_accessor :contribution_matrix #: Hash[Shift | Reduce, Hash[States::Item, bool]]

      # @rbs (State state, Grammar::Symbol token, Array[Shift | Reduce] actions, Hash[Shift | Reduce, Hash[States::Item, bool]] contribution_matrix) -> void
      def initialize(state, token, actions, contribution_matrix)
        @state = state
        @token = token
        @actions = actions
        @contribution_matrix = contribution_matrix
      end

      # @rbs (States::Item item) -> bool
      def contributed?(item)
        @contribution_matrix.any? {|action, contributions| !contributions.nil? && contributions[item] }
      end

      # @rbs (Hash[Shift | Reduce, Hash[States::Item, bool]] another_matrix) -> void
      def merge_matrix(another_matrix)
        @contribution_matrix.merge(another_matrix) {|action, contributions, another_contributions|
          next contributions if another_contributions.nil?
          next another_contributions if contributions.nil?

          contributions.merge(another_contributions) {|_, contributed, another_contributed| contributed || another_contributed }
        }
      end

      # Definition 3.42 (dominant_contribution)
      #
      # @rbs (State::lookahead_set lookaheads) -> Array[Shift | Reduce]?
      def dominant_contribution(lookaheads)
        actions = @actions.select {|action|
          contribution_matrix[action].nil? || contribution_matrix[action].any? {|item, contributed| contributed && lookaheads[item].include?(@token) }
        }
        return nil if actions.empty?

        # @type var shifts: Array[Shift]
        # @type var reduces: Array[Reduce]
        shifts, reduces = actions.partition {|action| action.is_a?(Shift) }

        shifts.each do |shift|
          reduces.each do |reduce|
            sym = shift.next_sym

            shift_prec = sym.precedence
            reduce_prec = reduce.item.rule.precedence

            # Can resolve only when both have prec
            unless shift_prec && reduce_prec
              next
            end

            case
            when shift_prec < reduce_prec
              # Reduce is selected
              actions.delete(shift)
              next
            when shift_prec > reduce_prec
              # Shift is selected
              actions.delete(reduce)
              next
            end

            # shift_prec == reduce_prec, then check associativity
            case sym.precedence&.type
            when :precedence
              # %precedence only specifies precedence and not specify associativity
              # then a conflict is unresolved if precedence is same.
              next
            when :right
              # Shift is selected
              actions.delete(reduce)
              next
            when :left
              # Reduce is selected
              actions.delete(shift)
              next
            when :nonassoc
              # Can not resolve
              #
              # nonassoc creates "run-time" error, precedence creates "compile-time" error.
              # Then omit both the shift and reduce.
              #
              # https://www.gnu.org/software/bison/manual/html_node/Using-Precedence.html
              actions.delete(shift)
              actions.delete(reduce)
            else
              raise "Unknown precedence type. #{sym}"
            end
          end
        end

        actions
      end

      # @rbs () -> String
      def to_s
        "State: #{@state.id}, Token: #{@token.id.s_value}, Actions: #{actions_to_s}, Contributions: #{contribution_matrix_to_s}"
      end

      private

      # @rbs () -> String
      def actions_to_s
        '[' + @actions.map {|action|
          if action.is_a?(Shift)
            action.class.name
          elsif action.is_a?(Reduce)
            "#{action.class.name}: (#{action.item})"
          end
        }.join(', ') + ']'
      end

      # @rbs () -> String
      def contribution_matrix_to_s
        '[' + @contribution_matrix.map {|action, contributions|
          "#{action.is_a?(Shift) ? action.class.name : "#{action.class.name}: (#{action.item})"}: " + contributions&.transform_keys(&:to_s).to_s
        }.join(', ') + ']'
      end
    end
  end
end

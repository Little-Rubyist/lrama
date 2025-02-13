# rbs_inline: enabled
# frozen_string_literal: true

module Lrama
  class Warnings
    class RedefinedRules
      # @rbs (Lrama::Logger logger, bool warnings) -> void
      def initialize(logger, warnings = false)
        @logger = logger
        @warnings = warnings
      end

      # @rbs (Lrama::Grammar grammar) -> void
      def warn(grammar)
        return unless @warnings

        grammar.parameterizing_rule_resolver.redefined_rules.each do |rule|
          @logger.warn("parameterizing rule redefined: #{rule}")
        end
      end
    end
  end
end

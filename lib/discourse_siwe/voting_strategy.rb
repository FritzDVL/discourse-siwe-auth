# frozen_string_literal: true

module DiscourseSiwe
  module VotingStrategy
    DEFAULT_RULES = {
      '11' => 1, # SP DAO
      '12' => 5, # Security Council
      '13' => 5, # Governor
      '25' => 3, # Core Team
      '26' => 1, # Contributor
      '28' => 2, # Moderator
    }.freeze

    module_function

    def calculate_power(held_badges, rules = nil)
      active_rules = rules.is_a?(Hash) && !rules.empty? ? rules : DEFAULT_RULES

      badge_ids = parse_badge_ids(held_badges)
      return 0.0 if badge_ids.empty?

      total_power = 0.0

      badge_ids.each do |badge_id|
        str_id = badge_id.to_s
        weight = active_rules[str_id] || active_rules[str_id.to_i] || active_rules['*']
        total_power += weight.to_f if weight
      end

      total_power
    end

    def parse_badge_ids(held_badges)
      case held_badges
      when Array
        held_badges.map do |b|
          b.is_a?(Hash) ? (b['id'] || b[:id]).to_s : b.to_s
        end.reject(&:empty?).uniq
      when String
        held_badges.split(',').map(&:strip).reject(&:empty?).uniq
      else
        []
      end
    end
  end
end

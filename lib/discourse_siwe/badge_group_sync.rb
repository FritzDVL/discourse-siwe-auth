# frozen_string_literal: true

require 'json'
require 'set'

module DiscourseSiwe
  # Maps Society Protocol ERC-1155 badges held by a wallet to Discourse groups.
  # Runs during the throttled identity refresh, account creation, and the
  # migration rake task. Membership changes are applied at refresh time; the
  # forum only learns about badge changes when the user logs in.
  module BadgeGroupSync
    module_function

    # Parses SiteSetting.siwe_society_group_mapping.
    # Format: badge_id:group_name|badge_id:group_name
    # Returns a hash of badge_id (string) => group_name (string).
    def mapping
      raw = SiteSetting.siwe_society_group_mapping.to_s.strip
      return {} if raw.empty?

      raw
        .split('|')
        .map(&:strip)
        .reject(&:empty?)
        .each_with_object({}) do |pair, memo|
          badge_id, group_name = pair.split(':', 2).map(&:strip)
          next if badge_id.to_s.empty? || group_name.to_s.empty?

          memo[badge_id] = group_name
        end
    end

    # Adds/removes the user from mapped groups based on held badges.
    # Never raises; failures are logged and skipped.
    def sync(user)
      return unless SiteSetting.siwe_society_enabled

      map = mapping
      return if map.empty?

      held_ids = IdentityStore.society_badges(user).map { |b| b['id'].to_s }.to_set

      map.each do |badge_id, group_name|
        sync_group(user, badge_id, group_name, held_ids)
      end
    end

    # Pure helper for deciding the membership action.
    # Returns :add, :remove, or :none.
    def action(held_ids, badge_id, member)
      held = held_ids.include?(badge_id.to_s)
      if held && !member
        :add
      elsif !held && member
        :remove
      else
        :none
      end
    end

    private

    def sync_group(user, badge_id, group_name, held_ids)
      group = Group.find_by(name: group_name)
      unless group
        log_warn("[discourse-siwe-auth] Mapped group missing: #{group_name}")
        return
      end

      if group.automatic
        log_warn("[discourse-siwe-auth] Cannot map badge #{badge_id} to automatic group #{group_name}")
        return
      end

      member = group.users.exists?(user.id)
      case action(held_ids, badge_id, member)
      when :add
        group.add(user)
        log_info("[discourse-siwe-auth] Added #{user.username} to #{group_name} (badge #{badge_id})")
      when :remove
        group.remove(user)
        log_info("[discourse-siwe-auth] Removed #{user.username} from #{group_name} (badge #{badge_id} lost)")
      end
    end

    def log_info(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.info(message)
      end
    end

    def log_warn(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      end
    end
  end
end

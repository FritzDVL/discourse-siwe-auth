# frozen_string_literal: true

module DiscourseSiwe
  # Applies the user's preferred web3 identity to their Discourse profile.
  # - user.name (display name)
  # - user avatar download job, if the chosen identity has an avatar URL
  # Username is intentionally never changed by this feature.
  module DisplayNameApplier
    module_function

    def apply(user)
      identities = IdentityStore.web3_identities(user)
      pref = identities[:preferred_identity]

      new_name = display_name_for(pref, identities)
      user.name = new_name if new_name.present?

      avatar_url = avatar_for(pref, identities)
      enqueue_avatar_download(user, avatar_url) if avatar_url.present?
    end

    def display_name_for(pref, identities)
      case pref
      when 'society'
        identities[:society_name]
      when 'ens'
        identities[:ens_name]
      when 'wallet'
        wallet = identities[:wallet_address]
        wallet.present? ? "#{wallet[0..5]}…#{wallet[-4..-1]}" : nil
      end
    end

    def avatar_for(pref, identities)
      case pref
      when 'society' then identities[:society_avatar]
      when 'ens'     then identities[:ens_avatar]
      else nil
      end
    end

    def enqueue_avatar_download(user, url)
      Jobs.enqueue(:download_avatar_from_url, user_id: user.id, url: url)
    rescue StandardError => e
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn("[discourse-siwe-auth] Failed to enqueue avatar download: #{e.message}")
      end
    end
  end
end

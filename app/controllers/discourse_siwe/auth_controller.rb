# frozen_string_literal: true

require 'siwe'
module DiscourseSiwe
  class AuthController < ::ApplicationController
    skip_before_action :check_xhr, only: %i[index]
    skip_before_action :redirect_to_login_if_required, only: %i[index message]

    def index
      raise ApplicationController::RenderEmpty
    end

    def message
      eth_account = params[:eth_account]
      chain_id = params[:chain_id]

      unless eth_account.present? && eth_account.match?(/\A0x[0-9a-fA-F]{40}\z/)
        return render json: { error: "Invalid Ethereum address" }, status: 400
      end

      unless chain_id.present? && chain_id.match?(/\A[1-9][0-9]*\z/)
        return render json: { error: "Invalid chain ID" }, status: 400
      end

      now = Time.now.utc
      domain = Discourse.base_url.delete_prefix("#{Discourse.base_protocol}://")
      message = Siwe::Message.new(domain, eth_account, Discourse.base_url, "1", {
        issued_at: now.iso8601,
        expiration_time: (now + 300).iso8601,
        statement: SiteSetting.siwe_statement,
        nonce: Siwe::Util.generate_nonce,
        chain_id: chain_id,
      })
      session[:nonce] = message.nonce

      render json: { message: message.prepare_message }
    end

    IDENTITIES = %w[wallet ens society].freeze

    def update_identity
      raise Discourse::NotLoggedIn unless current_user

      preferred = params[:preferred_identity]
      unless IDENTITIES.include?(preferred)
        return render json: { error: 'Invalid identity type' }, status: 400
      end

      cf = current_user.custom_fields
      case preferred
      when 'ens'
        return render json: { error: 'No ENS name available' }, status: 400 if cf['ens_name'].blank?
      when 'society'
        return render json: { error: 'No Society identity available' }, status: 400 if cf['society_badge_id'].blank?
      end

      cf['preferred_identity'] = preferred
      current_user.save_custom_fields

      DiscourseSiwe::DisplayNameApplier.apply(current_user)
      current_user.save!

      render json: { success: true, preferred_identity: preferred }
    end
  end
end

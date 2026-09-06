# frozen_string_literal: true

require 'net/http'
require 'json'

module DiscourseSiwe
  # Resolves a Society Protocol profile badge and all held badges for an
  # Ethereum address. Uses the configured subgraph by default and falls back
  # to direct RPC calls (RPC path only resolves the profile badge).
  # Every failure path returns nil so login is never blocked.
  class IdentityResolver
    # Standard ERC-1155 selectors.
    BALANCE_OF_SELECTOR = '00fdd58e'
    URI_SELECTOR        = '0e89341c'

    # SocietyProtocolBadges.profileBadgeId(address)
    PROFILE_BADGE_ID_SELECTOR = EthRpc.bin_to_hex(
      EthRpc.keccak256('profileBadgeId(address)')[0, 4]
    ).freeze

    USER_QUERY = <<~GRAPHQL
      query GetUser($id: ID!) {
        user(id: $id) {
          id
          name
          bio
          imageUrl
          profile {
            id
            name
            description
            imageUrl
            uri
          }
          badges {
            id
            name
            description
            imageUrl
            isOfficial
            isCommunity
            isProfile
          }
        }
      }
    GRAPHQL

    USER_AT_BLOCK_QUERY = <<~GRAPHQL
      query GetUserAtBlock($id: ID!, $block: Int!) {
        user(id: $id, block: { number: $block }) {
          id
          badges {
            id
            name
            description
            imageUrl
            isOfficial
            isCommunity
            isProfile
          }
        }
      }
    GRAPHQL

    def self.resolve(wallet_address)
      new(wallet_address).resolve
    end

    def self.resolve_badges_at_block(wallet_address, block_number = nil)
      new(wallet_address).resolve_badges_at_block(block_number)
    end

    def initialize(wallet_address)
      @wallet_address = wallet_address.to_s.downcase
    end

    # Returns { badge_id:, name:, bio:, avatar:, uri:, badges: } or nil.
    def resolve
      return nil unless SiteSetting.siwe_society_enabled
      return nil unless @wallet_address.match?(/\A0x[0-9a-fA-F]{40}\z/)

      if SiteSetting.siwe_identity_resolution_mode == 'subgraph' &&
         !SiteSetting.siwe_society_subgraph_url.to_s.strip.empty?
        via_subgraph || via_rpc
      else
        via_rpc
      end
    end

    def resolve_badges_at_block(block_number = nil)
      return [] unless SiteSetting.siwe_society_enabled
      return [] unless @wallet_address.match?(/\A0x[0-9a-fA-F]{40}\z/)

      if block_number && block_number.to_i > 0
        badges = via_subgraph_at_block(block_number.to_i)
        return badges if badges && !badges.empty?
      end

      # Fallback to current resolution badges
      res = resolve
      res&.dig(:badges) || []
    end

    private

    def via_subgraph_at_block(block_num)
      return nil if SiteSetting.siwe_society_subgraph_url.to_s.strip.empty?

      uri = URI(SiteSetting.siwe_society_subgraph_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10

      req = Net::HTTP::Post.new(
        uri.path.empty? ? '/' : uri.path,
        'Content-Type' => 'application/json'
      )
      req.body = { query: USER_AT_BLOCK_QUERY, variables: { id: @wallet_address, block: block_num } }.to_json

      resp = http.request(req)
      body = JSON.parse(resp.body)
      data = body.dig('data', 'user')
      return nil unless data

      parse_badges(data['badges'])
    rescue StandardError => e
      log_warn("[discourse-siwe-auth] Society subgraph at block error: #{e.message}")
      nil
    end

    def via_subgraph
      uri = URI(SiteSetting.siwe_society_subgraph_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10

      req = Net::HTTP::Post.new(
        uri.path.empty? ? '/' : uri.path,
        'Content-Type' => 'application/json'
      )
      req.body = { query: USER_QUERY, variables: { id: @wallet_address } }.to_json

      data = JSON.parse(http.request(req).body).dig('data', 'user')
      return nil unless data

      profile = data['profile'] || {}
      {
        badge_id: profile['id'],
        name:   first_non_empty(data['name'], profile['name']),
        bio:    first_non_empty(data['bio'], profile['description']),
        avatar: normalize_url(first_non_empty(data['imageUrl'], profile['imageUrl'])),
        uri:    profile['uri'],
        badges: parse_badges(data['badges']),
      }
    rescue StandardError => e
      log_warn("[discourse-siwe-auth] Society subgraph error: #{e.message}")
      nil
    end

    def via_rpc
      return nil unless DiscourseSiwe::EthRpc.rpc_url
      contract = SiteSetting.siwe_society_badges_contract.to_s
      return nil unless contract.match?(/\A0x[0-9a-fA-F]{40}\z/)

      http = DiscourseSiwe::EthRpc.connection
      http.start do
        badge_id_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{PROFILE_BADGE_ID_SELECTOR}#{DiscourseSiwe::EthRpc.encode_address(@wallet_address)}",
          http: http
        )
        badge_id = DiscourseSiwe::EthRpc.decode_uint256(badge_id_hex)
        return nil if badge_id.nil? || badge_id.zero?

        balance_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{BALANCE_OF_SELECTOR}" \
            "#{DiscourseSiwe::EthRpc.encode_address(@wallet_address)}" \
            "#{DiscourseSiwe::EthRpc.encode_uint256(badge_id)}",
          http: http
        )
        balance = DiscourseSiwe::EthRpc.decode_uint256(balance_hex)
        return nil if balance.nil? || balance.zero?

        uri_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{URI_SELECTOR}#{DiscourseSiwe::EthRpc.encode_uint256(badge_id)}",
          http: http
        )
        metadata_uri = DiscourseSiwe::EthRpc.decode_string(uri_hex)
        meta = fetch_metadata(metadata_uri)

        {
          badge_id: badge_id.to_s,
          name:   meta&.dig('name'),
          bio:    meta&.dig('description'),
          avatar: normalize_url(meta&.dig('image')),
          uri:    metadata_uri,
          badges: [],
        }
      end
    rescue StandardError => e
      log_warn("[discourse-siwe-auth] Society RPC resolution error: #{e.message}")
      nil
    end

    def fetch_metadata(metadata_uri)
      url = normalize_url(metadata_uri)
      return nil if url.to_s.strip.empty?

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10
      JSON.parse(http.request(Net::HTTP::Get.new(uri.request_uri)).body)
    rescue StandardError
      nil
    end

    def normalize_url(url)
      return nil if url.to_s.strip.empty?
      url.start_with?('ipfs://') ? url.sub('ipfs://', 'https://ipfs.io/ipfs/') : url
    end

    def parse_badges(badges_data)
      return [] unless badges_data.is_a?(Array)

      badges_data.filter_map do |b|
        next unless b.is_a?(Hash) && b['id'].present?

        {
          id: b['id'].to_s,
          name: b['name'].to_s,
          description: b['description'].to_s,
          image_url: normalize_url(b['imageUrl']),
          official: b['isOfficial'] == true,
          community: b['isCommunity'] == true,
          profile: b['isProfile'] == true,
        }
      end
    end

    def first_non_empty(*values)
      values.find { |v| !v.to_s.strip.empty? }
    end

    def log_warn(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      end
    end
  end
end

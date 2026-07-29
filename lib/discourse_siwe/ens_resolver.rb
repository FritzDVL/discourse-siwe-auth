# frozen_string_literal: true

require 'net/http'

module DiscourseSiwe
  # Server-side ENS reverse + forward resolution with spoofing check, plus
  # avatar lookup via the ENS metadata service.
  module EnsResolver
    module_function

    # ENS Registry contract address (same on all EVM networks).
    ENS_REGISTRY = '0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e'

    # Function selectors.
    RESOLVER_SELECTOR     = '0178b8bf' # resolver(bytes32)
    REVERSE_NAME_SELECTOR = '691f3431' # name(bytes32)
    FORWARD_ADDR_SELECTOR = '3b3b57de' # addr(bytes32)

    # Public entry point. Returns [ens_name, avatar_url] or [nil, nil].
    def resolve(address)
      return [nil, nil] unless address.present? && DiscourseSiwe::EthRpc.rpc_url

      http = DiscourseSiwe::EthRpc.connection
      http.start do
        addr_clean = DiscourseSiwe::EthRpc.remove_hex_prefix(address).downcase
        reverse_node = namehash("#{addr_clean}.addr.reverse")

        resolver = decode_address(
          DiscourseSiwe::EthRpc.eth_call(ENS_REGISTRY, "0x#{RESOLVER_SELECTOR}#{reverse_node}", http: http)
        )
        return [nil, nil] unless resolver

        name = decode_string(
          DiscourseSiwe::EthRpc.eth_call(resolver, "0x#{REVERSE_NAME_SELECTOR}#{reverse_node}", http: http)
        )
        return [nil, nil] if name.blank?

        # Forward verify — resolve name back to address to prevent spoofing.
        forward_node = namehash(name)
        fwd_resolver = decode_address(
          DiscourseSiwe::EthRpc.eth_call(ENS_REGISTRY, "0x#{RESOLVER_SELECTOR}#{forward_node}", http: http)
        )
        return [nil, nil] unless fwd_resolver

        resolved_addr = decode_address(
          DiscourseSiwe::EthRpc.eth_call(fwd_resolver, "0x#{FORWARD_ADDR_SELECTOR}#{forward_node}", http: http)
        )
        return [nil, nil] unless resolved_addr&.downcase == address.downcase

        [name, avatar_url(name)]
      end
    rescue StandardError
      [nil, nil]
    end

    # Compute ENS namehash for a domain name.
    def namehash(name)
      node = "\x00" * 32
      unless name.nil? || name.empty?
        name.split('.').reverse.each do |label|
          label_hash = DiscourseSiwe::EthRpc.keccak256(label)
          node = DiscourseSiwe::EthRpc.keccak256(node + label_hash)
        end
      end
      DiscourseSiwe::EthRpc.bin_to_hex(node)
    end

    # Returns the ENS metadata avatar URL if it responds 200, nil otherwise.
    def avatar_url(name)
      url = "https://metadata.ens.domains/mainnet/avatar/#{name}"
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5
      response = http.request(Net::HTTP::Head.new(uri.path))
      response.code.to_i == 200 ? url : nil
    rescue StandardError
      nil
    end

    def decode_address(hex)
      DiscourseSiwe::EthRpc.decode_address(hex)
    end

    def decode_string(hex)
      DiscourseSiwe::EthRpc.decode_string(hex)
    end
  end
end

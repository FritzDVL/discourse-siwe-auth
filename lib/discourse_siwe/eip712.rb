# frozen_string_literal: true

begin
  require 'digest/keccak'
rescue LoadError
  # Loaded by Discourse runtime via plugin.rb
end

module DiscourseSiwe
  module Eip712
    EIP712_DOMAIN_TYPE = 'EIP712Domain(string name,string version,uint256 chainId)'
    VOTE_TYPE          = 'Vote(uint256 topicId,uint256[] choice,uint256 timestamp)'

    DOMAIN_NAME    = 'Society Protocol Governance'
    DOMAIN_VERSION = '1'

    module_function

    def encode_uint256(val)
      hex = val.to_i.to_s(16).rjust(64, '0')
      [hex].pack('H*')
    end

    def domain_separator(chain_id = 1)
      type_hash    = EthRpc.keccak256(EIP712_DOMAIN_TYPE)
      name_hash    = EthRpc.keccak256(DOMAIN_NAME)
      version_hash = EthRpc.keccak256(DOMAIN_VERSION)
      chain_bytes  = encode_uint256(chain_id)

      EthRpc.keccak256(type_hash + name_hash + version_hash + chain_bytes)
    end

    def hash_vote(topic_id, choice_array, timestamp, chain_id = 1)
      type_hash = EthRpc.keccak256(VOTE_TYPE)

      choices = choice_array.is_a?(Array) ? choice_array : [choice_array]
      encoded_choices = choices.map { |c| encode_uint256(c) }.join
      choices_hash = EthRpc.keccak256(encoded_choices)

      struct_hash = EthRpc.keccak256(
        type_hash +
        encode_uint256(topic_id) +
        choices_hash +
        encode_uint256(timestamp)
      )

      EthRpc.keccak256("\x19\x01" + domain_separator(chain_id) + struct_hash)
    end

    def verify_vote(signer_address, topic_id, choice_array, timestamp, signature, chain_id = 1)
      return false unless signer_address.present? && signature.present?

      expected_signer = signer_address.to_s.downcase
      digest = hash_vote(topic_id, choice_array, timestamp, chain_id)

      # 1. Try standard EOA recovery via Eth::Signature
      begin
        if defined?(Eth::Signature) && Eth::Signature.respond_to?(:recover)
          recovered = Eth::Signature.recover(digest, signature)&.to_s&.downcase
          return true if recovered == expected_signer
        end
      rescue StandardError
        # Fall through to smart wallet check
      end

      # 2. Smart wallet check (EIP-1271 & EIP-6492)
      smart_wallet_valid?(expected_signer, digest, signature)
    end

    def smart_wallet_valid?(address, digest_bin, signature)
      return false unless EthRpc.rpc_url
      return false unless defined?(OmniAuth::Strategies::Siwe::EIP6492_VALIDATOR_BYTECODE)

      address_param = EthRpc.encode_address(address)
      hash_param = EthRpc.bin_to_hex(digest_bin).rjust(64, '0')
      sig_bytes = EthRpc.remove_hex_prefix(signature)

      bytes_offset = '0000000000000000000000000000000000000000000000000000000000000060'
      sig_length = (sig_bytes.length / 2).to_s(16).rjust(64, '0')
      sig_padded = sig_bytes.ljust(((sig_bytes.length + 63) / 64) * 64, '0')

      data = "0x#{OmniAuth::Strategies::Siwe::EIP6492_VALIDATOR_BYTECODE}" \
             "#{address_param}#{hash_param}#{bytes_offset}#{sig_length}#{sig_padded}"

      result = EthRpc.eth_call(nil, data)
      return false if result.nil?

      result.gsub(/\A0+/, '') == '1'
    rescue StandardError
      false
    end
  end
end

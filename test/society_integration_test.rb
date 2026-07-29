#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration test: resolves a Society Protocol profile badge against a real RPC.
#
# Usage:
#   ruby test/society_integration_test.rb
#
# Set RPC_URL for a dedicated provider; otherwise defaults to a public RPC.
# Set SOCIETY_ADDRESS to an address known to hold a Society profile badge to
# test the positive case.

$LOAD_PATH.unshift(*Dir[File.join(__dir__, '..', 'gems/*/gems/keccak-*/lib')])

require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/identity_resolver'

RPC_URL = ENV.fetch('RPC_URL', 'https://cloudflare-eth.com')
TEST_ADDRESS = ENV.fetch('SOCIETY_ADDRESS', '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045')
BADGES_CONTRACT = '0x2313C0cDdc233c92d16c2cfE17DF5fDCcE556763'

# Minimal SiteSetting stub so this script runs outside Discourse.
module SiteSetting
  class << self
    def siwe_society_enabled
      true
    end

    def siwe_identity_resolution_mode
      'rpc'
    end

    def siwe_society_subgraph_url
      ''
    end

    def siwe_society_badges_contract
      BADGES_CONTRACT
    end

    def siwe_ethereum_rpc_url
      RPC_URL
    end
  end
end

class SocietyIntegrationTest < Minitest::Test
  def test_rpc_path_does_not_crash
    result = DiscourseSiwe::IdentityResolver.resolve(TEST_ADDRESS)

    if ENV['SOCIETY_ADDRESS']
      refute_nil result, 'Expected a Society identity for SOCIETY_ADDRESS'
      refute_empty result[:badge_id].to_s, 'Expected badge_id to be present'
      refute_empty result[:name].to_s, 'Expected name to be present'
      puts "Resolved Society identity: #{result.inspect}"
    else
      # For a random address this is expected to be nil; the important thing is
      # the RPC path completes without raising.
      puts "Resolution result: #{result.inspect}"
    end
  end
end

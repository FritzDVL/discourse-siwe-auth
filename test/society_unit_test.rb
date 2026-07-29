#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for Society Protocol resolution helpers and shared Ethereum utilities.
# No network needed.
#
# Run: ruby test/society_unit_test.rb

$LOAD_PATH.unshift(*Dir[File.join(__dir__, '..', 'gems/*/gems/keccak-*/lib')])

require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/ens_resolver'
require_relative '../lib/discourse_siwe/identity_resolver'
require_relative '../lib/discourse_siwe/identity_store'

class EthRpcHelpersTest < Minitest::Test
  def test_encode_address
    assert_equal(
      '000000000000000000000000d8da6bf26964af9d7eed9e03e53415d37aa96045',
      DiscourseSiwe::EthRpc.encode_address('0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045')
    )
  end

  def test_encode_uint256
    assert_equal(
      '0000000000000000000000000000000000000000000000000000000000000001',
      DiscourseSiwe::EthRpc.encode_uint256(1)
    )
    assert_equal(
      '00000000000000000000000000000000000000000000000000000000000007d0',
      DiscourseSiwe::EthRpc.encode_uint256(2000)
    )
  end

  def test_decode_uint256
    assert_equal 1, DiscourseSiwe::EthRpc.decode_uint256('0000000000000000000000000000000000000000000000000000000000000001')
    assert_equal 2000, DiscourseSiwe::EthRpc.decode_uint256('7d0')
    assert_nil DiscourseSiwe::EthRpc.decode_uint256(nil)
  end

  def test_decode_address
    hex = '000000000000000000000000d8da6bf26964af9d7eed9e03e53415d37aa96045'
    assert_equal '0xd8da6bf26964af9d7eed9e03e53415d37aa96045', DiscourseSiwe::EthRpc.decode_address(hex)
    assert_nil DiscourseSiwe::EthRpc.decode_address('0' * 64)
  end

  def test_decode_string
    hex = '0000000000000000000000000000000000000000000000000000000000000020' \
          '000000000000000000000000000000000000000000000000000000000000000b' \
          '766974616c696b2e657468000000000000000000000000000000000000000000'
    assert_equal 'vitalik.eth', DiscourseSiwe::EthRpc.decode_string(hex)
  end

  def test_keccak256_and_bin_to_hex
    # Empty input keccak256 is well-known.
    expected = 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470'
    assert_equal expected, DiscourseSiwe::EthRpc.bin_to_hex(DiscourseSiwe::EthRpc.keccak256(''))
  end

  def test_profile_badge_id_selector
    # profileBadgeId(address) selector, computed at file load time.
    expected = DiscourseSiwe::EthRpc.bin_to_hex(
      DiscourseSiwe::EthRpc.keccak256('profileBadgeId(address)')[0, 4]
    )
    assert_equal expected, DiscourseSiwe::IdentityResolver::PROFILE_BADGE_ID_SELECTOR
  end
end

class EnsNamehashTest < Minitest::Test
  # Same EIP-137 vectors as test/ens_unit_test.rb, now via the shared module.
  def test_eth
    expected = '93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae'
    assert_equal expected, DiscourseSiwe::EnsResolver.namehash('eth')
  end

  def test_foo_dot_eth
    expected = 'de9b09fd7c5f901e23a3f19fecc54828e9c848539801e86591bd9801b019f84f'
    assert_equal expected, DiscourseSiwe::EnsResolver.namehash('foo.eth')
  end

  def test_empty_name
    assert_equal '0' * 64, DiscourseSiwe::EnsResolver.namehash('')
  end
end

class IdentityStoreTest < Minitest::Test
  def test_default_preference_society_wins
    cf = { 'society_name' => 'Society Member', 'ens_name' => 'foo.eth' }
    assert_equal 'society', DiscourseSiwe::IdentityStore.default_preference(cf)
  end

  def test_default_preference_ens_fallback
    cf = { 'society_name' => '', 'ens_name' => 'foo.eth' }
    assert_equal 'ens', DiscourseSiwe::IdentityStore.default_preference(cf)
  end

  def test_default_preference_wallet_fallback
    assert_equal 'wallet', DiscourseSiwe::IdentityStore.default_preference({})
  end

  def test_store_society
    user = Struct.new(:custom_fields).new({})
    DiscourseSiwe::IdentityStore.store_society(user, {
      badge_id: '42',
      name: 'Hero',
      avatar: 'https://example.com/hero.png',
      bio: 'A bio',
    })
    assert_equal '42', user.custom_fields['society_badge_id']
    assert_equal 'Hero', user.custom_fields['society_name']
    assert_equal 'https://example.com/hero.png', user.custom_fields['society_avatar']
    assert_equal 'A bio', user.custom_fields['society_bio']
    refute_nil user.custom_fields['society_resolved_at']
  end

  def test_society_stale?
    fresh = Struct.new(:custom_fields).new({ 'society_resolved_at' => Time.now.utc.iso8601 })
    stale = Struct.new(:custom_fields).new({ 'society_resolved_at' => (Time.now.utc - 86_401).iso8601 })
    missing = Struct.new(:custom_fields).new({})

    refute DiscourseSiwe::IdentityStore.society_stale?(fresh)
    assert DiscourseSiwe::IdentityStore.society_stale?(stale)
    assert DiscourseSiwe::IdentityStore.society_stale?(missing)
  end

  def test_web3_identities_default_wallet
    user = Struct.new(:custom_fields).new({ 'wallet_address' => '0xabc' })
    identities = DiscourseSiwe::IdentityStore.web3_identities(user)
    assert_equal '0xabc', identities[:wallet_address]
    assert_equal 'wallet', identities[:preferred_identity]
  end
end

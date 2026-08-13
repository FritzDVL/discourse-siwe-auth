#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for Society Protocol resolution helpers and shared Ethereum utilities.
# No network needed.
#
# Run: ruby test/society_unit_test.rb

$LOAD_PATH.unshift(*Dir[File.join(__dir__, '..', 'gems/*/gems/keccak-*/lib')])

require 'minitest/autorun'
require 'set'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/ens_resolver'
require_relative '../lib/discourse_siwe/identity_resolver'
require_relative '../lib/discourse_siwe/identity_store'
require_relative '../lib/discourse_siwe/badge_group_sync'

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

  def test_store_society_persists_badges_json
    user = Struct.new(:custom_fields).new({})
    DiscourseSiwe::IdentityStore.store_society(user, {
      badge_id: '42',
      name: 'Hero',
      avatar: 'https://example.com/hero.png',
      bio: 'A bio',
      badges: [
        { id: '11', name: 'SP DAO', image_url: 'https://example.com/11.png' },
        { id: '25', name: 'Core Team', image_url: 'https://example.com/25.png' },
      ],
    })
    parsed = JSON.parse(user.custom_fields['society_badges'])
    assert_equal '11', parsed.first['id']
    assert_equal '25', parsed.last['id']
  end

  def test_society_badges_helper
    user = Struct.new(:custom_fields).new({
      'society_badges' => [{ id: '13', name: 'Governor' }].to_json,
    })
    badges = DiscourseSiwe::IdentityStore.society_badges(user)
    assert_equal '13', badges.first['id']
    assert_equal 'Governor', badges.first['name']
  end

  def test_society_badges_helper_returns_empty_on_malformed_json
    user = Struct.new(:custom_fields).new({ 'society_badges' => 'not-json' })
    assert_empty DiscourseSiwe::IdentityStore.society_badges(user)
  end
end

class BadgeGroupSyncTest < Minitest::Test
  # Minimal SiteSetting stub for the mapping parser.
  module SiteSetting
    class << self
      attr_accessor :siwe_society_group_mapping, :siwe_society_enabled
    end
  end

  def setup
    SiteSetting.siwe_society_enabled = true
    SiteSetting.siwe_society_group_mapping = '13:governors|25:core-team|28:moderators'
  end

  def test_mapping_parser
    expected = { '13' => 'governors', '25' => 'core-team', '28' => 'moderators' }
    assert_equal expected, DiscourseSiwe::BadgeGroupSync.mapping
  end

  def test_mapping_parser_ignores_malformed_entries
    SiteSetting.siwe_society_group_mapping = '13:governors|junk|25:core-team|28:|::no'
    expected = { '13' => 'governors', '25' => 'core-team' }
    assert_equal expected, DiscourseSiwe::BadgeGroupSync.mapping
  end

  def test_mapping_parser_returns_empty_when_blank
    SiteSetting.siwe_society_group_mapping = ''
    assert_empty DiscourseSiwe::BadgeGroupSync.mapping
  end

  def test_action_truth_table
    held = Set['13', '25']
    assert_equal :add,    DiscourseSiwe::BadgeGroupSync.action(held, '28', false)
    assert_equal :remove, DiscourseSiwe::BadgeGroupSync.action(held, '28', true)
    assert_equal :none,   DiscourseSiwe::BadgeGroupSync.action(held, '13', false)
    assert_equal :none,   DiscourseSiwe::BadgeGroupSync.action(held, '13', true)
  end

  def test_sync_adds_and_removes_users_from_mapped_groups
    user = Struct.new(:id, :custom_fields).new(1, {
      'society_badges' => [{ 'id' => '13', 'name' => 'Governor' }].to_json,
    })

    governor_added = false
    core_removed = false

    fake_group = Struct.new(:name, :automatic, :member_ids) do
      def add(user)
        @added = true
      end

      def remove(user)
        @removed = true
      end

      def added?
        @added == true
      end

      def removed?
        @removed == true
      end

      def users
        Struct.new(:ids) do
          def exists?(user_id)
            ids.include?(user_id)
          end
        end.new(member_ids)
      end
    end

    groups = {
      'governors' => fake_group.new('governors', false, []),
      'core-team' => fake_group.new('core-team', false, [user.id]),
    }

    fake_group_class = Class.new do
      define_singleton_method(:find_by) { |name:| groups[name.to_s] }
    end

    Object.const_set(:Group, fake_group_class) unless defined?(Group)

    DiscourseSiwe::BadgeGroupSync.sync(user)

    assert groups['governors'].added?, 'user should be added to governors'
    assert groups['core-team'].removed?, 'user should be removed from core-team'
  ensure
    Object.send(:remove_const, :Group) if defined?(Group)
  end

  def test_sync_skips_missing_groups
    SiteSetting.siwe_society_group_mapping = '13:missing-group'

    user = Struct.new(:id, :custom_fields).new(1, {
      'society_badges' => [{ 'id' => '13', 'name' => 'Governor' }].to_json,
    })

    fake_group_class = Class.new do
      define_singleton_method(:find_by) { |name:| nil }
    end
    Object.const_set(:Group, fake_group_class) unless defined?(Group)

    # Should not raise even though the mapped group does not exist.
    DiscourseSiwe::BadgeGroupSync.sync(user)
  ensure
    Object.send(:remove_const, :Group) if defined?(Group)
  end
end

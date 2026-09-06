#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'

$LOAD_PATH.unshift(*Dir[File.join(__dir__, '..', 'gems/*/gems/keccak-*/lib')])

require_relative '../lib/discourse_siwe/voting_strategy'

class VotingStrategyTest < Minitest::Test
  def test_empty_badges_returns_zero
    assert_equal 0.0, DiscourseSiwe::VotingStrategy.calculate_power([])
    assert_equal 0.0, DiscourseSiwe::VotingStrategy.calculate_power(nil)
    assert_equal 0.0, DiscourseSiwe::VotingStrategy.calculate_power('')
  end

  def test_default_rules_single_badge
    # 11 is SP DAO (weight 1)
    assert_equal 1.0, DiscourseSiwe::VotingStrategy.calculate_power(['11'])
    # 13 is Governor (weight 5)
    assert_equal 5.0, DiscourseSiwe::VotingStrategy.calculate_power(['13'])
  end

  def test_default_rules_multiple_badges
    # 11 (weight 1) + 13 (weight 5) + 25 (weight 3) = 9
    power = DiscourseSiwe::VotingStrategy.calculate_power(['11', '13', '25'])
    assert_equal 9.0, power
  end

  def test_badge_hashes_from_subgraph
    badges = [
      { 'id' => '11', 'name' => 'SP DAO' },
      { 'id' => '26', 'name' => 'Contributor' } # weight 1
    ]
    assert_equal 2.0, DiscourseSiwe::VotingStrategy.calculate_power(badges)
  end

  def test_custom_strategy_rules
    rules = { '100' => 10, '200' => 25 }
    assert_equal 35.0, DiscourseSiwe::VotingStrategy.calculate_power(['100', '200'], rules)
    assert_equal 0.0, DiscourseSiwe::VotingStrategy.calculate_power(['11'], rules)
  end

  def test_duplicate_badges_counted_once
    assert_equal 1.0, DiscourseSiwe::VotingStrategy.calculate_power(['11', '11'])
  end
end

class ProposalTallyLogicTest < Minitest::Test
  # Mock Vote Struct
  VoteMock = Struct.new(:choice, :voting_power)

  def tally(options, votes)
    tally_data = options.each_with_index.map do |opt, idx|
      {
        index: idx,
        label: opt.to_s,
        vote_count: 0,
        voting_power: 0.0,
        percentage: 0.0,
      }
    end

    total_power = 0.0

    votes.each do |vote|
      choices = vote.choice.is_a?(Array) ? vote.choice : [vote.choice]
      weight = vote.voting_power.to_f
      total_power += weight

      choices.each do |c|
        c_idx = c.to_i
        if c_idx >= 0 && c_idx < tally_data.length
          tally_data[c_idx][:vote_count] += 1
          tally_data[c_idx][:voting_power] += weight
        end
      end
    end

    if total_power > 0
      tally_data.each do |item|
        item[:percentage] = ((item[:voting_power] / total_power) * 100.0).round(2)
      end
    end

    {
      total_votes: votes.size,
      total_power: total_power,
      tallies: tally_data,
    }
  end

  def test_tally_calculation
    options = ['Approve', 'Reject', 'Abstain']
    votes = [
      VoteMock.new([0], 10.0),
      VoteMock.new([0], 5.0),
      VoteMock.new([1], 5.0),
    ]

    result = tally(options, votes)

    assert_equal 3, result[:total_votes]
    assert_equal 20.0, result[:total_power]

    # Option 0 (Approve): 15 power / 20 = 75%
    assert_equal 2, result[:tallies][0][:vote_count]
    assert_equal 15.0, result[:tallies][0][:voting_power]
    assert_equal 75.0, result[:tallies][0][:percentage]

    # Option 1 (Reject): 5 power / 20 = 25%
    assert_equal 1, result[:tallies][1][:vote_count]
    assert_equal 5.0, result[:tallies][1][:voting_power]
    assert_equal 25.0, result[:tallies][1][:percentage]

    # Option 2 (Abstain): 0 power
    assert_equal 0, result[:tallies][2][:vote_count]
    assert_equal 0.0, result[:tallies][2][:voting_power]
    assert_equal 0.0, result[:tallies][2][:percentage]
  end
end

# If Digest::Keccak is not installed on system ruby, provide a mock for EthRpc.keccak256
unless defined?(Digest::Keccak)
  module Digest
    class Keccak
      def initialize(_); end
      def digest(data)
        OpenSSL::Digest::SHA256.digest(data)
      end
    end
  end
end

require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/eip712'

class Eip712HashingTest < Minitest::Test

  def test_hash_vote_deterministic
    h1 = DiscourseSiwe::Eip712.hash_vote(123, [0], 1700000000, 1)
    h2 = DiscourseSiwe::Eip712.hash_vote(123, [0], 1700000000, 1)
    assert_equal h1, h2
    assert_equal 32, h1.bytesize
  end

  def test_hash_vote_differs_on_choice
    h1 = DiscourseSiwe::Eip712.hash_vote(123, [0], 1700000000, 1)
    h2 = DiscourseSiwe::Eip712.hash_vote(123, [1], 1700000000, 1)
    refute_equal h1, h2
  end

  def test_hash_vote_differs_on_topic_id
    h1 = DiscourseSiwe::Eip712.hash_vote(123, [0], 1700000000, 1)
    h2 = DiscourseSiwe::Eip712.hash_vote(124, [0], 1700000000, 1)
    refute_equal h1, h2
  end

  def test_hash_vote_differs_on_chain_id
    h1 = DiscourseSiwe::Eip712.hash_vote(123, [0], 1700000000, 1)
    h2 = DiscourseSiwe::Eip712.hash_vote(123, [0], 1700000000, 11155111)
    refute_equal h1, h2
  end
end

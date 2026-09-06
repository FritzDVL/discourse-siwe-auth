# frozen_string_literal: true

class SpProposal < ActiveRecord::Base
  self.table_name = 'sp_proposals'

  has_many :sp_votes, dependent: :destroy

  enum status: { open: 0, closed: 1 }

  validates :topic_id, presence: true, uniqueness: true
  validates :title, presence: true
  validates :snapshot_block, presence: true, numericality: { greater_than: 0 }
  validates :ends_at, presence: true

  def active?
    open? && Time.now.utc < ends_at
  end

  def tally_results
    parsed_options = options.is_a?(Array) ? options : []
    tally = parsed_options.each_with_index.map do |opt, idx|
      {
        index: idx,
        label: opt.to_s,
        vote_count: 0,
        voting_power: 0.0,
        percentage: 0.0,
      }
    end

    total_power = 0.0
    votes = sp_votes.to_a

    votes.each do |vote|
      choices = vote.choice.is_a?(Array) ? vote.choice : [vote.choice]
      weight = vote.voting_power.to_f
      total_power += weight

      choices.each do |c|
        c_idx = c.to_i
        if c_idx >= 0 && c_idx < tally.length
          tally[c_idx][:vote_count] += 1
          tally[c_idx][:voting_power] += weight
        end
      end
    end

    if total_power > 0
      tally.each do |item|
        item[:percentage] = ((item[:voting_power] / total_power) * 100.0).round(2)
      end
    end

    {
      total_votes: votes.size,
      total_power: total_power,
      tallies: tally,
    }
  end
end

# frozen_string_literal: true

class SpVote < ActiveRecord::Base
  self.table_name = 'sp_votes'

  belongs_to :sp_proposal, class_name: 'SpProposal'

  validates :sp_proposal_id, presence: true
  validates :topic_id, presence: true
  validates :voter_address, presence: true, format: { with: /\A0x[0-9a-fA-F]{40}\z/ }
  validates :choice, presence: true
  validates :signature, presence: true
  validates :signed_at, presence: true
  validates :voter_address, uniqueness: { scope: :topic_id, message: 'has already voted on this proposal' }

  before_validation :normalize_address

  private

  def normalize_address
    self.voter_address = voter_address.downcase if voter_address.present?
  end
end

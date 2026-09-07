# frozen_string_literal: true

class CreateSpVotingTables < ActiveRecord::Migration[7.0]
  def change
    create_table :sp_proposals do |t|
      t.integer :topic_id, null: false
      t.string :title, null: false
      t.jsonb :options, null: false, default: []
      t.bigint :snapshot_block, null: false
      t.datetime :ends_at, null: false
      t.jsonb :strategy_rules, default: {}
      t.boolean :shielded, default: false, null: false
      t.integer :status, default: 0, null: false
      t.timestamps
    end

    add_index :sp_proposals, :topic_id, unique: true

    create_table :sp_votes do |t|
      t.references :sp_proposal, null: false, foreign_key: true, index: true
      t.integer :topic_id, null: false
      t.string :voter_address, null: false
      t.jsonb :choice, null: false
      t.decimal :voting_power, precision: 30, scale: 0, default: 0, null: false
      t.text :signature, null: false
      t.bigint :signed_at, null: false
      t.timestamps
    end

    add_index :sp_votes, :topic_id
    add_index :sp_votes, :voter_address
    add_index :sp_votes, %i[topic_id voter_address], unique: true
  end
end

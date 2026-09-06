The gap analysis provided in the evaluation is spot-on: attempting to execute the original proposal without resolving proposal data models, Ember Web3 limitations, connector outlets, and exact EIP-712 typing would have stalled development immediately.

Here is the updated, gap-free Master Specification ready to paste directly to Antigravity for execution on the `feature/native-token-voting` branch.

---

# Master Technical Specification: Native Token Voting

**Target Repository:** `SocietyProtocol/discourse-siwe-auth`

**Target Branch:** `feature/native-token-voting` (branched from `token-gating` @ `0f020e1`)

**Scope:** In-plugin off-chain EIP-712 voting subsystem weighted by ERC-1155 snapshot balances via Subgraph.

---

### 1. Database Schema Migration

Create migration: `db/migrate/20260906000000_create_sp_voting_tables.rb`

```ruby
class CreateSpVotingTables < ActiveRecord::Migration[7.0]
  def change
    create_table :sp_proposals do |t|
      t.integer :topic_id, null: false, index: { unique: true }
      t.string :title, null: false
      t.jsonb :options, null: false, default: [] # e.g. ["Approve", "Reject", "Abstain"]
      t.bigint :snapshot_block, null: false
      t.datetime :ends_at, null: false
      t.jsonb :strategy_rules, default: {} # e.g. { "11" => 1, "13" => 5 }
      t.integer :status, default: 0 # 0: open, 1: closed
      t.timestamps
    end

    create_table :sp_votes do |t|
      t.references :sp_proposal, null: false, foreign_key: true, index: true
      t.integer :topic_id, null: false, index: true
      t.string :voter_address, null: false, index: true
      t.jsonb :choice, null: false # Array of chosen option indices: [0]
      t.decimal :voting_power, precision: 30, scale: 0, default: 0
      t.text :signature, null: false
      t.bigint :signed_at, null: false
      t.timestamps
      t.index [:topic_id, :voter_address], unique: true
    end
  end
end

```

---

### 2. Backend Controller & Routing

#### Route Registration (`plugin.rb`)

Register routes inside `Discourse::Application.routes.prepend`:

```ruby
Discourse::Application.routes.prepend do
  get "/sp-voting/proposal/:topic_id" => "discourse_siwe/voting#show"
  post "/sp-voting/cast-vote" => "discourse_siwe/voting#cast_vote"
  post "/sp-voting/proposal" => "discourse_siwe/voting#create_proposal" # Admin/Staff only
end

```

#### Controller (`app/controllers/discourse_siwe/voting_controller.rb`)

1. **`show` Endpoint:** Retrieves the proposal for `:topic_id`, tallies votes by option index, and returns whether `current_user` has an active SIWE wallet and prior vote.
2. **`create_proposal` Endpoint:** Admin/Staff populates options and expiration. Automagically captures `snapshot_block` using `DiscourseSiwe::EthRpc.eth_block_number`.
3. **`cast_vote` Endpoint:**

- Validates active Discourse session and confirms recovered signature matches `current_user.custom_fields['wallet_address']`.
- Enforces proposal window (`Time.now.utc < proposal.ends_at`).
- Queries Subgraph at `snapshot_block` via `DiscourseSiwe::IdentityResolver` for voter's held ERC-1155 badges.
- Calculates weight based on `proposal.strategy_rules` and upserts `sp_votes`.

---

### 3. EIP-712 Specification & Frontend Bridge

To bypass Ember.js Web3 limitations, export EIP-712 signing helper functions directly inside the Vite bundler module (`ui/src/main.ts` compiled into `public/javascripts/siwe.iife.js`).

#### EIP-712 Shared Typed Schema

```typescript
export const EIP712_DOMAIN = {
  name: 'Society Protocol Governance',
  version: '1',
  chainId: 1, // Resolves dynamically from SiteSetting.siwe_voting_chain_id
}

export const EIP712_TYPES = {
  Vote: [
    { name: 'topicId', type: 'uint256' },
    { name: 'choice', type: 'uint256[]' },
    { name: 'timestamp', type: 'uint256' },
  ],
}
```

Expose `window.SiweAuth.signVotePayload({ topicId, choice })` to trigger Wagmi/Viem signing via MetaMask, WalletConnect, or Safe.

---

### 4. Ember Connector Component Integration

Attach the vote card to the topic level (not per post) using the Discourse plugin outlet.

#### Connector File

`assets/javascripts/discourse/connectors/topic-above-posts/sp-vote-connector.hbs`

```hbs
{{#if this.isGovernanceTopic}}
  <SpVoteWidget @topic={{this.model}} />
{{/if}}
```

#### Connector Script

`assets/javascripts/discourse/connectors/topic-above-posts/sp-vote-connector.js`

```javascript
export default {
  setupComponent(args, component) {
    const tags = component.get('model.tags') || []
    component.set('isGovernanceTopic', tags.includes('governance'))
  },
}
```

---

### 5. Local Development & Testing Instructions

Run the following workflow locally to initialize and test the implementation:

```bash
# 1. Switch to the feature branch inside your plugin directory
cd ~/Developer/Pluggin\ SPxDiscourse/discourse-siwe-auth
git checkout -b feature/native-token-voting

# 2. Re-bundle frontend assets if ui/ is modified
cd ui && pnpm build && cd ..

# 3. Run database migrations inside the local Discourse dev container
cd ~/discourse
bin/rake db:migrate

# 4. Start local development server
bin/ember-cli -s

```

#### Validation Verification Checklist:

- [ ] Create a topic tagged `#governance` on `http://localhost:4200`.
- [ ] Initialize proposal with options via `/sp-voting/proposal` API.
- [ ] Log in with SIWE; confirm `sp-vote-widget` appears above posts.
- [ ] Submit vote choice and sign EIP-712 request in wallet.
- [ ] Verify entry creation in DB via `bin/rails dbconsole`:

```sql
SELECT * FROM sp_votes;

```

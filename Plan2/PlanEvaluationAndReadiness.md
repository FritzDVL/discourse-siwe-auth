# Repository Status & Plan 2 Evaluation: Native Token/Identity Voting

**Assessment Date:** September 6, 2026  
**Repository:** `discourse-siwe-auth` (`SocietyProtocol/discourse-siwe-auth`)  
**Current Branch:** `token-gating` (HEAD commit `0f020e1`)  
**Target Feature:** Native Token & Identity Voting Module (`feature/native-token-voting`)  
**Evaluated Document:** [NewPlan.md](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/Plan2/NewPlan.md)

---

## Executive Summary

1. **Current State of the Repository:**
   The repository is in a healthy, modular state with core authentication, multi-identity resolution (Wallet, ENS, and Society Protocol outpost/profile via Subgraph & RPC), and badge-based token gating (`BadgeGroupSync`) implemented up to version **1.5.0**. However, the current branch `token-gating` is awaiting live end-to-end testing on a running Discourse instance. Currently, there is **no voting infrastructure** in the repository (no voting database tables, models, controllers, routes, or UI widgets).

2. **Is Plan 2 sufficiently accurate to start coding immediately?**
   **No.** While the conceptual vision of `NewPlan.md` (off-chain EIP-712 voting weighted by ERC-1155 snapshot balances) is sound and aligns with Society Protocol's roadmap, the specification has **critical architectural omissions, technical ambiguities, and naming mismatches** that will stall development or lead to broken implementations if attempted as-is.

Below is the detailed gap analysis, what works, what needs fixing, and the exact refined technical specifications required before coding starts.

---

## Part 1: Current Codebase Health & Status

| Area | Current Status | Key Files / Implementation Details |
|---|---|---|
| **Git & Branching** | `token-gating` branch | Clean working directory. Commit `0f020e1` added Society badge token gating. |
| **SIWE Authentication** | Fully implemented | [plugin.rb](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/plugin.rb), [siwe.rb](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/lib/omniauth/strategies/siwe.rb). Supports EOA, EIP-1271 (Safe), and EIP-6492 (undeployed smart accounts). |
| **Identity Resolution** | Fully implemented | [identity_resolver.rb](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/lib/discourse_siwe/identity_resolver.rb). Queries live Subgraph (`siwe_society_subgraph_url`) for profile badge + all held badges; RPC fallback via [eth_rpc.rb](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/lib/discourse_siwe/eth_rpc.rb). |
| **Token Gating** | Implemented (pending live test) | [badge_group_sync.rb](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/lib/discourse_siwe/badge_group_sync.rb). Uses `siwe_society_group_mapping` (`badge_id:group_name`). Auto-adds and removes users from mapped Discourse groups upon login / background refresh. |
| **Frontend Wallet Stack** | Hybrid (Vue 3 + Wagmi + Discourse Ember) | Frontend in [ui/](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/ui/) compiles via Vite into IIFE `public/javascripts/siwe.iife.js`. Loaded dynamically in Discourse Ember controller via `loadScript`. Identity selector rendered via Discourse plugin connector in [assets/javascripts/discourse/](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/assets/javascripts/discourse/). |
| **Voting Subsystem** | **Not started** | 0% implemented. No models, migrations, endpoints, or voting components exist. |

---

## Part 2: Critical Gaps & Inaccuracies in `Plan2/NewPlan.md`

### 1. Repository & Plugin Naming Mismatch (Breaking)
- **Plan says:** Repo name is `discourse-siwe-SP-auth` (lines 11, 22, 107).
- **Actual Codebase:** The directory and official name is `discourse-siwe-auth` (`SocietyProtocol/discourse-siwe-auth`).
- **Why this breaks:** Discourse resolves static plugin assets based on the directory name under `/plugins/<plugin-dir-name>/...`. Using `discourse-siwe-SP-auth` in asset paths or symlinks will result in 404 errors for scripts and stylesheets.

### 2. Ember Frontend Cannot Sign EIP-712 or Support WalletConnect Alone (Critical)
- **Plan says:** `components/sp-vote-widget.js` handles "Wallet interaction & EIP-712 trigger (MetaMask / WalletConnect)".
- **Discourse Reality:** Discourse’s Ember.js runtime contains **zero Web3 libraries**.
  - Plain JavaScript in Ember can only access `window.ethereum` if MetaMask (or another injected provider) is installed.
  - It **cannot** communicate with WalletConnect, mobile wallets, Safe, or Coinbase Wallet without an integrated provider client and modal.
- **Architectural Solution Needed:**
  The repo already has a modern Web3 toolchain in `ui/` using `@wagmi/core`, `viem`, and `@walletconnect/ethereum-provider` compiled into `siwe.iife.js`. 
  - Either the Vite bundle in `ui/` must export voting helper methods (e.g. `window.SiweAuth.signVote(...)` or a mountable vote widget),
  - OR the Ember component must use a standardized lightweight bundle that encapsulates Viem/Wagmi for EIP-712 signing.

### 3. Discourse Plugin Outlet Connector is Missing
- **Plan says:** "Attach `sp-vote-widget` to the `topic-title-after` or `post-content` outlet whenever a topic contains the `#governance` tag."
- **Discourse Reality:** In Discourse Ember, a component does not mount itself automatically.
  - It requires a connector file, e.g.: `assets/javascripts/discourse/connectors/topic-above-posts/sp-vote-connector.hbs` (or `topic-title-after`).
  - Note: `post-content` is an outlet rendered inside **every post** in a thread (causing duplicate voting widgets on every reply). The vote card must mount at the **topic level** (`topic-above-posts` or `topic-title-after`).
  - The connector template must evaluate the topic tag condition: `{{#if this.isGovernanceTopic}}...{{/if}}`.

### 4. Undefined Poll & Proposal Metadata (Data Model Gap)
- **Plan specifies:** Table `sp_votes` storing `{ topic_id, voter_address, choice, voting_power, signature }`.
- **The Missing Piece:** Where is the **Proposal/Poll Definition** stored?
  - What are the voting options? (e.g. Option 0: "Approve", Option 1: "Reject", Option 2: "Abstain")
  - What is the voting start time and deadline (expiration)?
  - What is the snapshot block height?
  - Who can create a proposal?
- If the endpoint `GET /sp-voting/poll/:topic_id` only queries `sp_votes`, where does it get the option labels, poll title, and status?
- **Recommendation:** Either:
  1. Store proposal configuration in Discourse Topic Custom Fields (`topic.custom_fields['sp_voting_proposal']` containing JSON with options, strategy, deadline, and snapshot block).
  2. Or create a parent table `sp_proposals` in the Rails migration (`topic_id`, `options`, `snapshot_block`, `strategy`, `ends_at`, `status`).

### 5. Snapshot Block Height Resolution is Unspecified
- **Plan says:** "Query `web3-app-subgraph` to fetch the voter's ERC-1155 token balances (`balanceOf(voter, tokenId)`) at the topic creation block height."
- **Discourse / Web3 Reality:**
  - Discourse topics only record a Postgres timestamp `created_at`.
  - The Graph and Ethereum RPC require an **exact integer block number** (`block: { number: X }`).
  - How is `created_at` translated to an Ethereum block number?
  - Querying historical blocks by timestamp requires an RPC search or archival block service.
- **Solution:** When a `#governance` topic or proposal is created, the backend must fetch the latest block number via `EthRpc.eth_block_number` and record it directly as `snapshot_block` in the proposal metadata.

### 6. Subgraph Schema & Voting Strategy Weights Are Ambiguous
- **Plan says:** "Query `web3-app-subgraph` to fetch the voter's ERC-1155 token balances... Apply strategy rules (e.g., Token ID 1 = 1 Vote, Token ID 2 = Weighted Amount)."
- **Current Ground Truth:**
  - In `lib/discourse_siwe/identity_resolver.rb`, the query is:
    ```graphql
    user(id: $id) { badges { id name isOfficial ... } }
    ```
  - In Society Protocol contracts, official badges include IDs `11` (SP DAO), `12` (Security Council), `13` (Governor), `25` (Core Team), `26` (Contributor), `28` (Moderator).
  - The plan leaves open:
    - Which token IDs are allowed to vote?
    - Are the weights hardcoded, configured in a `SiteSetting` (e.g. `siwe_voting_strategy_weights`), or configured per topic?
    - Does The Graph endpoint support historical block queries (`@block(number: $block)`) for the user's badges?

### 7. Incomplete EIP-712 Data Contract
- **Plan says:** "Verify signature against standard EIP-712 domain `Society Protocol Governance`."
- EIP-712 hashing requires an exact typed schema shared between frontend and backend:
  - **Domain:** `name`, `version`, `chainId`, `verifyingContract` (or omitted).
  - **Type structure:** Field names and types (e.g. `uint256 topicId`, `uint256[] choice`, `uint256 timestamp`).
  - If a single character, casing, or chain ID differs, signature verification fails.
  - Also: The recovered address must be verified to match `current_user.custom_fields['wallet_address']`.

### 8. Routing & Controller Namespacing
- **Plan says:** `config/routes.rb` and `app/controllers/sp_voting_controller.rb`.
- In Discourse plugins:
  - Defining routes directly in `plugin.rb` inside `Discourse::Application.routes.prepend` is the standard pattern (matching lines 205–209 of `plugin.rb`).
  - Controllers should be namespaced under `DiscourseSiwe::VotingController` to prevent collisions with Discourse core and other plugins.

---

## Part 3: Readiness Verdict & Recommendation

### Is the plan ready to execute right now?
**Verdict:** **Needs Refinement (75% complete).**  
Starting implementation without locking down the 8 gaps above will result in friction during frontend-backend integration, broken wallet signature requests, and unclear poll configuration.

### Can we make it ready quickly?
**Yes.** The architectural gaps can be resolved by aligning `NewPlan.md` with the existing conventions in `discourse-siwe-auth`.

---

## Part 4: Refined Technical Specification (The Missing Pieces)

Here is the exact concrete specification to incorporate into `Plan 2` to make it 100% actionable:

### 1. Proposal & Vote Data Model

#### A. Database Migration: `db/migrate/20260906000000_create_sp_voting_tables.rb`
Create two tables (or `sp_proposals` + `sp_votes`):

```ruby
class CreateSpVotingTables < ActiveRecord::Migration[7.0]
  def change
    create_table :sp_proposals do |t|
      t.integer :topic_id, null: false, index: { unique: true }
      t.string :title, null: false
      t.jsonb :options, null: false, default: [] # ['Yes', 'No', 'Abstain']
      t.bigint :snapshot_block, null: false
      t.datetime :ends_at, null: false
      t.jsonb :strategy_rules, default: {} # { '11' => 1, '13' => 5 }
      t.integer :status, default: 0 # 0: open, 1: closed
      t.timestamps
    end

    create_table :sp_votes do |t|
      t.references :sp_proposal, null: false, foreign_key: true, index: true
      t.integer :topic_id, null: false, index: true
      t.string :voter_address, null: false, index: true
      t.jsonb :choice, null: false # [0]
      t.decimal :voting_power, precision: 30, scale: 0, default: 0
      t.text :signature, null: false
      t.bigint :signed_at, null: false
      t.timestamps
      t.index [:topic_id, :voter_address], unique: true
    end
  end
end
```

### 2. Formal EIP-712 Specification

```typescript
// EIP-712 Typed Data Definition
export const EIP712_DOMAIN = {
  name: 'Society Protocol Governance',
  version: '1',
  chainId: 1, // Or SiteSetting.siwe_voting_chain_id
}

export const EIP712_TYPES = {
  Vote: [
    { name: 'topicId', type: 'uint256' },
    { name: 'choice', type: 'uint256[]' },
    { name: 'timestamp', type: 'uint256' },
  ],
}
```

### 3. API Contract (`DiscourseSiwe::VotingController`)

- `GET /sp-voting/proposal/:topic_id`
  - Returns proposal details: options, `snapshot_block`, `ends_at`, current aggregate vote counts/power per option, whether the current user is eligible, and their existing vote.
- `POST /sp-voting/cast-vote`
  - Authenticated Discourse session.
  - Verifies EIP-712 signature recovering the signer.
  - Ensures signer matches `current_user.custom_fields['wallet_address']`.
  - Checks if proposal is still open (`Time.now.utc < proposal.ends_at`).
  - Resolves voter's eligible badges at `snapshot_block` via Subgraph/RPC.
  - Computes total voting power according to `proposal.strategy_rules`.
  - Persists or updates the vote.

### 4. Frontend Integration (`sp-vote-widget`)
- Connector file: `assets/javascripts/discourse/connectors/topic-above-posts/sp-vote-connector.hbs`
  - Mounts widget conditionally: `{{#if this.isGovernance}} <SpVoteWidget @topic={{this.model}} /> {{/if}}`
- Wallet interaction:
  - Add voting capability to the Vite/Wagmi app in `ui/` or export Viem EIP-712 signer method onto `window.SiweAuth`. This guarantees full support for MetaMask, WalletConnect, and mobile browsers.

---

## Recommended Next Steps

1. **Step 1: Approve Refinements to Plan 2**  
   Update `Plan2/NewPlan.md` (or accept the specifications outlined above) so that database models, EIP-712 parameters, and wallet interaction methods are clearly bounded.
2. **Step 2: Create Feature Branch**  
   Switch from `token-gating` to `feature/native-token-voting`:
   ```bash
   git checkout -b feature/native-token-voting
   ```
3. **Step 3: Implementation Order**  
   1. Backend Rails migration (`sp_proposals`, `sp_votes`) & models.
   2. Ruby EIP-712 signature verification helper & Subgraph snapshot power calculator.
   3. Controller endpoints in `DiscourseSiwe::VotingController` + routes in `plugin.rb`.
   4. Frontend wallet signing module & Discourse Ember topic connector widget.
   5. Automated unit/integration tests in `test/`.

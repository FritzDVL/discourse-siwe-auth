A Discourse plugin setup is hybrid: **it contains a backend portion (Ruby/Rails) and a frontend portion (Ember.js/Discourse Theme Assets)**, alongside an optional lightweight Node.js/Viem microservice.

Below is the technical specification prompt you can hand off directly to Google Antigravity (or another agentic coding environment). It includes file trees, data contracts, and step-by-step local testing instructions.

---

# Technical Specification Prompt for Antigravity

**Role:** Senior Web3 & Discourse Full-Stack Engineer

**Objective:** Implement a native Token/Identity Voting module inside our existing Discourse plugin repository (`discourse-siwe-SP-auth`) on a feature branch named `feature/native-token-voting`.

**Dependencies:** `discourse-siwe-SP-auth`, `web3-app-subgraph` (GraphQL endpoint), `web3-app-contracts` (ERC-1155 identities).

---

### 1. Architecture Scope & Repository Structure

Add the voting subsystem directly inside the existing `discourse-siwe-SP-auth` repository under a new plugin extension module.

```text
discourse-siwe-SP-auth/
├── plugin.rb                          # Registers endpoints, DB migrations & Ember assets
├── config/
│   └── routes.rb                      # Defines /sp-voting API endpoints
├── db/migrate/
│   └── 20260906000000_create_sp_votes.rb # Stores voting payloads & metadata
├── app/
│   ├── controllers/
│   │   └── sp_voting_controller.rb   # Verifies SIWE session, EIP-712 & queries Subgraph
│   └── models/
│       └── sp_vote.rb                 # Vote record model & balance cache
└── assets/javascripts/discourse/
    ├── templates/components/sp-vote-widget.hbs # Voting Card UI in Topic View
    └── components/sp-vote-widget.js            # Wallet interaction & EIP-712 trigger

```

---

### 2. Database Schema (Rails Migration)

Create table `sp_votes`:

- `id` (Primary Key)
- `topic_id` (Integer, Indexed) — Corresponds to Discourse Topic/Proposal ID
- `voter_address` (String, Indexed) — User's SIWE-bound Ethereum address
- `choice` (Integer Array / JSON) — Selected voting option indices
- `voting_power` (BigInt / Numeric) — Tally weight computed via Subgraph
- `signature` (Text) — EIP-712 signature string
- `created_at` / `updated_at` (Timestamps)

---

### 3. API & Backend Requirements (`sp_voting_controller.rb`)

#### Endpoint 1: `GET /sp-voting/poll/:topic_id`

- **Public:** Returns current tallies and user-specific voting status for a topic.
- **Logic:**

1. Reads all `sp_votes` where `topic_id = params[:topic_id]`.
2. Returns total weight per option index.
3. If current session user is logged in, returns their cast vote (if any).

#### Endpoint 2: `POST /sp-voting/cast-vote`

- **Authenticated:** Requires active Discourse user session with an authenticated SIWE address.
- **Payload:** `{ topic_id, choice, signature, timestamp }`
- **Execution Sequence:**

1. **EIP-712 Signature Verification:** Verify signature against standard EIP-712 domain `Society Protocol Governance`.
2. **Snapshot Query (GraphQL):** Query `web3-app-subgraph` to fetch the voter's ERC-1155 token balances (`balanceOf(voter, tokenId)`) at the topic creation block height.
3. **Calculate Power:** Apply strategy rules (e.g., Token ID 1 = 1 Vote, Token ID 2 = Weighted Amount).
4. **Persistence:** Insert or update record in `sp_votes`. Return `{ success: true, weight: X }`.

---

### 4. Frontend Component Specification (`sp-vote-widget`)

1. **Mounting Point:** Attach `sp-vote-widget` to the `topic-title-after` or `post-content` outlet whenever a topic contains the `#governance` tag.
2. **State Management:**

- **Not Connected / No SIWE:** Prompts user to authenticate via existing `discourse-siwe-SP-auth`.
- **Connected / Eligible:** Renders option checkboxes/radios, a **"Sign & Cast Vote"** button, and current vote progress bars.
- **Voted:** Renders user's submitted choice with a "Vote Submitted" badge and live aggregate progress.

---

### 5. Local Development & Testing Instructions

Provide these setup steps to test end-to-end functionality locally:

#### Step A: Git Branch Setup

```bash
git checkout -b feature/native-token-voting

```

#### Step B: Local Discourse Docker Development Setup

```bash
# 1. Clone Discourse Core and link the plugin locally
git clone https://github.com/discourse/discourse.git ~/discourse
cd ~/discourse/plugins
ln -s /path/to/discourse-siwe-SP-auth ./discourse-siwe-SP-auth

# 2. Boot Discourse development container
cd ~/discourse
bin/ember-cli -s

```

#### Step C: Testing & Validation Flow

1. **Mock Subgraph:** Spin up local `web3-app-subgraph` or configure the plugin `SiteSetting` to point to a testnet Subgraph HTTP URL.
2. **Discourse Local Admin:** Navigate to `http://localhost:4200`, log in, create a topic tagged `#governance`.
3. **Execute Test:**

- Sign in using SIWE on the local forum.
- Click options on the `sp-vote-widget`.
- Trigger the wallet payload request (MetaMask / WalletConnect).
- Confirm signature validation and verify entry creation in local Postgres (`rails dbconsole` -> `SELECT * FROM sp_votes;`).

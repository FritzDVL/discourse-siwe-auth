# Evaluation of NewAnswer.md: Native Token Voting Master Specification

**Evaluation Date:** September 6, 2026  
**Evaluated File:** [NewAnswer.md](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/Plan2/NewAnswer.md)  
**Target Branch:** `feature/native-token-voting`  
**Status:** **APPROVED FOR EXECUTION (Green Light)**

---

## Executive Summary

`NewAnswer.md` successfully incorporates all critical architectural recommendations and addresses the gaps identified in [PlanEvaluationAndReadiness.md](file:///Users/user/Developer/Pluggin%20SPxDiscourse/discourse-siwe-auth/Plan2/PlanEvaluationAndReadiness.md). 

The proposal has transformed from an underspecified concept into a **production-grade technical blueprint** that accurately fits Discourse's plugin ecosystem and this repository's hybrid architecture (Rails backend + Discourse Ember + Vite/Wagmi Web3 IIFE bundle).

The plan is now **sufficiently accurate and structurally sound to start coding immediately**.

---

## Part 1: Gap Resolution Scorecard

| Identified Gap from Previous Review | Solution in `NewAnswer.md` | Verdict |
|---|---|---|
| **1. Missing Proposal / Poll Data Model** | Added `sp_proposals` table (`topic_id`, `options`, `snapshot_block`, `ends_at`, `strategy_rules`, `status`) linked to `sp_votes`. | **Resolved.** Now proposal options, deadlines, and block heights are formally persisted. |
| **2. Ember Web3 / WalletConnect Limitation** | Exports `window.SiweAuth.signVotePayload` from the Vite bundle in `ui/src/main.ts` using `@wagmi/core` / `viem`. | **Resolved.** Full support for MetaMask, WalletConnect, and Safe without fighting Ember constraints. |
| **3. Discourse Outlet Connector & Scope** | Uses `connectors/topic-above-posts/sp-vote-connector.hbs` + `.js` with `tags.includes('governance')`. | **Resolved.** Mounts once per topic rather than repeating on every post. |
| **4. EIP-712 Typing & Domain Contract** | Defined standard `EIP712_DOMAIN` and `EIP712_TYPES` with explicit field types (`topicId`, `choice`, `timestamp`). | **Resolved.** Frontend and backend now share an identical hashing schema. |
| **5. Routing & Controller Namespacing** | Uses `Discourse::Application.routes.prepend` in `plugin.rb` and `DiscourseSiwe::VotingController`. | **Resolved.** Follows Discourse conventions and avoids global namespace collisions. |
| **6. Repository & Path Accuracy** | Corrected repo references to `discourse-siwe-auth`. | **Resolved.** Asset paths and symlinks will resolve cleanly. |

---

## Part 2: Implementation Details & Code Specifications

To ensure smooth coding during execution, the following 4 implementation-level code blocks should be used directly when building the components:

### 1. `EthRpc.eth_block_number` (`lib/discourse_siwe/eth_rpc.rb`)
The controller's `create_proposal` endpoint needs `eth_block_number`. Add this method to `EthRpc`:

```ruby
def eth_block_number(http: nil)
  return nil unless rpc_url

  http ||= connection
  path = URI(rpc_url).path
  path = '/' if path.empty?

  req = Net::HTTP::Post.new(path, 'Content-Type' => 'application/json')
  req.body = {
    jsonrpc: '2.0',
    method: 'eth_blockNumber',
    params: [],
    id: 1
  }.to_json

  response = http.request(req)
  result = JSON.parse(response.body)
  return nil if result['error'] || result['result'].nil?

  result['result'].to_i(16)
rescue StandardError
  nil
end
```

### 2. Ruby EIP-712 Signature Verification (`lib/discourse_siwe/eip712.rb`)
Ruby's `eth` gem handles EOA signature recovery from a 32-byte hash, and `siwe.rb` already contains the EIP-6492 smart-wallet validator. We introduce a helper to compute the EIP-712 hash:

```ruby
# frozen_string_literal: true

module DiscourseSiwe
  module Eip712
    EIP712_DOMAIN_TYPE = 'EIP712Domain(string name,string version,uint256 chainId)'
    VOTE_TYPE = 'Vote(uint256 topicId,uint256[] choice,uint256 timestamp)'

    def self.hash_vote(topic_id, choice_array, timestamp, chain_id = 1)
      domain_separator = EthRpc.keccak256(
        EthRpc.keccak256(EIP712_DOMAIN_TYPE) +
        EthRpc.keccak256('Society Protocol Governance') +
        EthRpc.keccak256('1') +
        [chain_id.to_i].pack('N*').rjust(32, "\x00")
      )

      # Encoded uint256[] choice is keccak256(concatenated 32-byte integers)
      encoded_choice = choice_array.map { |c| [c.to_i].pack('N*').rjust(32, "\x00") }.join
      choice_hash = EthRpc.keccak256(encoded_choice)

      vote_struct_hash = EthRpc.keccak256(
        EthRpc.keccak256(VOTE_TYPE) +
        [topic_id.to_i].pack('N*').rjust(32, "\x00") +
        choice_hash +
        [timestamp.to_i].pack('N*').rjust(32, "\x00")
      )

      EthRpc.keccak256("\x19\x01" + domain_separator + vote_struct_hash)
    end

    def self.verify_vote(signer_address, topic_id, choice_array, timestamp, signature, chain_id = 1)
      expected_signer = signer_address.to_s.downcase
      digest = hash_vote(topic_id, choice_array, timestamp, chain_id)

      # 1. Try standard EOA recovery via Eth::Signature
      recovered = Eth::Signature.recover(digest, signature)&.downcase rescue nil
      return true if recovered == expected_signer

      # 2. Smart wallet fallback (EIP-1271 / EIP-6492)
      return false unless EthRpc.rpc_url
      OmniAuth::Strategies::Siwe.new(nil).send(:smart_wallet_valid?, Struct.new(:address).new(expected_signer), signature) rescue false
    end
  end
end
```

### 3. Frontend Web3 Signer Bridge (`ui/src/main.ts`)
Add `signVotePayload` inside `ui/src/main.ts` using `@wagmi/core` and `viem`:

```typescript
import { signTypedData } from '@wagmi/core'

export async function signVotePayload(wagmiConfig: any, payload: { topicId: number; choice: number[]; timestamp: number; chainId?: number }) {
  const domain = {
    name: 'Society Protocol Governance',
    version: '1',
    chainId: payload.chainId || 1,
  } as const

  const types = {
    Vote: [
      { name: 'topicId', type: 'uint256' },
      { name: 'choice', type: 'uint256[]' },
      { name: 'timestamp', type: 'uint256' },
    ],
  } as const

  const signature = await signTypedData(wagmiConfig, {
    domain,
    types,
    primaryType: 'Vote',
    message: {
      topicId: BigInt(payload.topicId),
      choice: payload.choice.map(BigInt),
      timestamp: BigInt(payload.timestamp),
    },
  })

  return signature
}
```

### 4. Configuration Setting (`config/settings.yml`)
Add voting chain ID setting:

```yaml
  siwe_voting_chain_id:
    client: true
    default: 1
```

---

## Part 3: Step-by-Step Execution Plan

With `NewAnswer.md` approved, here is the execution sequence:

1. **Step 1: Branch Creation & Setup**
   ```bash
   git checkout -b feature/native-token-voting
   ```
2. **Step 2: Database Layer**
   - Create migration `db/migrate/20260906000000_create_sp_voting_tables.rb`.
   - Create ActiveRecord models: `app/models/sp_proposal.rb` and `app/models/sp_vote.rb`.
3. **Step 3: Backend Verification & Controllers**
   - Add `eth_block_number` in `lib/discourse_siwe/eth_rpc.rb`.
   - Add `lib/discourse_siwe/eip712.rb` for typed data hashing and signature checks.
   - Implement `DiscourseSiwe::VotingController` with `show`, `create_proposal`, and `cast_vote`.
   - Register routes in `plugin.rb` and settings in `config/settings.yml`.
4. **Step 4: Frontend Web3 & Discourse Ember UI**
   - Export `signVotePayload` from `ui/src/main.ts` and rebuild `pnpm build`.
   - Add Discourse connector in `assets/javascripts/discourse/connectors/topic-above-posts/`.
   - Add Ember component `sp-vote-widget` (rendering options, live progress tallies, and signature prompt).
5. **Step 5: Testing & Verification**
   - Write unit tests in `test/voting_unit_test.rb` verifying EIP-712 hashing, power calculation, and endpoint authentication.
   - Run end-to-end verification checklist as outlined in `NewAnswer.md`.

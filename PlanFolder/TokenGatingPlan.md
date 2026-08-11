# Plan: Society Badge Token Gating for Discourse (v1)

**Status:** Implementation-ready. Builds on `RefinedPlan.md` (already implemented).
**Repo:** `SocietyProtocol/discourse-siwe-auth` — current version 1.4.0
**Feature name:** Web3 Outpost sign-in for Discourse — badge-based group gating

---

## 1. Goal

Map Society Protocol ERC-1155 badges held by a user's verified wallet to
Discourse group membership. When a user signs in, their held badges are
resolved and their group memberships are synced: they are **added** to mapped
groups for badges they hold and **removed** from mapped groups for badges they
no longer hold. This is the token-gating mechanism for the forum.

v1 scope (agreed):

- Group sync + group flair (flair is configured by the admin on the Discourse
  group itself — no custom frontend work).
- Mapping via a site setting (`badge_id:group_name` pairs).
- Auto-remove on badge loss (applied at the next identity refresh, see §5).
- **No dedicated badges display section** — deferred until badge artwork is
  finalized.

Out of scope (future phases, see §9):

- Admin UI for mapping arbitrary token contracts (no-code setup for external
  communities).
- Rendering held badges with artwork (profile card / preferences section).
- ERC-20 (SPEC) balance-based gating.
- Real-time revocation (webhooks / indexer push instead of login-time pull).

---

## 2. Verified ground truth

Confirmed against the live subgraph
(`https://api.studio.thegraph.com/query/46833/society-mainnet/version/latest`)
and its `schema.graphql`:

- `User.badges: [Badge!]!` — every badge the wallet holds, one query. We do
  **not** need per-ID `balanceOf` loops for the subgraph path.
- `Badge` fields available: `id` (ERC-1155 token ID), `name`, `description`,
  `imageUrl`, `isOfficial`, `isCommunity`, `isProfile`, `community { id name }`.
- Live official badges (queried 2026-07-29, `isOfficial: true`):

  | Token ID | Name | Holders (at query time) |
  |---|---|---|
  | 11 | SP DAO | 1 |
  | 12 | Security Council | 1 |
  | 13 | Governor | 2 |
  | 14 | Bronze VIP | 0 |
  | 15 | Silver VIP | 0 |
  | 16 | Gold VIP | 0 |
  | 24 | Advisor | 0 |
  | 25 | Core Team | 6 |
  | 26 | Contributor | 10 |
  | 27 | ICO Participant | 0 |
  | 28 | Moderator | 2 |

  ⚠️ IDs 17–23 do **not** exist on-chain as official badges despite the docs
  registry mentioning the 11–28 range. Do not hardcode a contiguous range
  anywhere; the mechanism must work purely from the mapping setting.

- The mapping mechanism is **generic** by design: `badge_id → group_name`
  works for community badges too (they appear in `user.badges` with
  `isCommunity: true`). External communities can already gate on their own
  badges in v1 by knowing their badge IDs; the no-code admin UI is what the
  future phase adds.

---

## 3. Settings (`config/settings.yml`)

Append under `discourse_siwe:`:

```yaml
  siwe_society_group_mapping:
    default: ''
```

- Format: `badge_id:group_name|badge_id:group_name|...`
  Example: `13:governors|25:core-team|28:moderators`
- Empty string = feature disabled (no-op). Kill-switch without touching
  `siwe_society_enabled`.
- Server-side only, no `client: true`.
- Add matching label to `config/locales/server.en.yml`.

Group names refer to existing Discourse groups. **Groups are created and
configured (name, flair, title, visibility) by the forum admin** — the plugin
never creates groups, and it logs + skips any mapped group that doesn't exist.

---

## 4. Backend changes

### 4.1 `IdentityResolver` — extend the subgraph query

Current `USER_QUERY` gains a badges block:

```graphql
query GetUser($id: ID!) {
  user(id: $id) {
    id
    name
    bio
    imageUrl
    profile { id name description imageUrl uri }
    badges { id name description imageUrl isOfficial isCommunity isProfile }
  }
}
```

Result hash gains:

```ruby
badges: (data['badges'] || []).map do |b|
  { id: b['id'], name: b['name'], image_url: b['imageUrl'],
    official: b['isOfficial'], community: b['isCommunity'] }
end
```

RPC fallback (`via_rpc`) stays as-is (profile badge only) and returns
`badges: []` — document that group gating requires subgraph mode. This is
acceptable because RPC mode is already the degraded fallback; enumerating
badges via `balanceOf` loops is not viable without an on-chain registry.

### 4.2 `IdentityStore` — persist the badge list

- Add `society_badges` to `FIELDS` (registered as `:string`, stores JSON).
- `store_society` additionally writes
  `user.custom_fields['society_badges'] = (society[:badges] || []).to_json`.
- `IdentityStore.society_badges(user)` helper: parse the JSON, return `[]` on
  missing/malformed data. Never raises.

### 4.3 New module: `DiscourseSiwe::BadgeGroupSync`
(`lib/discourse_siwe/badge_group_sync.rb`)

```ruby
module DiscourseSiwe
  module BadgeGroupSync
    module_function

    # Returns { 13 => "governors", 25 => "core-team" } from the setting.
    # Malformed entries are skipped with a log line.
    def mapping
      # parse SiteSetting.siwe_society_group_mapping
    end

    # Adds/removes the user from mapped groups based on held badge IDs.
    # Never raises: every failure is logged with warn and skipped.
    def sync(user)
      map = mapping
      return if map.empty?

      held_ids = IdentityStore.society_badges(user).map { |b| b['id'].to_i }.to_set

      map.each do |badge_id, group_name|
        group = Group.find_by(name: group_name)
        unless group
          Rails.logger.warn("[discourse-siwe-auth] Mapped group missing: #{group_name}")
          next
        end

        member = group.users.exists?(user.id)
        if held_ids.include?(badge_id) && !member
          group.add(user)
          log "added #{user.username} to #{group_name} (badge #{badge_id})"
        elsif !held_ids.include?(badge_id) && member
          group.remove(user)
          log "removed #{user.username} from #{group_name} (badge #{badge_id} lost)"
        end
      end
    end
  end
end
```

Rules:

- Only groups **present in the mapping** are ever touched. Users are never
  removed from unmapped groups.
- Removal is exactly the token-gating semantic: badge lost → group removed.
- `Group#add` / `Group#remove` are Discourse core APIs (idempotent, fire the
  usual group events — flair/title update automatically).
- Runs **after** `store_society` + `save_custom_fields`, in the same places:
  - `Jobs::RefreshSiweIdentity#execute` (the throttled login-time refresh)
  - `SiweAuthenticator#after_create_account` (new signups)
  - the `siwe:migrate_identities` rake task (backfill)
- The login path itself stays network-free; sync runs inside the background
  job, so a slow subgraph never blocks authentication.

Load + call sites: add the `load` line in `plugin.rb`'s `after_initialize`.

### 4.4 Rake task

`siwe:migrate_identities` calls `BadgeGroupSync.sync(user)` after storing
fields (inside the `unless dry_run` block), so the backfill also populates
groups.

---

## 5. Freshness semantics (web2 ↔ web3 boundary)

Badge state is pulled, not pushed. Membership changes apply at:

- account creation (immediate), and
- the throttled refresh: at most once per 24h, triggered on login.

Consequences to document in the README:

- A user who **receives** a badge gets group access at their next login
  (or next day at worst).
- A user who **loses** a badge keeps access until their next login/refresh.
  This is inherent to embedding web3 state into a web2 forum; real-time
  revocation is a future phase (§9).
- Admins can force a user refresh by clearing their `society_resolved_at`
  custom field, or force everyone by re-running the migration task after
  clearing the field. (The rake task skips users who already have
  `wallet_address` — for forced re-sync, add a `force` flag: run
  `store_society` + sync regardless. Small addition, same task.)

---

## 6. Tests (standalone minitest, existing style)

`test/society_unit_test.rb` additions (no network):

- Mapping parser: valid pairs, empty string, malformed entries
  (`"13:governors|junk|:no-name|14:"`), whitespace tolerance.
- `society_badges` JSON round-trip via the Struct user stub; malformed JSON
  returns `[]`.
- Sync decision logic (extract the add/remove decision into a pure function
  `BadgeGroupSync.action(held_ids, badge_id, member?)` returning
  `:add` / `:remove` / `:none` — test the truth table without stubbing
  Discourse `Group`).

No Discourse-test-suite (rspec) additions — consistent with the repo.

---

## 7. Also update

- `README.md`: new "Token gating" section — mapping format, group creation +
  flair setup walkthrough, freshness semantics (§5), registry table (§2) as
  the reference for Society's own badges, note that community badges work the
  same way.
- `plugin.rb` header: version `1.4.0` → `1.5.0`.
- `config/locales/server.en.yml`: label for the new setting.

---

## 8. Open items to confirm on staging

1. `Group#add` / `Group#remove` behavior on the deployed Discourse version
   (both are long-stable core APIs, but confirm no `GroupUser` callback
   surprises for managed/automatic groups — mapped groups must be
   **manual** groups, not Discourse automatic groups like `trust_level_1`).
2. Subgraph `badges` field latency after a mint/burn (indexing delay — affects
   how quickly a new badge appears at next login).
3. Flair images: admin uploads badge artwork to each mapped group manually
   until the dedicated artwork pipeline exists.
4. Run `siwe:migrate_identities[true]` dry-run, then the real backfill, then
   verify a known badge holder (e.g. a Core Team wallet, ID 25, 6 holders)
   lands in the right group.

---

## 9. Future phases (not in v1)

- **No-code admin UI:** paste any ERC-1155 (or ERC-20) contract address + token
  ID, pick a Discourse group, done. This is what makes the plugin reusable by
  external communities gating on their own tokens. Needs a proper admin
  settings UI (list + add/remove rows) instead of the pipe-delimited string,
  plus a generic `balanceOf` resolver for arbitrary contracts (subgraph only
  covers the Society Badges contract).
- **Badges display section:** render held badges with artwork on the user
  profile/preferences once artwork is finalized.
- **SPEC (ERC-20) gating:** balance-threshold groups.
- **Real-time revocation:** subscribe to subgraph webhook / event indexer so
  burns kick users immediately instead of at next login.

---

## 10. Implementation order

1. `config/settings.yml` + locales (§3, §7)
2. `IdentityResolver` query extension + parsing (§4.1)
3. `IdentityStore` badge persistence (§4.2) + unit tests (§6)
4. `BadgeGroupSync` module (§4.3) + unit tests (§6)
5. Wire into job, authenticator, rake task + `force` flag (§4.3, §4.4, §5)
6. README + version bump (§7)
7. Staging: create mapped groups with flair, dry-run backfill, verify with a
   real badge-holding wallet (§8)

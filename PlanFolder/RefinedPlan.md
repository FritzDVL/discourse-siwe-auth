# Refined Plan: Society Protocol Identity Toggle for Discourse SIWE

**Status:** Implementation-ready. Supersedes `InitialPlan.md`.
**Repo:** `SocietyProtocol/discourse-siwe-auth` — current version 1.2.1
**Target Discourse:** 2026.6.0 (prod) / 2026.7.0 (test)

This plan keeps the draft's overall shape (custom fields + resolver + toggle UI +
migration) but fixes concrete bugs found by reviewing it against the actual
codebase, and replaces every unverified Society Protocol assumption with facts
confirmed against their live repos and deployment.

---

## 1. Verified Society Protocol facts (ground truth)

Confirmed against [SocietyProtocol/web3-app-subgraph](https://github.com/SocietyProtocol/web3-app-subgraph),
[SocietyProtocol/web3-app-client](https://github.com/SocietyProtocol/web3-app-client), and
[SocietyProtocol/web3-app-contracts](https://github.com/SocietyProtocol/web3-app-contracts):

- **Live Badges contract (ERC-1155, UUPS proxy), Ethereum mainnet:**
  `0x2313C0cDdc233c92d16c2cfE17DF5fDCcE556763` (current; used by the live app
  and live subgraph since the May 2026 redeploy).
  ⚠️ The draft plan's default `0xa3af0da9733061da88b91ea28740780a887c8ce3` is
  the **legacy** proxy — still on-chain but superseded. Do not use it as default.
- **Live mainnet subgraph endpoint** (extracted from the app.societyprotocol.io
  bundle; verified to return data):
  `https://api.studio.thegraph.com/query/46833/society-mainnet/version/latest`
- **Subgraph schema** (`schema.graphql`): `User` entity keyed by lowercase
  wallet address, fields `name`, `bio`, `imageUrl`, `profile: Badge`.
  `Badge` entity: `id` (ERC-1155 token id), `name`, `description`, `imageUrl`,
  `uri`, `isProfile`, `holdersCount`, etc. The draft's GraphQL query shape was
  approximately right; the corrected query is in §4.3.
- **Contract ABI** (`SocietyProtocolBadges.sol`):
  `profileBadgeId(address) → uint256`, `uri(uint256) → string`,
  `balanceOf(address,uint256) → uint256`.
  ⚠️ `balanceOf` can be **overridden per-badge by a hook contract**
  (`ISocietyBadgeHook.onBalanceOf`) — it is not plain ERC-1155. Don't cache or
  second-guess its result; just call it.
- The frontend's own user lookup query is
  `src/queries/user.graphql` in web3-app-client — use it as the reference
  pattern for our query.

---

## 2. Bugs in the draft plan, and their fixes

| # | Draft problem | Fix |
|---|---|---|
| 1 | Badges contract default is the stale pre-redeploy proxy | Default to `0x2313C0cDdc233c92d16c2cfE17DF5fDCcE556763`, keep it a site setting |
| 2 | Wallet address taken from `auth_token.dig(:info, :name)` — but `info.name` is `ens_name \|\| address` (see `siwe.rb` `info` block) | Use `auth_token.uid` (the strategy sets `uid` to `@verified_address`) |
| 3 | `resolve_society_via_rpc` is an unimplemented placeholder | Full implementation in §4.4, reusing a shared RPC helper (§4.1) |
| 4 | `result.extra_data.merge(...)` — `extra_data` can be nil | Nil-guard before merging |
| 5 | **Core logic gap:** `apply_preferred_identity` mutates `result.username/name/avatar_url`, which Discourse only uses at **account creation**. For existing users (the stated scope!) the toggle would do nothing | Define explicit display semantics in §5: toggle updates `user.name` (display name) + avatar for existing users; username is left stable. Auth-result mutation only matters for new signups |
| 6 | ENS never refreshed for existing users on login | Store ENS from `auth_token.info` on every login (it is already resolved server-side in the strategy — free) |
| 7 | `assoc.info` in migration — `UserAssociatedAccount` has no `info` column (it has `provider_name`, `provider_uid`, `user_id`, `extra` jsonb) | Use `assoc.extra`; ENS is generally not persisted there, so migration re-resolves ENS via RPC (§7) |
| 8 | Frontend Ember code mixes classic `Component.extend({})` with `@action` decorators — invalid syntax; also reads `model.custom_fields.*` while the serializer adds `web3_identities` | Correct Glimmer component in §6, reading `model.web3_identities.*` |
| 9 | `modifyClass('controller:preferences/profile')` with an empty body does nothing — the component is never rendered | Render via a real plugin outlet / connector (§6.3), with the exact outlet verified against the deployed Discourse version |
| 10 | Error-revert line `this.set('model.custom_fields.preferred_identity', this.model.custom_fields.preferred_identity)` is a no-op | Store previous value, restore on failure (§6.2) |
| 11 | `siwe_society_rpc_url` defaults to an Alchemy URL containing `YOUR_KEY`; also duplicates the existing `siwe_ethereum_rpc_url` | Drop the setting; Society RPC falls back to `siwe_ethereum_rpc_url` (§3) |
| 12 | Subgraph/RPC call runs **synchronously inside the login callback** on every login — adds latency and failure surface to auth | Resolve inline only at account creation; refresh for existing users in a background job, throttled (§4.5) |
| 13 | Re-registering `discourse_siwe_enabled` with `client: true` duplicates `enabled_site_setting` | Leave the existing setting untouched |
| 14 | `sanitize_username` slices to 60 chars; Discourse max username length is a site setting (`max_username_length`, default 20) | Truncate to `SiteSetting.max_username_length` and let Discourse's suggester uniquify |
| 15 | Test plan has no automated tests | Add standalone minitest files matching the repo's existing test style (§8) |

---

## 3. Plugin settings (`config/settings.yml`)

Append under the existing `discourse_siwe:` section (keep the four existing
settings exactly as they are):

```yaml
discourse_siwe:
  # ... existing settings unchanged ...

  siwe_society_enabled:
    default: true

  siwe_society_subgraph_url:
    default: 'https://api.studio.thegraph.com/query/46833/society-mainnet/version/latest'

  siwe_society_badges_contract:
    default: '0x2313C0cDdc233c92d16c2cfE17DF5fDCcE556763'

  siwe_identity_resolution_mode:
    default: 'subgraph'
    type: enum
    choices:
      - subgraph
      - rpc
```

Notes:

- None of these need `client: true` — all resolution is server-side.
- **No `siwe_society_rpc_url`.** RPC mode (and ENS) both use the existing
  `siwe_ethereum_rpc_url`. If mode is `rpc` and that setting is empty, Society
  resolution returns nil — same behavior as ENS today.
- `siwe_society_enabled` is a kill-switch so the feature can be disabled
  without touching the rest.
- Add matching labels to `config/locales/server.en.yml`.

---

## 4. Backend changes

### 4.1 New file: `lib/discourse_siwe/eth_rpc.rb` (shared helper)

`lib/omniauth/strategies/siwe.rb` currently has private `rpc_url`,
`rpc_connection`, and `eth_call` methods. The resolver and the migration need
the same capability, so extract them into a shared module instead of
copy-pasting a third implementation:

```ruby
# frozen_string_literal: true

require 'net/http'
require 'json'

module DiscourseSiwe
  module EthRpc
    module_function

    def rpc_url
      url = SiteSetting.siwe_ethereum_rpc_url rescue nil
      url if url&.present?
    end

    def connection
      uri = URI(rpc_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10
      http
    end

    # Generic eth_call. `to` may be nil (contract-creation simulation,
    # used by EIP-6492). Returns hex result without 0x prefix, or nil.
    def eth_call(to, data, http: nil)
      return nil unless rpc_url

      http ||= connection
      path = URI(rpc_url).path
      path = '/' if path.empty?
      call_params = { data: data }
      call_params[:to] = to if to
      req = Net::HTTP::Post.new(path, 'Content-Type' => 'application/json')
      req.body = {
        jsonrpc: '2.0', method: 'eth_call',
        params: [call_params, 'latest'], id: 1
      }.to_json

      result = JSON.parse(http.request(req).body)
      return nil if result['error'] || result['result'].nil? || result['result'] == '0x'

      Eth::Util.remove_hex_prefix(result['result'])
    rescue StandardError
      nil
    end

    # ABI encode helpers for the calls we need
    def encode_address(addr) = Eth::Util.remove_hex_prefix(addr).downcase.rjust(64, '0')
    def encode_uint256(n)    = n.to_i.to_s(16).rjust(64, '0')

    def decode_address(hex)
      return nil if hex.nil? || hex.length < 40
      address = hex[-40, 40]
      return nil if address == '0' * 40
      "0x#{address}"
    end

    def decode_uint256(hex)
      return nil if hex.nil? || hex.empty?
      hex.to_i(16)
    end

    def decode_string(hex)
      return nil if hex.nil? || hex.length < 128
      offset = hex[0, 64].to_i(16) * 2
      length = hex[offset, 64].to_i(16)
      return '' if length.zero?
      data_start = offset + 64
      return nil if hex.length < data_start + length * 2
      [hex[data_start, length * 2]].pack('H*').force_encoding('UTF-8')
    end
  end
end
```

Then refactor `lib/omniauth/strategies/siwe.rb` **minimally**: delete its
private `rpc_url` / `rpc_connection` / `eth_call` / `abi_decode_address` /
`abi_decode_string` and delegate to `DiscourseSiwe::EthRpc`
(e.g. `EthRpc.eth_call(...)`). Keep `ens_namehash`, `resolve_ens`,
`ens_avatar_url`, and `smart_wallet_valid?` where they are — behavior must not
change. This refactor is what lets the migration re-resolve ENS (§7) without
duplicating ENS logic: also expose ENS resolution by moving `resolve_ens` +
helpers into the same module **or** into `IdentityResolver` — decide once, but
there must be exactly one ENS implementation afterward. Recommendation: move
`ens_namehash`, `resolve_ens`, `ens_avatar_url` into
`lib/discourse_siwe/ens_resolver.rb` and have the strategy call it.

### 4.2 New file: `lib/discourse_siwe/identity_resolver.rb`

Full implementation (no placeholder). Returns a hash or nil:

```ruby
# frozen_string_literal: true

require 'net/http'
require 'json'

module DiscourseSiwe
  class IdentityResolver
    # eth_call function selectors (first 4 bytes of keccak of the signature):
    #   profileBadgeId(address)  -> 0x...
    #   balanceOf(address,uint256) -> 0x00fdd58e
    #   uri(uint256)             -> 0x0e89341c
    # Compute selectors at load time with Eth::Util.keccak256 to avoid
    # hardcoding mistakes (same approach as ENS selectors in siwe.rb, which
    # are hardcoded — either is acceptable, but verify against the ABI).
    BALANCE_OF_SELECTOR = '00fdd58e'
    URI_SELECTOR        = '0e89341c'

    PROFILE_BADGE_ID_SELECTOR = Eth::Util.bin_to_hex(
      Eth::Util.keccak256('profileBadgeId(address)')[0, 4]
    ).freeze

    def self.resolve(wallet_address)
      new(wallet_address).resolve
    end

    def initialize(wallet_address)
      @wallet_address = wallet_address.downcase
    end

    # Returns { badge_id:, name:, bio:, avatar:, uri: } or nil.
    def resolve
      return nil unless SiteSetting.siwe_society_enabled

      if SiteSetting.siwe_identity_resolution_mode == 'subgraph' &&
         SiteSetting.siwe_society_subgraph_url.present?
        via_subgraph || via_rpc   # fall back to RPC if subgraph fails
      else
        via_rpc
      end
    end

    private

    # --- Subgraph path -------------------------------------------------------

    QUERY = <<~GRAPHQL
      query GetUser($id: ID!) {
        user(id: $id) {
          id
          name
          bio
          imageUrl
          profile {
            id
            name
            description
            imageUrl
            uri
          }
        }
      }
    GRAPHQL

    def via_subgraph
      uri = URI(SiteSetting.siwe_society_subgraph_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10
      req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path,
                                'Content-Type' => 'application/json')
      req.body = { query: QUERY, variables: { id: @wallet_address } }.to_json

      data = JSON.parse(http.request(req).body).dig('data', 'user')
      return nil unless data

      profile = data['profile'] || {}
      {
        badge_id: profile['id'],
        # User-level fields are the outpost profile; badge metadata is fallback
        name:   data['name'].presence || profile['name'],
        bio:    data['bio'].presence || profile['description'],
        avatar: data['imageUrl'].presence || profile['imageUrl'],
        uri:    profile['uri'],
      }
    rescue StandardError => e
      Rails.logger.warn("[discourse-siwe-auth] Society subgraph error: #{e.message}")
      nil
    end

    # --- Direct-RPC fallback -------------------------------------------------

    def via_rpc
      return nil unless DiscourseSiwe::EthRpc.rpc_url
      contract = SiteSetting.siwe_society_badges_contract
      return nil unless contract.match?(/\A0x[0-9a-fA-F]{40}\z/)

      http = DiscourseSiwe::EthRpc.connection
      http.start do
        # 1. profileBadgeId(address) — 0 means "no profile badge"
        badge_id_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{PROFILE_BADGE_ID_SELECTOR}#{DiscourseSiwe::EthRpc.encode_address(@wallet_address)}",
          http: http
        )
        badge_id = DiscourseSiwe::EthRpc.decode_uint256(badge_id_hex)
        return nil if badge_id.nil? || badge_id.zero?

        # 2. balanceOf(address, badgeId) — hook-aware check the user holds it
        balance_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{BALANCE_OF_SELECTOR}" \
            "#{DiscourseSiwe::EthRpc.encode_address(@wallet_address)}" \
            "#{DiscourseSiwe::EthRpc.encode_uint256(badge_id)}",
          http: http
        )
        balance = DiscourseSiwe::EthRpc.decode_uint256(balance_hex)
        return nil if balance.nil? || balance.zero?

        # 3. uri(badgeId) -> metadata JSON URL (http or ipfs)
        uri_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{URI_SELECTOR}#{DiscourseSiwe::EthRpc.encode_uint256(badge_id)}",
          http: http
        )
        metadata_uri = DiscourseSiwe::EthRpc.decode_string(uri_hex)

        meta = fetch_metadata(metadata_uri)
        {
          badge_id: badge_id.to_s,
          name:   meta&.dig('name'),
          bio:    meta&.dig('description'),
          avatar: normalize_url(meta&.dig('image')),
          uri:    metadata_uri,
        }
      end
    rescue StandardError => e
      Rails.logger.warn("[discourse-siwe-auth] Society RPC resolution error: #{e.message}")
      nil
    end

    def fetch_metadata(metadata_uri)
      url = normalize_url(metadata_uri)
      return nil if url.blank?

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10
      JSON.parse(http.request(Net::HTTP::Get.new(uri.request_uri)).body)
    rescue StandardError
      nil
    end

    def normalize_url(url)
      return nil if url.blank?
      url.start_with?('ipfs://') ? url.sub('ipfs://', 'https://ipfs.io/ipfs/') : url
    end
  end
end
```

Design notes:

- The draft wrapped the whole subgraph call in `rescue => e` with a log line
  missing a space (`error:#{e.message}`) — fixed above; use `warn` not `error`
  (identity resolution failing must never page anyone).
- Resolution **never raises** — every failure mode returns nil so login is
  never broken by Society Protocol being down.
- The subgraph `user.id` must be lowercased before querying (schema id is the
  lowercase address) — handled in `initialize`.

### 4.3 `plugin.rb` — registration block

Add to the existing `after_initialize` (do **not** create a second routes
block; extend the existing one):

```ruby
after_initialize do
  load File.expand_path('../app/controllers/discourse_siwe/auth_controller.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/eth_rpc.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/identity_resolver.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/ens_resolver.rb', __FILE__) # if extracted, see 4.1

  %w[
    wallet_address ens_name ens_avatar
    society_badge_id society_name society_avatar society_bio
    preferred_identity society_resolved_at
  ].each { |f| User.register_custom_field_type(f, :string) }

  # Expose identities to the owning user only (not publicly).
  add_to_serializer(:user, :web3_identities, include_condition: -> { scope.user == object }) do
    {
      wallet_address: object.custom_fields['wallet_address'],
      ens_name: object.custom_fields['ens_name'],
      ens_avatar: object.custom_fields['ens_avatar'],
      society_badge_id: object.custom_fields['society_badge_id'],
      society_name: object.custom_fields['society_name'],
      society_avatar: object.custom_fields['society_avatar'],
      society_bio: object.custom_fields['society_bio'],
      preferred_identity: object.custom_fields['preferred_identity'] || 'wallet',
    }
  end

  Discourse::Application.routes.prepend do
    get  '/discourse-siwe/auth'           => 'discourse_siwe/auth#index'
    get  '/discourse-siwe/message'        => 'discourse_siwe/auth#message'
    post '/discourse-siwe/update-identity' => 'discourse_siwe/auth#update_identity'
  end
end
```

(Verify the exact `include_condition` lambda form against the deployed
Discourse version's `add_to_serializer` API; older form is
`add_to_serializer(:user, :web3_identities) { ... }` plus an
`add_to_serializer(:user, :include_web3_identities?) { scope.user == object }`.)

### 4.4 `SiweAuthenticator` — corrected hooks

```ruby
class ::SiweAuthenticator < ::Auth::ManagedAuthenticator
  # ... existing methods unchanged ...

  # Runs on EVERY login (new and existing users).
  def after_authenticate(auth_token, existing_account: nil)
    result = super

    wallet = auth_token&.uid&.downcase
    return result unless wallet.present?

    info = auth_token[:info] || {}
    ens_name   = info[:nickname].presence
    ens_name   = nil if ens_name&.downcase == wallet
    ens_avatar = info[:image].presence

    if result.user
      # Existing user: cheap in-place updates only (no network calls here).
      cf = result.user.custom_fields
      cf['wallet_address'] ||= wallet
      cf['ens_name']   = ens_name   if ens_name
      cf['ens_avatar'] = ens_avatar if ens_avatar
      cf['preferred_identity'] ||= default_preference(cf)
      result.user.save_custom_fields
      enqueue_identity_refresh(result.user)   # throttled background job, §4.5
    else
      # New user: pass data through to after_create_account.
      result.extra_data = (result.extra_data || {}).merge(
        wallet_address: wallet,
        ens_name: ens_name,
        ens_avatar: ens_avatar,
      )
      # Auth-result name/avatar only affect account creation:
      result.name       = ens_name   if ens_name
      result.avatar_url = ens_avatar if ens_avatar
    end

    result
  end

  def after_create_account(user, auth_result)
    super
    extra = auth_result[:extra_data] || {}
    wallet = extra['wallet_address'] || extra[:wallet_address]
    return unless wallet.present?

    user.custom_fields['wallet_address'] = wallet.downcase
    user.custom_fields['ens_name']       = extra['ens_name']   || extra[:ens_name]
    user.custom_fields['ens_avatar']     = extra['ens_avatar'] || extra[:ens_avatar]

    society = DiscourseSiwe::IdentityResolver.resolve(wallet)   # inline, once
    store_society(user, society)

    user.custom_fields['preferred_identity'] = default_preference(user.custom_fields)
    user.save_custom_fields
  end

  private

  def default_preference(cf)
    if cf['society_name'].present? then 'society'
    elsif cf['ens_name'].present?  then 'ens'
    else 'wallet'
    end
  end

  def store_society(user, society)
    %w[badge_id name avatar bio].each do |k|
      user.custom_fields["society_#{k}"] = society&.[](k.to_sym)
    end
    user.custom_fields['society_resolved_at'] = Time.now.utc.iso8601
  end
end
```

Key differences from the draft:

- Wallet from `auth_token.uid`, ENS filtered when it equals the address.
- No `apply_preferred_identity` mutation of `result.username` for existing
  users — see §5 for what actually happens instead.
- No Society network call in the login path for existing users (moved to a
  throttled job). One inline call at account creation is acceptable.
- The draft's `sanitize_username` is dropped from the login path entirely —
  Discourse's own `UserNameSuggester` already handles usernames at signup.
  If we ever want Society/ENS names as suggested usernames for new signups,
  set `result.username` via `UserNameSuggester.suggest(...)` — optional,
  out of scope for v1 of this feature.

### 4.5 Throttled background refresh job

Create `app/jobs/regular/refresh_siwe_identity.rb` (plugin jobs dir is picked
up automatically via `after_initialize` load, same pattern as the controller):

```ruby
module Jobs
  class RefreshSiweIdentity < ::Jobs::Base
    def execute(args)
      user = User.find_by(id: args[:user_id])
      return unless user

      last = user.custom_fields['society_resolved_at']
      return if last.present? && Time.parse(last) > 24.hours.ago

      wallet = user.custom_fields['wallet_address']
      return unless wallet.present?

      society = DiscourseSiwe::IdentityResolver.resolve(wallet)
      SiweAuthenticator.send(:new).send(:store_society, user, society) # or extract store_society into a shared concern
      user.save_custom_fields
    end
  end
end
```

`enqueue_identity_refresh(user)` in the authenticator is simply
`Jobs.enqueue(:refresh_siwe_identity, user_id: user.id)` guarded by the same
24h check (so we don't flood the queue). Cleaner: extract
`store_society`/`default_preference` into `DiscourseSiwe::IdentityStore`
module used by both the authenticator and the job — do that instead of the
`send` hack shown inline above.

### 4.6 `update_identity` endpoint (`auth_controller.rb`)

Mostly as drafted, plus the part the draft missed — **applying** the choice:

```ruby
IDENTITIES = %w[wallet ens society].freeze

def update_identity
  raise Discourse::NotLoggedIn unless current_user

  preferred = params[:preferred_identity]
  return render json: { error: 'Invalid identity type' }, status: 400 unless IDENTITIES.include?(preferred)

  cf = current_user.custom_fields
  case preferred
  when 'ens'
    return render json: { error: 'No ENS name available' }, status: 400 if cf['ens_name'].blank?
  when 'society'
    return render json: { error: 'No Society identity available' }, status: 400 if cf['society_badge_id'].blank?
  end

  cf['preferred_identity'] = preferred
  current_user.save_custom_fields

  DiscourseSiwe::DisplayNameApplier.apply(current_user)   # §5
  current_user.save!

  render json: { success: true, preferred_identity: preferred }
end
```

Note `raise Discourse::NotLoggedIn` instead of a manual 401 JSON — idiomatic
Discourse, and CSRF is already enforced by `ApplicationController` for POSTs.

---

## 5. Display-name semantics (the gap in the draft)

The draft never defined what "Display name override based on preference"
actually does for an existing account. Fixed behavior:

- **Username: never changed by this feature.** Renaming breaks mentions,
  quotes, and permalinks. New users already get the ENS name suggested as
  username at signup via existing behavior (`info.nickname` → username
  suggestion); that stays.
- **`user.name` (display name):** set from the preferred identity:
  - `society` → `society_name`
  - `ens` → `ens_name`
  - `wallet` → truncated `0x1234…abcd` form
- **Avatar:** if the preferred identity has an avatar URL, enqueue Discourse's
  built-in `Jobs::DownloadAvatarFromUrl` for the user; on `wallet`, leave the
  existing avatar alone (no web3 avatar source).

Implement as `DiscourseSiwe::DisplayNameApplier.apply(user)` in
`lib/discourse_siwe/display_name_applier.rb`, called from
`update_identity` and from `after_create_account` (after fields are stored).
It must no-op gracefully when the preferred identity's name is blank.

---

## 6. Frontend changes

### 6.1 Component — valid Glimmer syntax

`assets/javascripts/discourse/components/siwe-identity-selector.gjs`
(Glimmer/gjs is the current Discourse standard; if the pinned Discourse
version predates `.gjs` in plugins, use the classic `.js` + `.hbs` pair
instead — verify on the test instance first):

```gjs
import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { ajax } from 'discourse/lib/ajax';
import { popupAjaxError } from 'discourse/lib/ajax-error';

export default class SiweIdentitySelector extends Component {
  @tracked saving = false;
  // this.args.model is the preferences user model; identities arrive
  // via model.web3_identities (serialized in §4.3)

  get identities() {
    const w = this.args.model.web3_identities;
    if (!w?.wallet_address) return [];
    const list = [
      { id: 'wallet', label: w.wallet_address, source: 'Wallet' },
    ];
    if (w.ens_name) list.push({ id: 'ens', label: w.ens_name, source: 'ENS', avatar: w.ens_avatar });
    if (w.society_badge_id) list.push({ id: 'society', label: w.society_name, source: 'Society Protocol', avatar: w.society_avatar });
    return list;
  }

  @action
  async select(id) {
    const previous = this.args.model.web3_identities.preferred_identity;
    if (id === previous || this.saving) return;
    this.saving = true;
    try {
      await ajax('/discourse-siwe/update-identity', {
        type: 'POST',
        data: { preferred_identity: id },
      });
      this.args.model.set('web3_identities.preferred_identity', id);
    } catch (e) {
      this.args.model.set('web3_identities.preferred_identity', previous); // real revert
      popupAjaxError(e);
    } finally {
      this.saving = false;
    }
  }

  <template>
    {{#if this.identities.length}}
      <div class="control-group siwe-identity-selector">
        <label class="control-label">{{i18n "discourse_siwe.identity.title"}}</label>
        <div class="controls">
          {{#each this.identities as |identity|}}
            <label class="identity-option">
              <input
                type="radio"
                name="preferred-identity"
                value={{identity.id}}
                checked={{eq identity.id @model.web3_identities.preferred_identity}}
                disabled={{this.saving}}
                {{on "change" (fn this.select identity.id)}}
              />
              <span class="identity-name">{{identity.label}}</span>
              <span class="identity-source">{{identity.source}}</span>
              {{#if identity.avatar}}
                <img src={{identity.avatar}} class="identity-preview" alt="" />
              {{/if}}
            </label>
          {{/each}}
        </div>
      </div>
    {{/if}}
  </template>
}
```

(The draft's emoji icons are dropped — match Discourse's UI conventions
instead. `eq`/`fn`/`on` are built-in helpers in current Discourse Ember.)

### 6.2 Render it into the preferences page

The draft's empty `modifyClass` renders nothing. Use a plugin-outlet
connector. In the deployed Discourse version, find the outlet in
`app/assets/javascripts/discourse/app/templates/preferences/profile.hbs`
(or the `preferences` wrapper), then add e.g.:

`assets/javascripts/discourse/connectors/user-preferences-profile-bottom/siwe-identity-selector.hbs`
```hbs
<SiweIdentitySelector @model={{@model}} />
```

⚠️ The exact outlet name must be verified by grepping the target Discourse
version's templates — do not assume `user-preferences-profile-bottom` exists.
This is the one frontend step that requires a live Discourse checkout to
confirm.

### 6.3 Styles + locales

- Add a `.siwe-identity-selector` block to
  `assets/stylesheets/discourse-siwe-auth.scss` (option rows, 24px avatar
  previews, muted source label).
- Add `js.discourse_siwe.identity.title: 'Web3 display identity'` (and option
  labels/errors) to `config/locales/client.en.yml`.

---

## 7. Migration (`lib/tasks/siwe_identities.rake`)

Fixes vs. draft: `assoc.info` → `assoc.extra`; ENS re-resolved via the shared
resolver instead of relying on association data; rate limiting; dry-run flag.

```ruby
namespace :siwe do
  desc 'Backfill web3 identity custom fields for existing SIWE users'
  task :migrate_identities, [:dry_run] => :environment do |_t, args|
    dry_run = args[:dry_run] == 'true'
    migrated = 0

    UserAssociatedAccount.where(provider_name: 'siwe').find_each do |assoc|
      user = assoc.user
      next unless user
      wallet = assoc.provider_uid&.downcase
      next if wallet.blank? || user.custom_fields['wallet_address'].present?

      puts "#{dry_run ? '[dry-run] ' : ''}Migrating #{user.username} (#{user.id})"

      unless dry_run
        user.custom_fields['wallet_address'] = wallet

        ens_name, ens_avatar = DiscourseSiwe::EnsResolver.resolve(wallet) # see 4.1 extraction
        user.custom_fields['ens_name']   = ens_name   if ens_name
        user.custom_fields['ens_avatar'] = ens_avatar if ens_avatar

        society = DiscourseSiwe::IdentityResolver.resolve(wallet)
        DiscourseSiwe::IdentityStore.store_society(user, society)
        user.custom_fields['preferred_identity'] =
          DiscourseSiwe::IdentityStore.default_preference(user.custom_fields)

        user.save_custom_fields
        DiscourseSiwe::DisplayNameApplier.apply(user)
        user.save!
        sleep 0.5  # be kind to the RPC/subgraph
      end
      migrated += 1
    end

    puts "Done. #{migrated} users #{dry_run ? 'would be' : ''} migrated."
  end
end
```

Notes:

- The draft applied no display name during migration. Decide explicitly:
  recommended default is to **only backfill fields + preference, not rewrite
  `user.name` for existing users** (surprise renames are worse than stale
  display names); their name updates next time they use the toggle or log in.
  Make this a task flag if desired.
- Users without a configured RPC get wallet-only fields — fine; the login-time
  refresh fills the rest later.

---

## 8. Tests (matching the repo's standalone minitest style)

New files, same pattern as `test/ens_unit_test.rb` / `test/ens_integration_test.rb`:

- `test/society_unit_test.rb` — no network:
  - `decode_uint256` / address+uint256 ABI encoding for
    `profileBadgeId`/`balanceOf`/`uri` calldata (assert exact calldata hex).
  - Subgraph response parsing: feed canned JSON payloads (with/without
    `profile`, missing user) into the parsing path (structure the resolver so
    parsing is a pure function — `IdentityResolver.parse_subgraph(json)`).
  - `normalize_url`: `ipfs://` → gateway, passthrough http(s), blank → nil.
  - `default_preference` priority: society > ens > wallet.
- `test/society_integration_test.rb` — needs `RPC_URL`; resolve a known
  mainnet address holding a Society profile badge (get one from the live
  subgraph first, e.g. one of the users returned by a test query) via `via_rpc`
  path, assert `badge_id` and `name` are present.
- Update `README.md` test list accordingly.

No Discourse test-suite (rspec) tests exist in this repo today — keep it that
way; standalone scripts are the established convention.

---

## 9. Also update

- `plugin.rb` header: version `1.2.1` → `1.3.0`, extend `about` text.
- `README.md`: new settings table rows, feature description, note that the
  Society subgraph/contract defaults point at mainnet.
- `config/locales/server.en.yml`: labels for the 4 new settings.

---

## 10. Open items to confirm on staging before production

1. The plugin-outlet name in `preferences/profile` (§6.2).
2. Exact `add_to_serializer` include-condition API form (§4.3).
3. `after_create_account` extra_data key stringification in the deployed
   Discourse version (code above tolerates both).
4. Whether `.gjs` components compile in plugins on the pinned Discourse
   version; fall back to classic component if not.
5. Whether Discourse's `Jobs::DownloadAvatarFromUrl` signature matches
   `(url:, user_id:)` on the deployed version.
6. Run the migration with `dry_run=true` first.

---

## 11. Implementation order

1. `config/settings.yml` + locales (§3, §9)
2. `lib/discourse_siwe/eth_rpc.rb` + minimal `siwe.rb` refactor; ENS extraction (§4.1)
3. `lib/discourse_siwe/identity_resolver.rb` (§4.2) + unit tests (§8)
4. `plugin.rb`: custom fields, serializer, route (§4.3)
5. `SiweAuthenticator` hooks + `IdentityStore` + refresh job (§4.4, §4.5)
6. `update_identity` + `DisplayNameApplier` (§4.6, §5)
7. Frontend: component, outlet connector, styles, locales (§6)
8. Migration rake task, dry-run on staging (§7, §10.6)
9. README + version bump (§9), then production deploy

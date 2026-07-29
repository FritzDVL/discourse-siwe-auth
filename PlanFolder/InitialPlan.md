### **SPEC: Society Protocol Identity Toggle for Discourse SIWE**

**Repository:** `https://github.com/SocietyProtocol/discourse-siwe-auth`**Discourse Version:** 2026.6.0-latest (production) / 2026.7.0-latest (test)**Scope:** Non-destructive enhancement for existing SIWE users

---

#### **1. Architecture Summary**

The existing fork already has:

- ✅ SIWE authentication (self-contained, no gem dependency issues)
- ✅ ENS resolution (forward+reverse verified)
- ✅ EIP-6492 smart wallet support (Coinbase Smart Wallet, Safe, etc.)

**What we add:**

- Society Protocol identity resolution (via subgraph or direct RPC)
- Custom user fields to store all identities
- User preference toggle in profile settings
- Display name override based on preference

---

#### **2. Data Model: Custom User Fields**

Create these fields for all SIWE users. Populate via one-time migration + ongoing login refresh.

**Table**

| **Field** | **Type** | **Source** | **Mutable** |
| --- | --- | --- | --- |
| `wallet_address` | string | `UserAssociatedAccount.provider_uid` | ❌ Immutable |
| `ens_name` | string | `resolve_ens()` in `siwe.rb` | ✅ |
| `ens_avatar` | string | `ens_avatar_url()` in `siwe.rb` | ✅ |
| `society_badge_id` | string | Subgraph/RPC: `profileBadgeId(address)` | ✅ |
| `society_name` | string | Badge metadata `name` | ✅ |
| `society_avatar` | string | Badge metadata `image` | ✅ |
| `society_bio` | string | Badge metadata `description` | ✅ |
| `preferred_identity` | string | User toggle: `wallet`/`ens`/`society` | ✅ |

---

#### **3. Plugin Settings (Add to `config/settings.yml`)**

**yaml**

```yaml
plugins:
  discourse_siwe_enabled:
    default: true
    client: true

  siwe_society_subgraph_url:
    default: ""
    client: false
    type: string
    description: "Society Protocol subgraph URL (optional, falls back to RPC)"

  siwe_society_rpc_url:
    default: "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
    client: false
    type: string
    description: "Ethereum RPC URL for direct contract calls"

  siwe_society_badges_contract:
    default: "0xa3af0da9733061da88b91ea28740780a887c8ce3"
    client: false
    type: string

  siwe_identity_resolution_mode:
    default: "subgraph"
    type: enum
    choices:
      - subgraph
      - rpc
    client: false
```

---

#### **4. Backend Changes**

#### **4.1 New File: `lib/discourse_siwe/identity_resolver.rb`**

**ruby**

```ruby
# frozen_string_literal: true

module DiscourseSiwe
  class IdentityResolver
    SOCIETY_BADGES_ABI = [
      {
        "inputs": [{ "name": "", "type": "address" }],
        "name": "profileBadgeId",
        "outputs": [{ "name": "", "type": "uint256" }],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          { "name": "account", "type": "address" },
          { "name": "id", "type": "uint256" }
        ],
        "name": "balanceOf",
        "outputs": [{ "name": "", "type": "uint256" }],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [{ "name": "id", "type": "uint256" }],
        "name": "uri",
        "outputs": [{ "name": "", "type": "string" }],
        "stateMutability": "view",
        "type": "function"
      }
    ].freeze

    def self.resolve(wallet_address)
      new(wallet_address).resolve
    end

    def initialize(wallet_address)
      @wallet_address = wallet_address.downcase
      @mode = SiteSetting.siwe_identity_resolution_mode
    end

    def resolve
      {
        ens: nil, # ENS is already resolved in siwe.rb strategy
        society: resolve_society
      }
    end

    private

    def resolve_society
      if @mode == "subgraph" && SiteSetting.siwe_society_subgraph_url.present?
        resolve_society_via_subgraph
      else
        resolve_society_via_rpc
      end
    end

    def resolve_society_via_subgraph
      query = <<~GRAPHQL
        query GetUser($address: ID!) {
          user(id: $address) {
            name
            bio
            imageUrl
            profile {
              id
              name
              imageUrl
              uri
            }
          }
        }GRAPHQL

      response = Excon.post(
        SiteSetting.siwe_society_subgraph_url,
        headers: { 'Content-Type' => 'application/json' },
        body: { query: query, variables: { address: @wallet_address } }.to_json,
        timeout: 10
      )

      data = JSON.parse(response.body)['data']['user'] rescue nil
      return nil unless data && data['profile']

      {
        badge_id: data['profile']['id'],
        name: data['name'] || data['profile']['name'],
        bio: data['bio'],
        avatar: data['imageUrl'] || data['profile']['imageUrl'],
        uri: data['profile']['uri']
      }
    rescue => e
      Rails.logger.error("Society Protocol subgraph error:#{e.message}")
      nil
    end

    def resolve_society_via_rpc
      # Uses the existing RPC infrastructure from siwe.rb
      # 1. Call profileBadgeId(address)
      # 2. Verify balanceOf(address, badgeId) > 0
      # 3. Call uri(badgeId)
      # 4. Fetch metadata from URI
      # Implementation follows same pattern as resolve_ens in siwe.rb
      nil # Placeholder — implement if subgraph unavailable
    end
  end
end
```

#### **4.2 Modify `plugin.rb`: Add Engine + Custom Fields**

Add to the `after_initialize` block:

**ruby**

```ruby
after_initialize do
  # Load existing files
  load File.expand_path('../app/controllers/discourse_siwe/auth_controller.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/identity_resolver.rb', __FILE__)

  # Register custom fields
  User.register_custom_field_type('wallet_address', :string)
  User.register_custom_field_type('ens_name', :string)
  User.register_custom_field_type('ens_avatar', :string)
  User.register_custom_field_type('society_badge_id', :string)
  User.register_custom_field_type('society_name', :string)
  User.register_custom_field_type('society_avatar', :string)
  User.register_custom_field_type('society_bio', :string)
  User.register_custom_field_type('preferred_identity', :string)

  # Add to user serializer for frontend access
  add_to_serializer(:user, :web3_identities) do
    {
      wallet_address: object.custom_fields['wallet_address'],
      ens_name: object.custom_fields['ens_name'],
      ens_avatar: object.custom_fields['ens_avatar'],
      society_badge_id: object.custom_fields['society_badge_id'],
      society_name: object.custom_fields['society_name'],
      society_avatar: object.custom_fields['society_avatar'],
      preferred_identity: object.custom_fields['preferred_identity'] || 'wallet'
    }
  end

  # Add routes
  Discourse::Application.routes.prepend do
    get '/discourse-siwe/auth' => 'discourse_siwe/auth#index'
    get '/discourse-siwe/message' => 'discourse_siwe/auth#message'
    post '/discourse-siwe/update-identity' => 'discourse_siwe/auth#update_identity'
  end
end
```

#### **4.3 Modify `SiweAuthenticator` in `plugin.rb`**

Override `after_authenticate` and `after_create_account`:

**ruby**

```ruby
class ::SiweAuthenticator < ::Auth::ManagedAuthenticator
  def name
    'siwe'
  end

  def register_middleware(omniauth)
    omniauth.provider :siwe, setup: lambda { |env|
      strategy = env['omniauth.strategy']
    }
  end

  def enabled?
    SiteSetting.discourse_siwe_enabled
  end

  def primary_email_verified?
    false
  end

  def description_for_auth_hash(auth_token)
    auth_token&.provider_uid || super
  end

  # === NEW: Identity resolution and storage ===

  def after_authenticate(auth_token, existing_account: nil)
    result = super

    wallet_address = auth_token.dig(:info, :name)
    return result unless wallet_address.present?

    # For existing users: refresh their identity data on every login
    if result.user
      refresh_user_identities(result.user, wallet_address)
      apply_preferred_identity(result, result.user)
    end

    # Pass identity data to after_create_account for new users
    result.extra_data = result.extra_data.merge({
      wallet_address: wallet_address,
      ens_name: auth_token.dig(:info, :nickname),
      ens_avatar: auth_token.dig(:info, :image),
      preferred_identity: 'ens' # Default new users to ENS if available
    })

    result
  end

  def after_create_account(user, auth_result)
    super

    extra = auth_result[:extra_data] || {}
    wallet_address = extra['wallet_address']
    return unless wallet_address.present?

    # Store all identity data
    user.custom_fields['wallet_address'] = wallet_address.downcase
    user.custom_fields['ens_name'] = extra['ens_name']
    user.custom_fields['ens_avatar'] = extra['ens_avatar']
    user.custom_fields['preferred_identity'] = extra['preferred_identity'] || 'wallet'

    # Resolve Society Protocol identity
    society_data = DiscourseSiwe::IdentityResolver.resolve(wallet_address)
    if society_data
      user.custom_fields['society_badge_id'] = society_data[:badge_id]
      user.custom_fields['society_name'] = society_data[:name]
      user.custom_fields['society_avatar'] = society_data[:avatar]
      user.custom_fields['society_bio'] = society_data[:bio]

      # If user has Society identity, default to it over ENS
      if society_data[:name].present?
        user.custom_fields['preferred_identity'] = 'society'
      end
    end

    user.save_custom_fields
  end

  private

  def refresh_user_identities(user, wallet_address)
    # Ensure wallet is always stored
    user.custom_fields['wallet_address'] ||= wallet_address.downcase

    # Refresh Society Protocol data (may have changed since last login)
    society_data = DiscourseSiwe::IdentityResolver.resolve(wallet_address)
    if society_data
      user.custom_fields['society_badge_id'] = society_data[:badge_id]
      user.custom_fields['society_name'] = society_data[:name]
      user.custom_fields['society_avatar'] = society_data[:avatar]
      user.custom_fields['society_bio'] = society_data[:bio]
    end

    # Set default preference if not already set
    if user.custom_fields['preferred_identity'].blank?
      if user.custom_fields['society_name'].present?
        user.custom_fields['preferred_identity'] = 'society'
      elsif user.custom_fields['ens_name'].present? && user.custom_fields['ens_name'] != wallet_address
        user.custom_fields['preferred_identity'] = 'ens'
      else
        user.custom_fields['preferred_identity'] = 'wallet'
      end
    end

    user.save_custom_fields
  end

  def apply_preferred_identity(result, user)
    pref = user.custom_fields['preferred_identity'] || 'wallet'

    case pref
    when 'society'
      if user.custom_fields['society_name'].present?
        result.username = sanitize_username(user.custom_fields['society_name'])
        result.name = user.custom_fields['society_name']
        result.avatar_url = user.custom_fields['society_avatar']
      end
    when 'ens'
      if user.custom_fields['ens_name'].present? && user.custom_fields['ens_name'] != user.custom_fields['wallet_address']
        result.username = sanitize_username(user.custom_fields['ens_name'])
        result.name = user.custom_fields['ens_name']
        result.avatar_url = user.custom_fields['ens_avatar']
      end
    when 'wallet'
      wallet = user.custom_fields['wallet_address']
      result.name = "#{wallet[0..5]}...#{wallet[-4..-1]}" if wallet.present?
    end
  end

  def sanitize_username(raw)
    return nil if raw.blank?
    raw.downcase
       .gsub('.', '_')        # ENS dots → underscores
       .gsub(/[^a-z0-9_-]/, '') # Only safe chars
       .slice(0, 60)
  end
end
```

#### **4.4 Add to Auth Controller: `update_identity` endpoint**

**ruby**

```ruby
# In app/controllers/discourse_siwe/auth_controller.rb

def update_identity
  return render json: { error: 'Not authenticated' }, status: 401 unless current_user

  preferred = params[:preferred_identity]
  allowed = %w[wallet ens society]

  unless allowed.include?(preferred)
    return render json: { error: 'Invalid identity type' }, status: 400
  end

  # Verify the user actually has this identity
  case preferred
  when 'ens'
    return render json: { error: 'No ENS name available' }, status: 400 unless current_user.custom_fields['ens_name'].present?
  when 'society'
    return render json: { error: 'No Society identity available' }, status: 400 unless current_user.custom_fields['society_badge_id'].present?
  end

  current_user.custom_fields['preferred_identity'] = preferred
  current_user.save_custom_fields

  render json: { success: true, preferred_identity: preferred }
end
```

---

#### **5. Frontend Changes**

#### **5.1 Add Identity Toggle UI to User Preferences**

Create a new component/template in the Discourse plugin:

**handlebars**

```
{{! assets/javascripts/discourse/templates/components/siwe-identity-selector.hbs }}

{{#if model.custom_fields.wallet_address}}
  <div class="control-group siwe-identity-selector">
    <label class="control-label">Web3 Display Identity</label>

    <div class="controls">
      {{! Wallet Address (always available) }}
      <label class="identity-option">
        <RadioButton
          @value="wallet"
          @selection={{model.custom_fields.preferred_identity}}
          @onChange={{action "selectIdentity" "wallet"}} />
        <span class="identity-icon">⬡</span>
        <span class="identity-name">{{model.custom_fields.wallet_address}}</span>
        <span class="identity-source">Wallet Address</span>
      </label>

      {{! ENS (if available) }}
      {{#if model.custom_fields.ens_name}}
        <label class="identity-option">
          <RadioButton
            @value="ens"
            @selection={{model.custom_fields.preferred_identity}}
            @onChange={{action "selectIdentity" "ens"}} />
          <span class="identity-icon">🌐</span>
          <span class="identity-name">{{model.custom_fields.ens_name}}</span>
          <span class="identity-source">ENS</span>
          {{#if model.custom_fields.ens_avatar}}
            <img src={{model.custom_fields.ens_avatar}} class="identity-preview" />
          {{/if}}
        </label>
      {{/if}}

      {{! Society Protocol (if available) }}
      {{#if model.custom_fields.society_badge_id}}
        <label class="identity-option">
          <RadioButton
            @value="society"
            @selection={{model.custom_fields.preferred_identity}}
            @onChange={{action "selectIdentity" "society"}} />
          <span class="identity-icon">🏛️</span>
          <span class="identity-name">{{model.custom_fields.society_name}}</span>
          <span class="identity-source">Society Protocol</span>
          {{#if model.custom_fields.society_avatar}}
            <img src={{model.custom_fields.society_avatar}} class="identity-preview" />
          {{/if}}
        </label>
      {{/if}}
    </div>
  </div>
{{/if}}
```

#### **5.2 JavaScript Controller**

**JavaScript**

```jsx
// assets/javascripts/discourse/components/siwe-identity-selector.js

import Component from "@ember/component";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";

export default Component.extend({
  @action
  selectIdentity(identity) {
    this.set('model.custom_fields.preferred_identity', identity);

    ajax('/discourse-siwe/update-identity', {
      type: 'POST',
      data: { preferred_identity: identity }
    }).then(() => {
      // Show success message
    }).catch((err) => {
      // Show error, revert selection
      this.set('model.custom_fields.preferred_identity', this.model.custom_fields.preferred_identity);
    });
  }
});
```

#### **5.3 Hook into User Preferences Page**

**JavaScript**

```jsx
// In plugin initializer
import { withPluginApi } from 'discourse/lib/plugin-api';

export default {
  name: 'siwe-identity-preferences',

  initialize() {
    withPluginApi('1.15.0', (api) => {
      // Add the identity selector to the profile preferences page
      api.modifyClass('controller:preferences/profile', {
        pluginId: 'siwe-identity-preferences',

        // The template will automatically pick up custom_fields from the model
      });
    });
  }
};
```

---

#### **6. One-Time Migration for Existing Users**

Run this in Rails console (or as a rake task):

**ruby**

```ruby
# lib/tasks/siwe_migrate_identities.rake

namespace :siwe do
  desc "Migrate existing SIWE users to new identity system"
  task migrate_identities: :environment do
    count = 0

    UserAssociatedAccount.where(provider_name: 'siwe').find_each do |assoc|
      user = assoc.user
      next unless user

      wallet = assoc.provider_uid.downcase

      # Skip if already migrated
      next if user.custom_fields['wallet_address'].present?

      # Store wallet address
      user.custom_fields['wallet_address'] = wallet

      # Extract ENS from existing auth data (if available in association)
      # The existing siwe.rb strategy already resolves ENS during login
      # If the user has logged in recently, the association info might have it
      ens_name = assoc.info&.dig('nickname')
      if ens_name.present? && ens_name != wallet
        user.custom_fields['ens_name'] = ens_name
        user.custom_fields['ens_avatar'] = assoc.info&.dig('image')
      end

      # Resolve Society Protocol identity
      society_data = DiscourseSiwe::IdentityResolver.resolve(wallet)
      if society_data
        user.custom_fields['society_badge_id'] = society_data[:badge_id]
        user.custom_fields['society_name'] = society_data[:name]
        user.custom_fields['society_avatar'] = society_data[:avatar]
        user.custom_fields['society_bio'] = society_data[:bio]
      end

      # Set default preference
      if society_data&.dig(:name).present?
        user.custom_fields['preferred_identity'] = 'society'
      elsif ens_name.present? && ens_name != wallet
        user.custom_fields['preferred_identity'] = 'ens'
      else
        user.custom_fields['preferred_identity'] = 'wallet'
      end

      user.save_custom_fields
      count += 1

      puts "Migrated user#{user.username} (ID:#{user.id}) with preference:#{user.custom_fields['preferred_identity']}"
    end

    puts "Migration complete.#{count} users migrated."
  end
end
```

---

#### **7. Testing Plan**

**Table**

| **Test** | **How** |
| --- | --- |
| **Migration dry-run** | Run on staging instance first, check console output |
| **New user signup** | Create fresh wallet, verify all identity fields populated |
| **Existing user login** | Verify identity refresh on login, preference preserved |
| **Toggle switch** | Change preference in UI, verify display name updates |
| **No Society identity** | Wallet without Society badge should show wallet/ENS only |
| **No ENS** | Wallet without ENS should show wallet/Society only |
| **No subgraph** | Set `siwe_identity_resolution_mode` to `rpc`, verify fallback |

---

#### **8. What You Need to Provide Your IDE Agent**

1. **This spec document** (copy-paste this entire message)
2. **The Society Protocol subgraph URL** — ask their engineer: "What's the GraphQL query endpoint for the web3-app-subgraph?"
3. **Your current `plugin.rb`** — confirm it's the one I fetched above
4. **Your current `siwe.rb`** — confirm it's the one with `resolve_ens` method
5. **Your Discourse version** — `2026.6.0-latest` (consider updating to `2026.7.0-latest` on test instance)

---

#### **9. Order of Implementation**

1. **Add custom field registration** to `plugin.rb`
2. **Create `identity_resolver.rb`** with subgraph integration
3. **Modify `SiweAuthenticator`** with `after_authenticate`/`after_create_account` overrides
4. **Add `update_identity` endpoint** to auth controller
5. **Build frontend toggle UI** (Ember component + template)
6. **Write migration rake task**
7. **Test on staging** → Deploy to production

---

Does this spec cover everything? Any part you want me to expand or simplify before you hand it to your IDE agent?
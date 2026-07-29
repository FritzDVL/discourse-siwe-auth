Directory structure:
└── societyprotocol-discourse-siwe-auth/
    ├── README.md
    ├── LICENSE-APACHE
    ├── LICENSE-MIT
    ├── package.json
    ├── plugin.rb
    ├── pnpm-lock.yaml
    ├── .discourse-compatibility
    ├── .prettierignore
    ├── .prettierrc
    ├── app/
    │   └── controllers/
    │       └── discourse_siwe/
    │           └── auth_controller.rb
    ├── assets/
    │   ├── javascripts/
    │   │   └── discourse/
    │   │       ├── siwe-route-map.js.es6
    │   │       ├── controllers/
    │   │       │   └── siwe-auth-index.js.es6
    │   │       ├── routes/
    │   │       │   └── siwe-auth-index.js.es6
    │   │       └── templates/
    │   │           └── siwe-auth-index.hbs
    │   └── stylesheets/
    │       └── discourse-siwe-auth.scss
    ├── config/
    │   ├── settings.yml
    │   └── locales/
    │       ├── client.en.yml
    │       └── server.en.yml
    ├── lib/
    │   └── omniauth/
    │       └── strategies/
    │           └── siwe.rb
    ├── test/
    │   ├── ens_integration_test.rb
    │   └── ens_unit_test.rb
    └── ui/
        ├── index.html
        ├── package.json
        ├── tsconfig.json
        ├── tsconfig.node.json
        ├── vite.config.ts
        └── src/
            ├── env.d.ts
            ├── main.ts
            ├── shadow.ts
            ├── SiweAuth.vue
            └── wagmi.ts


Files Content:

================================================
FILE: README.md
================================================
# Sign-In with Ethereum for Discourse

A Discourse plugin that lets users authenticate with their Ethereum wallet using
the [Sign-In with Ethereum (SIWE)](https://login.xyz) standard. Injected wallets
(MetaMask, Safe, etc.) work out of the box. ENS names and avatars are resolved
server-side when an RPC endpoint is configured.

> **About this fork.** This is a fork of
> [`signinwithethereum/discourse-siwe-auth`](https://github.com/signinwithethereum/discourse-siwe-auth)
> that fixes three install-time issues blocking installation on current Discourse
> (which now ships Ruby 3.4 inside the official `discourse/base` Docker image).
> See [Compatibility notes](#compatibility-notes-discourse--ruby-34) below.
> Tracking issue upstream:
> [signinwithethereum/discourse-siwe-auth#2](https://github.com/signinwithethereum/discourse-siwe-auth/issues/2).

## Requirements

- A Discourse forum that is self-hosted or hosted with a provider that supports
  third-party plugins, like [Communiteq](https://www.communiteq.com/).

## Installation

Access your container's `app.yml` file:

```bash
cd /var/discourse
nano containers/app.yml
```

Add a `before_code` hook to install `rubyzip` and an `after_code` hook to
clone the plugin:

```yml
hooks:
  before_code:
    - exec:
        cmd:
          - gem install rubyzip
  after_code:
    - exec:
      cd: $home/plugins
      cmd:
        - sudo -E -u discourse git clone https://github.com/discourse/docker_manager.git
        - sudo -E -u discourse git clone https://github.com/FritzDVL/discourse-siwe-auth.git # <-- added
```

### Why both hooks are needed

**`before_code` → `gem install rubyzip`**: the `rbsecp256k1` native crypto gem
this plugin depends on uses `rubyzip` inside its own `extconf.rb` to fetch and
unpack the libsecp256k1 C source during build. That happens at `bundle install`
time, *before* Discourse processes the `gem` directives in `plugin.rb`, so the
plugin's own gem block can't supply it in time. Installing `rubyzip`
system-wide in `before_code` guarantees it's on disk when the native
extension's build script runs.

**`after_code` → `sudo -E -u discourse git clone`**: always run the clone as
the unprivileged `discourse` user. On Ubuntu 24.04 a plain `git clone` runs as
`root` inside the container and produces files the Rails build cannot read,
which surfaces as a confusing failure during `./launcher rebuild app`. The
`-E` flag preserves the environment; `-u discourse` runs the command as the
user the rest of the Discourse build expects to own the plugin tree. Match the
exact form of the existing `docker_manager.git` line in your `app.yml`; if
that line is missing the prefix, your container is using an older layout —
add the prefix to both lines rather than dropping it from the new one.

Rebuild the container:

```bash
cd /var/discourse
./launcher rebuild app
```

## Configuration

After installation, find the plugin under **Admin > Plugins** and make sure it
is enabled:

![Installed plugins](/installed-plugins.png 'Installed plugins')

Click **Settings** to configure the plugin:

![Plugin settings](/settings.png 'Plugin settings')

From here you can customize the sign-in statement and optionally add a
WalletConnect / Reown project ID. Without a project ID, only injected wallets
(MetaMask, Safe, etc.) are available.

### Settings

| Setting | Description |
| --- | --- |
| **Discourse siwe enabled** | Enable or disable Sign-In with Ethereum authentication. |
| **Siwe ethereum rpc url** | _Optional._ An Ethereum JSON-RPC endpoint used for ENS name/avatar resolution and EIP-1271 signature verification (required for smart contract wallets like SAFE). A dedicated provider (Alchemy, Infura) is recommended. Example: `https://mainnet.infura.io/v3/YOUR_KEY`. |
| **Siwe project ID** | _Optional._ A WalletConnect / Reown project ID. Without it, only injected wallets (MetaMask, Safe, etc.) are available. To enable WalletConnect, create a free project ID at [dashboard.reown.com](https://dashboard.reown.com). |
| **Siwe statement** | The human-readable statement shown in the SIWE message. Defaults to "Sign in with Ethereum". |

## Compatibility notes (Discourse + Ruby 3.4)

Recent versions of Discourse ship Ruby 3.4 inside the official
`discourse/base` Docker image and pin `rubyzip` to the 3.x line. That
combination broke the install of upstream
[`signinwithethereum/discourse-siwe-auth`](https://github.com/signinwithethereum/discourse-siwe-auth)
(see issue [#2](https://github.com/signinwithethereum/discourse-siwe-auth/issues/2)).
This fork fixes three distinct issues in `plugin.rb` so that `./launcher
rebuild app` completes cleanly. They are documented here so the changes
make sense to anyone reading the diff.

### 1. Discourse's plugin `gem` DSL needs an explicit version string

Discourse's plugin loader exposes a `gem` DSL whose signature is
`gem(name, version, opts = {})`, and it shells out to
`gem install ... --ignore-dependencies` under the hood. The original
plugin used short forms like `gem 'eth', require: false` (no version
arg). On Ruby 3.x that makes RubyGems treat the keyword-arguments hash
as the `version` argument, producing:

```
ERROR:  While executing gem ... (Gem::Requirement::BadRequirementError)
    Illformed requirement ["{require:"]
```

Every gem line in `plugin.rb` therefore now carries an explicit version
string as its second positional argument, e.g.
`gem 'eth', '0.5.17', require: false`.

### 2. Every transitive dependency must be declared explicitly

Because Discourse passes `--ignore-dependencies` to `gem install`,
RubyGems will not pull in transitive deps automatically. Two consequences
on Ruby 3.4:

- **`base64` is no longer a default gem** in Ruby 3.4 (it was demoted to
  a bundled gem). `eth >= 0.5.16` is the first version that explicitly
  depends on `base64`, so it must be listed in `plugin.rb`.
- The `eth` / `siwe` gems also need their full subgraph listed in
  install order: `ecdsa`, `h2c`, `bls12-381`, `http-2`, `httpx`. Same
  reasoning applies to lower-level build deps (`pkg-config`,
  `mini_portile2`, `ffi`, `ffi-compiler`, `konstructor`).

### 3. `rbsecp256k1`'s spurious `rubyzip ~> 2.3` runtime dep

The `rbsecp256k1` gem (which `eth` uses for ECDSA signature
recovery/verification) declares a runtime dependency on
`rubyzip ~> 2.3` in its `.gemspec`. In reality, `rubyzip` is only used
inside `rbsecp256k1`'s `extconf.rb` to download and unpack the
libsecp256k1 C source archive at **build time** — it has zero runtime
use of rubyzip. This is an upstream bug in `rbsecp256k1`'s gemspec and
every published version since 5.0.0 carries it.

Discourse's main bundle now pins `rubyzip 3.2.2`. So when Discourse's
plugin loader calls `Gem::Specification#activate` on `rbsecp256k1`
during boot, RubyGems sees the active rubyzip 3.x and the
`~> 2.3` constraint refuses to resolve, raising:

```
Gem::ConflictError: Unable to activate rbsecp256k1-6.0.0,
because rubyzip-3.2.2 conflicts with rubyzip (~> 2.3)
```

(`--ignore-dependencies` skips install-time resolution but RubyGems
still validates deps at activation time, so we can't simply ignore it.)

The workaround in `plugin.rb` does three things, all idempotent across
container rebuilds:

1. Pre-install `rbsecp256k1` ourselves into the plugin's gem dir using
   `Bundler.with_unbundled_env { system('gem install ...') }`.
2. Open the installed `.gemspec` on disk and strip exactly the line
   `s.add_runtime_dependency(%q<rubyzip>.freeze, ["~> 2.3".freeze])`
   using a precise regex (atomic temp-file + rename so a concurrent
   reader can never see a half-written file).
3. Call `Gem::Specification.reset` to invalidate the cached spec, then
   declare `gem 'rbsecp256k1', '6.0.0', require: false` normally.
   Discourse's plugin loader sees the gem already installed, reads the
   patched spec, and activates it without conflict. A
   `Rails.logger.info` line is emitted when the patch is applied so the
   shim is visible in production logs.

`rubyzip` still needs to be on the system gem path for
`rbsecp256k1`'s `extconf.rb` to succeed at build time, which is why
the `before_code: gem install rubyzip` hook in `app.yml` is still
required (see [Installation](#installation) above).

## Tests

The plugin includes unit and integration tests for ENS resolution helpers and
EIP-6492 smart wallet signature verification.

### Unit tests (no network needed)

```bash
ruby test/ens_unit_test.rb
ruby test/smart_wallet_unit_test.rb
```

### Integration tests (require an Ethereum RPC endpoint)

```bash
ruby test/ens_integration_test.rb
ruby test/smart_wallet_integration_test.rb
```

By default, integration tests use a public RPC. Set `RPC_URL` for a dedicated
provider:

```bash
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY ruby test/smart_wallet_integration_test.rb
```

### Run all tests

```bash
for f in test/*_test.rb; do ruby "$f"; done
```

## How it works

When a user clicks the Ethereum login button, the plugin opens a dedicated
authentication. The user connects their wallet, signs a SIWE message,
and is authenticated via an OmniAuth strategy on the server side.

After first sign-in, users are asked to associate an email address with their
account. If an RPC URL is configured and the connected address has an ENS name,
the name is resolved and verified server-side and suggested as the default
username. ENS avatars are fetched via the ENS metadata service and used as the
profile photo.

Alternatively, existing users can connect their Ethereum accounts via
their profile settings.



================================================
FILE: LICENSE-APACHE
================================================
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2021 Spruce Systems Inc.
   Copyright 2026 EthID.org

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.


================================================
FILE: LICENSE-MIT
================================================
MIT License

Copyright (c) 2021 Spruce Systems, Inc.
Copyright (c) 2026 EthID.org

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


================================================
FILE: package.json
================================================
{
  "private": true,
  "scripts": {
    "format": "prettier --write .",
    "format:check": "prettier --check ."
  },
  "devDependencies": {
    "prettier": "^3.8.1"
  }
}



================================================
FILE: plugin.rb
================================================
# frozen_string_literal: true

# name: discourse-siwe-auth
# about: Authenticate users via the Sign In with Ethereum (SIWE) standard
# version: 1.2.1
# authors: EthID
# url: https://siwe.xyz

enabled_site_setting :discourse_siwe_enabled
register_svg_icon 'fab-ethereum'
register_asset 'stylesheets/discourse-siwe-auth.scss'

%w[
  ../lib/omniauth/strategies/siwe.rb
].each { |path| load File.expand_path(path, __FILE__) }

# Discourse's plugin `gem` DSL signature is `gem(name, version, opts = {})` and
# it shells out to `gem install ... --ignore-dependencies`, so:
#   1) every gem MUST have an explicit version string as the 2nd positional arg
#      (passing `require: false` without a version makes Ruby treat the kwargs
#      hash as the version, breaking install with "Illformed requirement"),
#   2) every transitive dependency must be declared explicitly here in
#      install order (deps before dependents), since --ignore-dependencies
#      means Discourse will not auto-resolve them.
# `rubyzip` (a build-time dep of rbsecp256k1's extconf.rb) is installed
# system-wide via the `before_code` hook in app.yml; see README.

gem 'pkg-config',    '1.6.5',  require: false
gem 'mini_portile2', '2.8.9',  require: false
gem 'ffi',           '1.17.4', require: false
gem 'ffi-compiler',  '1.3.2',  require: false
gem 'konstructor',   '1.0.2',  require: false
gem 'scrypt',        '3.1.0',  require: false
gem 'keccak',        '1.3.3',  require: false

# rbsecp256k1 6.0.0 (and every published version since 5.0.0) declares a
# spurious runtime dependency on `rubyzip ~> 2.3`. It only uses rubyzip in
# its `extconf.rb` to unpack libsecp256k1's source archive at build time —
# it has zero runtime use of rubyzip. But Discourse's main bundle activates
# rubyzip 3.x at boot, so when Discourse's plugin DSL calls `spec.activate`
# on rbsecp256k1, RubyGems raises Gem::ConflictError.
#
# Workaround: pre-install rbsecp256k1 ourselves and strip the bogus rubyzip
# line from the installed gemspec on disk. Discourse's plugin loader then
# sees the gem already installed, loads the patched spec, and activates it
# without conflict. Idempotent across rebuilds.
RBSECP256K1_VERSION = '6.0.0'
rbsecp_gems_dir = File.expand_path("../gems/#{RUBY_VERSION}", __FILE__)
rbsecp_spec_file = "#{rbsecp_gems_dir}/specifications/rbsecp256k1-#{RBSECP256K1_VERSION}.gemspec"

unless File.exist?(rbsecp_spec_file)
  install_cmd = "gem install rbsecp256k1 -v #{RBSECP256K1_VERSION} " \
                "-i #{rbsecp_gems_dir} --no-document " \
                "--ignore-dependencies --no-user-install"
  Bundler.with_unbundled_env { system(install_cmd) } ||
    raise("rbsecp256k1 #{RBSECP256K1_VERSION} pre-install failed")
end

# Precise pattern: only the exact add_runtime_dependency line for rubyzip.
# Avoids accidentally stripping other lines if upstream changes formatting.
rbsecp_rubyzip_dep_re =
  /^\s*s\.add_runtime_dependency\(?\s*%q<rubyzip>.*?\)?\s*\n/
rbsecp_spec_content = File.read(rbsecp_spec_file)
if rbsecp_spec_content =~ rbsecp_rubyzip_dep_re
  patched = rbsecp_spec_content.sub(rbsecp_rubyzip_dep_re, '')
  # Atomic replace via tempfile + rename so a concurrent reader never sees a
  # half-written gemspec.
  tmp = "#{rbsecp_spec_file}.patching.#{Process.pid}"
  File.write(tmp, patched)
  File.rename(tmp, rbsecp_spec_file)
  Gem::Specification.reset
  Rails.logger.info(
    "[discourse-siwe-auth] Stripped spurious rubyzip runtime dep from " \
    "rbsecp256k1-#{RBSECP256K1_VERSION}.gemspec to avoid Gem::ConflictError " \
    "with Discourse's bundled rubyzip."
  ) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
end

gem 'rbsecp256k1', RBSECP256K1_VERSION, require: false

# eth >= 0.5.16 is the first version that explicitly depends on `base64`,
# which Ruby 3.4 demoted from default-gem to bundled-gem. Its full transitive
# closure (bls12-381, httpx, etc.) must be declared since --ignore-dependencies
# prevents auto-install.
gem 'base64',        '0.3.0',  require: false
gem 'ecdsa',         '1.2.0',  require: false
gem 'h2c',           '0.2.1',  require: false
gem 'bls12-381',     '0.3.1',  require: false
gem 'http-2',        '1.1.3',  require: false
gem 'httpx',         '1.7.6',  require: false
gem 'eth',           '0.5.17', require: false
gem 'siwe',          '1.1.2',  require: false

class ::SiweAuthenticator < ::Auth::ManagedAuthenticator
  def name
    'siwe'
  end

  def register_middleware(omniauth)
    omniauth.provider :siwe,
                      setup: lambda { |env|
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
end

auth_provider authenticator: ::SiweAuthenticator.new,
              icon: 'fab-ethereum',
              title_setting: :siwe_statement,
              full_screen_login: true

after_initialize do
  load File.expand_path('../app/controllers/discourse_siwe/auth_controller.rb', __FILE__)

  Discourse::Application.routes.prepend do
    get '/discourse-siwe/auth' => 'discourse_siwe/auth#index'
    get '/discourse-siwe/message' => 'discourse_siwe/auth#message'
  end
end



================================================
FILE: pnpm-lock.yaml
================================================
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true
  excludeLinksFromLockfile: false

importers:
  .:
    devDependencies:
      prettier:
        specifier: ^3.8.1
        version: 3.8.1

packages:
  prettier@3.8.1:
    resolution:
      {
        integrity: sha512-UOnG6LftzbdaHZcKoPFtOcCKztrQ57WkHDeRD9t/PTQtmT0NHSeWWepj6pS0z/N7+08BHFDQVUrfmfMRcZwbMg==,
      }
    engines: { node: '>=14' }
    hasBin: true

snapshots:
  prettier@3.8.1: {}



================================================
FILE: .discourse-compatibility
================================================
[Empty file]


================================================
FILE: .prettierignore
================================================
public
ui/dist



================================================
FILE: .prettierrc
================================================
{
  "singleAttributePerLine": true,
  "singleQuote": true,
  "semi": false
}



================================================
FILE: app/controllers/discourse_siwe/auth_controller.rb
================================================
# frozen_string_literal: true

require 'siwe'
module DiscourseSiwe
  class AuthController < ::ApplicationController
    skip_before_action :check_xhr, only: %i[index]
    skip_before_action :redirect_to_login_if_required, only: %i[index message]

    def index
      raise ApplicationController::RenderEmpty
    end

    def message
      eth_account = params[:eth_account]
      chain_id = params[:chain_id]

      unless eth_account.present? && eth_account.match?(/\A0x[0-9a-fA-F]{40}\z/)
        return render json: { error: "Invalid Ethereum address" }, status: 400
      end

      unless chain_id.present? && chain_id.match?(/\A[1-9][0-9]*\z/)
        return render json: { error: "Invalid chain ID" }, status: 400
      end

      now = Time.now.utc
      domain = Discourse.base_url.delete_prefix("#{Discourse.base_protocol}://")
      message = Siwe::Message.new(domain, eth_account, Discourse.base_url, "1", {
        issued_at: now.iso8601,
        expiration_time: (now + 300).iso8601,
        statement: SiteSetting.siwe_statement,
        nonce: Siwe::Util.generate_nonce,
        chain_id: chain_id,
      })
      session[:nonce] = message.nonce

      render json: { message: message.prepare_message }
    end
  end
end



================================================
FILE: assets/javascripts/discourse/siwe-route-map.js.es6
================================================
export default function () {
  this.route('siwe-auth', { path: '/discourse-siwe/auth' }, function () {
    this.route('index', { path: '/' })
  })
}



================================================
FILE: assets/javascripts/discourse/controllers/siwe-auth-index.js.es6
================================================
import Controller from '@ember/controller'
import { withPluginApi } from 'discourse/lib/plugin-api'
import loadScript from 'discourse/lib/load-script'

export default Controller.extend({
  init() {
    this._super(...arguments)
    this.initAuth()
  },

  async initAuth() {
    const settings = withPluginApi('0.11.7', (api) => {
      const siteSettings = api.container.lookup('site-settings:main')
      return {
        projectId: siteSettings.siwe_project_id,
        statement: siteSettings.siwe_statement,
      }
    })

    const csrfToken =
      document
        .querySelector('meta[name="csrf-token"]')
        ?.getAttribute('content') || ''

    await loadScript('/plugins/discourse-siwe-auth/javascripts/siwe.iife.js')

    if (window.mountSiwe) {
      window.mountSiwe('#siwe-mount', {
        csrfToken,
        callbackUrl: '/auth/siwe/callback',
        messageUrl: '/discourse-siwe/message',
        walletConnectProjectId: settings.projectId,
        statement: settings.statement,
      })
    }
  },
})



================================================
FILE: assets/javascripts/discourse/routes/siwe-auth-index.js.es6
================================================
import Route from '@ember/routing/route'

export default Route.extend()



================================================
FILE: assets/javascripts/discourse/templates/siwe-auth-index.hbs
================================================
{{! {{hide-application-header}}
{{! {{hide-application-sidebar}}
{{body-class 'siwe-login-page'}}
{{hideApplicationHeaderButtons 'search' 'login' 'signup' 'menu'}}
{{hideApplicationSidebar}}
{{! {{bodyClass "login-page"}}
{{bodyClass 'siwe-login-page'}}

<form
  id='siwe-sign'
  method='POST'
  action='/auth/siwe/callback'
  style='display: none;'
>
  <textarea id='eth_message' name='eth_message'></textarea>
  <textarea id='eth_signature' name='eth_signature'></textarea>
</form>

<div id='siwe-mount' class='siwe-mount'></div>


================================================
FILE: assets/stylesheets/discourse-siwe-auth.scss
================================================
.siwe-login-page {
  .d-header {
    background-color: var(--secondary);
    box-shadow: none;
    .wrap {
      width: auto;
    }
  }

  .discourse-root {
    min-height: 100dvh;
  }

  .main-outlet-wrapper {
    height: calc(100dvh - var(--header-offset));
  }

  .powered-by-discourse {
    display: none;
  }
}

.siwe-mount {
  background-color: var(--secondary);
  max-width: 24rem;
  margin-inline: auto;
  scrollbar-gutter: auto;
  min-height: calc(100dvh - 10rem);
  display: grid;
  align-items: center;
}



================================================
FILE: config/settings.yml
================================================
discourse_siwe:
  discourse_siwe_enabled:
    default: true
  siwe_project_id:
    client: true
    default: ''
  siwe_ethereum_rpc_url:
    default: ''
  siwe_statement:
    client: true
    default: 'Sign in with Ethereum'



================================================
FILE: config/locales/client.en.yml
================================================
en:
  admin_js:
    admin:
      site_settings:
        categories:
          discourse_siwe: 'Sign in With Ethereum'
  js:
    login:
      siwe:
        name: 'SIWE'
        title: 'Sign in with Ethereum'



================================================
FILE: config/locales/server.en.yml
================================================
en:
  site_settings:
    discourse_siwe_enabled: 'Enable Sign In With Ethereum authentication'
    siwe_project_id: 'Project ID for Web3Modal'
    siwe_ethereum_rpc_url: 'Ethereum RPC URL — required for ENS name/avatar resolution and EIP-1271 smart contract wallet verification (e.g. SAFE). A dedicated endpoint (Alchemy, Infura) is recommended.'
    siwe_statement: 'Statement that will be displayed in the SIWE message'



================================================
FILE: lib/omniauth/strategies/siwe.rb
================================================
require 'net/http'
require 'json'

module OmniAuth
  module Strategies
    class Siwe
      include OmniAuth::Strategy

      # ENS Registry contract address (same on all networks)
      ENS_REGISTRY = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"

      # EIP-6492 universal signature validator bytecode (no 0x prefix).
      # Deployed via eth_call (no actual deployment) to verify EOA, ERC-1271,
      # and EIP-6492 signatures in a single call.
      # Constructor: (address signer, bytes32 hash, bytes signature)
      # Returns: 0x01 if valid, 0x00 if invalid
      # Source: EIP-6492 reference implementation
      EIP6492_VALIDATOR_BYTECODE = "608060405234801561001057600080fd5b5060405161069438038061069483398101604081905261002f9161051e565b600061003c848484610048565b9050806000526001601ff35b60007f64926492649264926492649264926492649264926492649264926492649264926100748361040c565b036101e7576000606080848060200190518101906100929190610577565b60405192955090935091506000906001600160a01b038516906100b69085906105dd565b6000604051808303816000865af19150503d80600081146100f3576040519150601f19603f3d011682016040523d82523d6000602084013e6100f8565b606091505b50509050876001600160a01b03163b60000361016057806101605760405162461bcd60e51b815260206004820152601e60248201527f5369676e617475726556616c696461746f723a206465706c6f796d656e74000060448201526064015b60405180910390fd5b604051630b135d3f60e11b808252906001600160a01b038a1690631626ba7e90610190908b9087906004016105f9565b602060405180830381865afa1580156101ad573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906101d19190610633565b6001600160e01b03191614945050505050610405565b6001600160a01b0384163b1561027a57604051630b135d3f60e11b808252906001600160a01b03861690631626ba7e9061022790879087906004016105f9565b602060405180830381865afa158015610244573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906102689190610633565b6001600160e01b031916149050610405565b81516041146102df5760405162461bcd60e51b815260206004820152603a602482015260008051602061067483398151915260448201527f3a20696e76616c6964207369676e6174757265206c656e6774680000000000006064820152608401610157565b6102e7610425565b5060208201516040808401518451859392600091859190811061030c5761030c61065d565b016020015160f81c9050601b811480159061032b57508060ff16601c14155b1561038c5760405162461bcd60e51b815260206004820152603b602482015260008051602061067483398151915260448201527f3a20696e76616c6964207369676e617475726520762076616c756500000000006064820152608401610157565b60408051600081526020810180835289905260ff83169181019190915260608101849052608081018390526001600160a01b0389169060019060a0016020604051602081039080840390855afa1580156103ea573d6000803e3d6000fd5b505050602060405103516001600160a01b0316149450505050505b9392505050565b600060208251101561041d57600080fd5b508051015190565b60405180606001604052806003906020820280368337509192915050565b6001600160a01b038116811461045857600080fd5b50565b634e487b7160e01b600052604160045260246000fd5b60005b8381101561048c578181015183820152602001610474565b50506000910152565b600082601f8301126104a657600080fd5b81516001600160401b038111156104bf576104bf61045b565b604051601f8201601f19908116603f011681016001600160401b03811182821017156104ed576104ed61045b565b60405281815283820160200185101561050557600080fd5b610516826020830160208701610471565b949350505050565b60008060006060848603121561053357600080fd5b835161053e81610443565b6020850151604086015191945092506001600160401b0381111561056157600080fd5b61056d86828701610495565b9150509250925092565b60008060006060848603121561058c57600080fd5b835161059781610443565b60208501519093506001600160401b038111156105b357600080fd5b6105bf86828701610495565b604086015190935090506001600160401b0381111561056157600080fd5b600082516105ef818460208701610471565b9190910192915050565b828152604060208201526000825180604084015261061e816060850160208701610471565b601f01601f1916919091016060019392505050565b60006020828403121561064557600080fd5b81516001600160e01b03198116811461040557600080fd5b634e487b7160e01b600052603260045260246000fdfe5369676e617475726556616c696461746f72237265636f7665725369676e6572"

      option :fields, %i[eth_message eth_signature]

      uid do
        @verified_address
      end

      info do
        ens_name, ens_avatar = resolve_ens(@verified_address)
        display_name = ens_name || @verified_address
        {
          nickname: display_name,
          name: display_name,
          image: ens_avatar
        }
      end

      def request_phase
        query_string = env['QUERY_STRING']
        redirect "/discourse-siwe/auth?#{query_string}"
      end

      def callback_phase
        eth_message_crlf = request.params['eth_message']
        eth_message = eth_message_crlf.encode(eth_message_crlf.encoding, universal_newline: true)
        eth_signature = request.params['eth_signature']
        siwe_message = ::Siwe::Message.from_message(eth_message)

        domain = Discourse.base_url.delete_prefix("#{Discourse.base_protocol}://")
        if siwe_message.domain != domain
          return fail!("Invalid domain")
        end

        nonce = session.delete(:nonce)
        if siwe_message.nonce != nonce
          return fail!("Invalid nonce")
        end

        @verified_address = siwe_message.address

        failure_reason = nil
        begin
          siwe_message.validate(eth_signature)
        rescue ::Siwe::ExpiredMessage
          failure_reason = :expired_message
        rescue ::Siwe::NotValidMessage
          failure_reason = :invalid_message
        rescue ::Siwe::InvalidSignature
          # EOA verification failed — try EIP-6492 universal validator which handles
          # both deployed wallets (EIP-1271, e.g. Safe) and undeployed accounts
          # (EIP-6492, e.g. Coinbase Smart Wallet)
          unless smart_wallet_valid?(siwe_message, eth_signature)
            failure_reason = :invalid_signature
          end
        end

        return fail!(failure_reason) if failure_reason

        super
      end

      private

      def rpc_url
        url = SiteSetting.siwe_ethereum_rpc_url rescue nil
        url if url && !url.empty?
      end

      # Build a reusable HTTP connection to the configured RPC endpoint.
      def rpc_connection
        uri = URI(rpc_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 10
        http
      end

      # Generic JSON-RPC eth_call. Returns hex result without 0x prefix, or nil.
      # When +to+ is nil the call simulates contract creation (used by EIP-6492).
      # Accepts an optional +http+ connection for reuse across sequential calls.
      def eth_call(to, data, http: nil)
        return nil unless rpc_url

        http ||= rpc_connection
        path = URI(rpc_url).path
        path = '/' if path.empty?
        req = Net::HTTP::Post.new(path, 'Content-Type' => 'application/json')
        call_params = { data: data }
        call_params[:to] = to if to
        req.body = {
          jsonrpc: "2.0",
          method: "eth_call",
          params: [call_params, "latest"],
          id: 1
        }.to_json

        response = http.request(req)
        result = JSON.parse(response.body)
        return nil if result['error'] || result['result'].nil? || result['result'] == '0x'

        Eth::Util.remove_hex_prefix(result['result'])
      rescue StandardError
        nil
      end

      # Universal smart-wallet signature verification using the EIP-6492
      # off-chain validator. A single eth_call (contract creation simulation)
      # that handles deployed EIP-1271 wallets (e.g. Safe) AND undeployed
      # ERC-4337 accounts (e.g. Coinbase Smart Wallet) in one shot.
      def smart_wallet_valid?(siwe_message, signature)
        return false unless rpc_url

        # Hash the message the same way personal_sign does (EIP-191)
        prefixed = Eth::Signature.prefix_message(siwe_message.prepare_message)
        message_hash = Eth::Util.bin_to_hex(Eth::Util.keccak256(prefixed))

        # ABI-encode constructor args: (address signer, bytes32 hash, bytes signature)
        address_param = Eth::Util.remove_hex_prefix(siwe_message.address).downcase.rjust(64, '0')
        hash_param = message_hash.rjust(64, '0')
        sig_bytes = Eth::Util.remove_hex_prefix(signature)
        # bytes offset: 3 × 32 = 96 = 0x60
        bytes_offset = "0000000000000000000000000000000000000000000000000000000000000060"
        sig_length = (sig_bytes.length / 2).to_s(16).rjust(64, '0')
        sig_padded = sig_bytes.ljust(((sig_bytes.length + 63) / 64) * 64, '0')

        data = "0x#{EIP6492_VALIDATOR_BYTECODE}#{address_param}#{hash_param}#{bytes_offset}#{sig_length}#{sig_padded}"

        # eth_call with no 'to' simulates contract creation
        result = eth_call(nil, data)
        return false if result.nil?

        # Validator returns 0x01 (possibly zero-padded to 32 bytes) for valid
        result.gsub(/\A0+/, '') == '1'
      end

      # Compute ENS namehash for a domain name
      def ens_namehash(name)
        node = "\x00" * 32
        unless name.nil? || name.empty?
          name.split('.').reverse.each do |label|
            label_hash = Eth::Util.keccak256(label)
            node = Eth::Util.keccak256(node + label_hash)
          end
        end
        Eth::Util.bin_to_hex(node)
      end

      # Decode an ABI-encoded address return value
      def abi_decode_address(hex)
        return nil if hex.nil? || hex.length < 40
        address = hex[-40, 40]
        return nil if address == '0' * 40
        "0x#{address}"
      end

      # Decode an ABI-encoded string return value
      def abi_decode_string(hex)
        return nil if hex.nil? || hex.length < 128
        offset = hex[0, 64].to_i(16) * 2
        length = hex[offset, 64].to_i(16)
        return '' if length == 0
        data_start = offset + 64
        return nil if hex.length < data_start + length * 2
        [hex[data_start, length * 2]].pack('H*').force_encoding('UTF-8')
      end

      # Resolve ENS name and avatar for an Ethereum address.
      # Returns [name, avatar_url] or [nil, nil].
      def resolve_ens(address)
        return [nil, nil] unless rpc_url

        http = rpc_connection
        http.start do
          # Step 1: Reverse resolve address → name
          addr_clean = Eth::Util.remove_hex_prefix(address).downcase
          reverse_node = ens_namehash("#{addr_clean}.addr.reverse")

          # Get resolver for the reverse node from ENS registry
          resolver_hex = eth_call(ENS_REGISTRY, "0x0178b8bf#{reverse_node}", http: http)
          resolver = abi_decode_address(resolver_hex)
          return [nil, nil] unless resolver

          # Get the name from the reverse resolver
          name_hex = eth_call(resolver, "0x691f3431#{reverse_node}", http: http)
          name = abi_decode_string(name_hex)
          return [nil, nil] if name.nil? || name.empty?

          # Step 2: Forward verify — resolve name back to address to prevent spoofing
          forward_node = ens_namehash(name)
          fwd_resolver_hex = eth_call(ENS_REGISTRY, "0x0178b8bf#{forward_node}", http: http)
          fwd_resolver = abi_decode_address(fwd_resolver_hex)
          return [nil, nil] unless fwd_resolver

          addr_hex = eth_call(fwd_resolver, "0x3b3b57de#{forward_node}", http: http)
          resolved_addr = abi_decode_address(addr_hex)
          return [nil, nil] unless resolved_addr&.downcase == address.downcase

          [name, ens_avatar_url(name)]
        end
      rescue StandardError
        [nil, nil]
      end

      # Returns the ENS metadata avatar URL if it exists, nil otherwise.
      def ens_avatar_url(name)
        url = "https://metadata.ens.domains/mainnet/avatar/#{name}"
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5
        response = http.request(Net::HTTP::Head.new(uri.path))
        response.code.to_i == 200 ? url : nil
      rescue StandardError
        nil
      end
    end
  end
end



================================================
FILE: test/ens_integration_test.rb
================================================
#!/usr/bin/env ruby
# Integration test: resolves a known ENS name against a real Ethereum RPC.
#
# Usage:
#   ruby test/ens_integration_test.rb                               # uses default public RPC
#   RPC_URL=https://eth-mainnet.g.alchemy.com/v2/KEY ruby test/ens_integration_test.rb
#
# Tests against jalil.eth, which has a reverse record and avatar.

require 'net/http'
require 'json'

$LOAD_PATH.unshift(*Dir[File.join(__dir__, '..', 'gems/3.4.8/gems/keccak-*/lib')])
require 'digest/keccak'

RPC_URL = ENV.fetch('RPC_URL', 'https://cloudflare-eth.com')
ENS_REGISTRY = '0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e'

# Known test data
TEST_ADDRESS = '0xe11DA9560b51f8918295EdC5ab9c0a90E9ADa20B'
TEST_ENS     = 'jalil.eth'

def keccak256(data)
  Digest::Keccak.new(256).digest(data)
end

def bin_to_hex(bin)
  bin.unpack1('H*')
end

def ens_namehash(name)
  node = "\x00" * 32
  unless name.nil? || name.empty?
    name.split('.').reverse.each do |label|
      label_hash = keccak256(label)
      node = keccak256(node + label_hash)
    end
  end
  bin_to_hex(node)
end

def eth_call(to, data)
  uri = URI(RPC_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 10
  http.read_timeout = 10
  req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path, 'Content-Type' => 'application/json')
  req.body = {
    jsonrpc: '2.0',
    method: 'eth_call',
    params: [{ to: to, data: data }, 'latest'],
    id: 1
  }.to_json

  response = http.request(req)
  result = JSON.parse(response.body)

  if result['error']
    puts "  RPC error: #{result['error']}"
    return nil
  end

  return nil if result['result'].nil? || result['result'] == '0x'

  hex = result['result']
  hex.start_with?('0x') ? hex[2..] : hex
end

def abi_decode_address(hex)
  return nil if hex.nil? || hex.length < 40
  address = hex[-40, 40]
  return nil if address == '0' * 40
  "0x#{address}"
end

def abi_decode_string(hex)
  return nil if hex.nil? || hex.length < 128
  offset = hex[0, 64].to_i(16) * 2
  length = hex[offset, 64].to_i(16)
  return '' if length == 0
  data_start = offset + 64
  return nil if hex.length < data_start + length * 2
  [hex[data_start, length * 2]].pack('H*')
end

# ---------- Run integration test ----------

puts "ENS Integration Test"
puts "RPC: #{RPC_URL}"
puts "=" * 60

address = TEST_ADDRESS
addr_clean = address.sub(/\A0x/i, '').downcase

# Step 1: Reverse resolve
puts "\n1. Reverse resolving #{address}..."
reverse_node = ens_namehash("#{addr_clean}.addr.reverse")
puts "   Reverse node: #{reverse_node}"

resolver_hex = eth_call(ENS_REGISTRY, "0x0178b8bf#{reverse_node}")
resolver = abi_decode_address(resolver_hex)
if resolver.nil?
  puts "   FAIL: No resolver found for reverse node"
  exit 1
end
puts "   Reverse resolver: #{resolver}"

name_hex = eth_call(resolver, "0x691f3431#{reverse_node}")
name = abi_decode_string(name_hex)
if name.nil? || name.empty?
  puts "   FAIL: No name returned from reverse resolver"
  exit 1
end
puts "   Resolved name: #{name}"

if name == TEST_ENS
  puts "   PASS: Name matches expected '#{TEST_ENS}'"
else
  puts "   WARN: Expected '#{TEST_ENS}', got '#{name}'"
end

# Step 2: Forward verify
puts "\n2. Forward verifying #{name} -> address..."
forward_node = ens_namehash(name)
puts "   Forward node: #{forward_node}"

fwd_resolver_hex = eth_call(ENS_REGISTRY, "0x0178b8bf#{forward_node}")
fwd_resolver = abi_decode_address(fwd_resolver_hex)
if fwd_resolver.nil?
  puts "   FAIL: No resolver found for forward name"
  exit 1
end
puts "   Forward resolver: #{fwd_resolver}"

addr_hex = eth_call(fwd_resolver, "0x3b3b57de#{forward_node}")
resolved_addr = abi_decode_address(addr_hex)
if resolved_addr.nil?
  puts "   FAIL: No address returned from forward resolver"
  exit 1
end
puts "   Resolved address: #{resolved_addr}"

if resolved_addr.downcase == address.downcase
  puts "   PASS: Forward verification confirmed"
else
  puts "   FAIL: Address mismatch! #{resolved_addr} != #{address}"
  exit 1
end

# Step 3: Avatar via ENS metadata service
puts "\n3. Checking avatar via ENS metadata service..."
avatar_url = "https://metadata.ens.domains/mainnet/avatar/#{name}"
avatar_uri = URI(avatar_url)
avatar_http = Net::HTTP.new(avatar_uri.host, avatar_uri.port)
avatar_http.use_ssl = true
avatar_http.open_timeout = 10
avatar_http.read_timeout = 10
avatar_res = avatar_http.request(Net::HTTP::Head.new(avatar_uri.path))
puts "   URL: #{avatar_url}"
puts "   Status: #{avatar_res.code}"
if avatar_res.code.to_i == 200
  puts "   Content-Type: #{avatar_res['content-type']}"
  puts "   PASS: Avatar available"
else
  puts "   INFO: No avatar available (status #{avatar_res.code})"
end

# Step 4: Verify no-avatar case returns 404
puts "\n4. Checking no-avatar case (hot.jalil.eth)..."
no_avatar_url = "https://metadata.ens.domains/mainnet/avatar/hot.jalil.eth"
no_avatar_uri = URI(no_avatar_url)
no_avatar_http = Net::HTTP.new(no_avatar_uri.host, no_avatar_uri.port)
no_avatar_http.use_ssl = true
no_avatar_http.open_timeout = 10
no_avatar_http.read_timeout = 10
no_avatar_res = no_avatar_http.request(Net::HTTP::Head.new(no_avatar_uri.path))
puts "   URL: #{no_avatar_url}"
puts "   Status: #{no_avatar_res.code}"
if no_avatar_res.code.to_i == 404
  puts "   PASS: Correctly returns 404 for name without avatar"
else
  puts "   WARN: Expected 404, got #{no_avatar_res.code}"
end

puts "\n" + "=" * 60
puts "All checks passed!"



================================================
FILE: test/ens_unit_test.rb
================================================
#!/usr/bin/env ruby
# Unit tests for ENS resolution helpers (no RPC needed).
#
# Run: ruby test/ens_unit_test.rb

$LOAD_PATH.unshift(*Dir[File.join(__dir__, '..', 'gems/3.4.8/gems/keccak-*/lib')])
require 'digest/keccak'
require 'minitest/autorun'

# Standalone reimplementations of the functions under test,
# using Digest::Keccak directly (avoids the native rbsecp256k1 dep).
module EnsHelpers
  module_function

  def keccak256(data)
    Digest::Keccak.new(256).digest(data)
  end

  def bin_to_hex(bin)
    bin.unpack1('H*')
  end

  def ens_namehash(name)
    node = "\x00" * 32
    unless name.nil? || name.empty?
      name.split('.').reverse.each do |label|
        label_hash = keccak256(label)
        node = keccak256(node + label_hash)
      end
    end
    bin_to_hex(node)
  end

  def abi_decode_address(hex)
    return nil if hex.nil? || hex.length < 40
    address = hex[-40, 40]
    return nil if address == '0' * 40
    "0x#{address}"
  end

  def abi_decode_string(hex)
    return nil if hex.nil? || hex.length < 128
    offset = hex[0, 64].to_i(16) * 2
    length = hex[offset, 64].to_i(16)
    return '' if length == 0
    data_start = offset + 64
    return nil if hex.length < data_start + length * 2
    [hex[data_start, length * 2]].pack('H*')
  end

end

class EnsNamehashTest < Minitest::Test
  # Well-known ENS namehash test vectors from EIP-137
  # https://eips.ethereum.org/EIPS/eip-137

  def test_empty_name
    assert_equal '0' * 64, EnsHelpers.ens_namehash('')
  end

  def test_eth
    expected = '93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae'
    assert_equal expected, EnsHelpers.ens_namehash('eth')
  end

  def test_foo_dot_eth
    expected = 'de9b09fd7c5f901e23a3f19fecc54828e9c848539801e86591bd9801b019f84f'
    assert_equal expected, EnsHelpers.ens_namehash('foo.eth')
  end

  def test_alice_dot_eth
    # Verify determinism and correct length
    hash = EnsHelpers.ens_namehash('alice.eth')
    assert_equal 64, hash.length, 'namehash should be 64 hex chars'
    assert_equal hash, EnsHelpers.ens_namehash('alice.eth')
  end

  def test_reverse_node
    # For address 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045
    addr_clean = 'd8da6bf26964af9d7eed9e03e53415d37aa96045'
    reverse_name = "#{addr_clean}.addr.reverse"
    hash = EnsHelpers.ens_namehash(reverse_name)
    assert_equal 64, hash.length
    # Verify it's deterministic
    assert_equal hash, EnsHelpers.ens_namehash(reverse_name)
  end

  def test_nil_name
    assert_equal '0' * 64, EnsHelpers.ens_namehash(nil)
  end
end

class AbiDecodeAddressTest < Minitest::Test
  def test_valid_address
    # 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 padded to 32 bytes
    hex = '000000000000000000000000d8da6bf26964af9d7eed9e03e53415d37aa96045'
    assert_equal '0xd8da6bf26964af9d7eed9e03e53415d37aa96045', EnsHelpers.abi_decode_address(hex)
  end

  def test_zero_address
    hex = '0000000000000000000000000000000000000000000000000000000000000000'
    assert_nil EnsHelpers.abi_decode_address(hex)
  end

  def test_nil_input
    assert_nil EnsHelpers.abi_decode_address(nil)
  end

  def test_short_input
    assert_nil EnsHelpers.abi_decode_address('abcd')
  end
end

class AbiDecodeStringTest < Minitest::Test
  def test_simple_string
    # ABI-encoded "vitalik.eth" (11 bytes)
    hex = '0000000000000000000000000000000000000000000000000000000000000020' \
          '000000000000000000000000000000000000000000000000000000000000000b' \
          '766974616c696b2e657468000000000000000000000000000000000000000000'
    assert_equal 'vitalik.eth', EnsHelpers.abi_decode_string(hex)
  end

  def test_short_string
    # ABI-encoded "eth" (3 bytes)
    hex = '0000000000000000000000000000000000000000000000000000000000000020' \
          '0000000000000000000000000000000000000000000000000000000000000003' \
          '6574680000000000000000000000000000000000000000000000000000000000'
    assert_equal 'eth', EnsHelpers.abi_decode_string(hex)
  end

  def test_empty_string
    hex = '0000000000000000000000000000000000000000000000000000000000000020' \
          '0000000000000000000000000000000000000000000000000000000000000000'
    assert_equal '', EnsHelpers.abi_decode_string(hex)
  end

  def test_nil_input
    assert_nil EnsHelpers.abi_decode_string(nil)
  end

  def test_too_short
    assert_nil EnsHelpers.abi_decode_string('0020')
  end

  def test_avatar_url
    # ABI-encoded "https://example.com/avatar.png" (30 bytes)
    url = 'https://example.com/avatar.png'
    url_hex = url.unpack1('H*')
    url_padded = url_hex.ljust(64, '0')
    hex = '0000000000000000000000000000000000000000000000000000000000000020' \
          '000000000000000000000000000000000000000000000000000000000000001e' \
          "#{url_padded}"
    assert_equal url, EnsHelpers.abi_decode_string(hex)
  end
end




================================================
FILE: ui/index.html
================================================
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta
      name="viewport"
      content="width=device-width, initial-scale=1.0"
    />
    <title>SIWE Auth — Dev Harness</title>
    <style>
      body {
        margin: 0;
        font-family: system-ui, sans-serif;
      }
    </style>
  </head>
  <body>
    <!-- Hidden form matching Discourse template structure -->
    <form
      id="siwe-sign"
      method="POST"
      action="/auth/siwe/callback"
      style="display: none"
    >
      <textarea
        id="eth_account"
        name="eth_account"
      ></textarea>
      <textarea
        id="eth_message"
        name="eth_message"
      ></textarea>
      <textarea
        id="eth_signature"
        name="eth_signature"
      ></textarea>
      <textarea
        id="eth_name"
        name="eth_name"
      ></textarea>
      <textarea
        id="eth_avatar"
        name="eth_avatar"
      ></textarea>
    </form>

    <div id="siwe-mount"></div>

    <script
      type="module"
      src="/src/main.ts"
    ></script>
    <script type="module">
      // Auto-mount for dev testing
      window.addEventListener('DOMContentLoaded', () => {
        if (window.mountSiwe) {
          window.mountSiwe('#siwe-mount', {
            csrfToken: 'dev-token',
            callbackUrl: '/auth/siwe/callback',
            messageUrl: '/discourse-siwe/message',
            statement: 'Sign-in to Discourse via Ethereum',
          })
        }
      })
    </script>
  </body>
</html>



================================================
FILE: ui/package.json
================================================
{
  "name": "discourse-siwe-vue",
  "type": "module",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vue-tsc --noEmit && vite build",
    "typecheck": "vue-tsc --noEmit"
  },
  "dependencies": {
    "@1001-digital/components": "^2.8.1",
    "@1001-digital/components.evm": "^3.5.3",
    "@1001-digital/styles": "^2.6.0",
    "@tanstack/vue-query": "^5.100.9",
    "@vueuse/core": "^14.3.0",
    "@wagmi/connectors": "^8.0.9",
    "@wagmi/core": "^3.4.8",
    "@wagmi/vue": "^0.5.11",
    "viem": "^2.48.8",
    "vue": "^3.5.33"
  },
  "devDependencies": {
    "@types/luxon": "^3.7.1",
    "@vitejs/plugin-vue": "^6.0.6",
    "typescript": "^6.0.3",
    "vite": "^8.0.10",
    "vue-tsc": "^3.2.8"
  }
}



================================================
FILE: ui/tsconfig.json
================================================
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "jsx": "preserve",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "esModuleInterop": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "skipLibCheck": true,
    "noEmit": true,
    "types": ["vite/client"]
  },
  "include": ["src/**/*.ts", "src/**/*.vue"],
  "references": [{ "path": "./tsconfig.node.json" }]
}



================================================
FILE: ui/tsconfig.node.json
================================================
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "allowSyntheticDefaultImports": true,
    "strict": true,
    "composite": true
  },
  "include": ["vite.config.ts"]
}



================================================
FILE: ui/vite.config.ts
================================================
import { readFileSync, writeFileSync, unlinkSync, readdirSync } from 'fs'
import { resolve } from 'path'
import { defineConfig, type Plugin } from 'vite'
import vue from '@vitejs/plugin-vue'

/**
 * After Vite writes the build output, reads any extracted CSS files,
 * prepends them to the JS bundle as `var __siwe_css__`, and deletes
 * the CSS files. This lets mountSiwe() inject component styles into
 * the shadow DOM at runtime.
 */
function cssToShadow(): Plugin {
  let outDir = ''
  return {
    name: 'css-to-shadow',
    configResolved(config) {
      outDir = config.build.outDir
    },
    closeBundle() {
      const absOut = resolve(outDir)
      const files = readdirSync(absOut)
      const cssFiles = files.filter((f) => f.endsWith('.css'))
      if (!cssFiles.length) return

      let css = ''
      for (const f of cssFiles) {
        css += readFileSync(resolve(absOut, f), 'utf-8')
        unlinkSync(resolve(absOut, f))
      }

      const jsFile = files.find((f) => f === 'siwe.iife.js')
      if (!jsFile) return

      const jsPath = resolve(absOut, jsFile)
      const js = readFileSync(jsPath, 'utf-8')
      // Prepend __siwe_css__ as a global before the IIFE
      writeFileSync(jsPath, `var __siwe_css__ = ${JSON.stringify(css)};\n` + js)
    },
  }
}

export default defineConfig({
  plugins: [vue(), cssToShadow()],
  define: {
    'process.env.NODE_ENV': JSON.stringify('production'),
  },
  build: {
    lib: {
      entry: 'src/main.ts',
      formats: ['iife'],
      name: 'SiweAuth',
      fileName: () => 'siwe.iife.js',
    },
    outDir: '../public/javascripts',
    emptyOutDir: false,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
  resolve: {
    dedupe: ['vue', '@wagmi/core', '@wagmi/vue'],
  },
  optimizeDeps: {
    exclude: ['@1001-digital/components', '@1001-digital/components.evm'],
    include: [
      '@metamask/sdk',
      'eventemitter3',
      'qrcode',
      '@walletconnect/ethereum-provider',
      '@reown/appkit/core',
      '@safe-global/safe-apps-sdk',
      '@safe-global/safe-apps-provider',
    ],
  },
})



================================================
FILE: ui/src/env.d.ts
================================================
/// <reference types="vite/client" />

interface ImportMeta {
  readonly server?: boolean
}

declare module '*.vue' {
  import type { DefineComponent } from 'vue'
  const component: DefineComponent<object, object, unknown>
  export default component
}

declare module '@1001-digital/styles?inline' {
  const css: string
  export default css
}



================================================
FILE: ui/src/main.ts
================================================
import { createApp, h } from 'vue'
import { VueQueryPlugin } from '@tanstack/vue-query'
import { WagmiPlugin } from '@wagmi/vue'
import globalStyles from '@1001-digital/styles?inline'
import { Globals, defaultIconAliases, IconAliasesKey } from '@1001-digital/components'
import { EvmConfigKey } from '@1001-digital/components.evm'
import SiweAuth from './SiweAuth.vue'
import { createWagmiConfig } from './wagmi'
import { createShadowRoot, injectStyles, captureDevStyles, getHostCSSOverrides } from './shadow'

// In production, the cssToShadow Vite plugin prepends extracted component
// CSS as `var __siwe_css__` to the IIFE bundle. We reference it here.
declare var __siwe_css__: string | undefined

export interface SiweOptions {
  csrfToken: string
  callbackUrl: string
  messageUrl: string
  walletConnectProjectId?: string
  statement?: string
}

export function mountSiwe(el: string | HTMLElement, options: SiweOptions) {
  const element = typeof el === 'string' ? document.querySelector(el) : el
  if (!element) throw new Error(`Element not found: ${el}`)

  // Shadow DOM encapsulation
  const { shadow, root, teleportTarget } = createShadowRoot(element)

  // Inject base styles + Discourse theme overrides + component CSS
  const hostOverrides = getHostCSSOverrides()
  const allStyles = [
    globalStyles,
    hostOverrides,
    ':host { color-scheme: inherit; }',
    typeof __siwe_css__ !== 'undefined' ? __siwe_css__ : '',
  ].join('\n')
  injectStyles(shadow, allStyles)

  // In dev mode, capture Vite-injected SFC styles into shadow root
  let stopCapture: (() => void) | undefined
  if (import.meta.env.DEV) {
    stopCapture = captureDevStyles(shadow)
  }

  const wagmiConfig = createWagmiConfig({
    walletConnectProjectId: options.walletConnectProjectId,
  })

  const app = createApp({
    setup() {
      return () => [
        h(Globals),
        h(SiweAuth, {
          messageUrl: options.messageUrl,
          csrfToken: options.csrfToken,
          statement: options.statement,
        }),
      ]
    },
  })

  app.use(VueQueryPlugin)
  app.use(WagmiPlugin, { config: wagmiConfig })

  app.provide(EvmConfigKey, {
    title: 'Sign-in with Ethereum',
    defaultChain: 'mainnet',
    chains: { mainnet: { id: 1, blockExplorer: 'https://etherscan.io' } },
    walletConnectProjectId: options.walletConnectProjectId,
  })
  app.provide(IconAliasesKey, defaultIconAliases)

  // Provide shadow teleport target so Dialog renders inside shadow root
  app.provide('teleport-target', teleportTarget)

  app.mount(root)

  return {
    unmount: () => {
      stopCapture?.()
      app.unmount()
    },
  }
}

// Expose globally for Discourse's loadScript() usage
;(window as any).mountSiwe = mountSiwe



================================================
FILE: ui/src/shadow.ts
================================================
/**
 * Shadow DOM encapsulation for the SIWE auth widget.
 *
 * Prevents library styles (:root, html, body resets, component CSS)
 * from leaking into the host page by mounting inside a shadow root.
 */

/**
 * Remap document-level selectors to shadow-compatible equivalents.
 * :root → :host, html {} → :host {}, body {} → :host {}
 */
function adaptStyles(css: string): string {
  return css
    .replace(/:root/g, ':host')
    .replace(/\bhtml\s*\{/g, ':host {')
    .replace(/\bbody\s*\{/g, ':host {')
}

/**
 * Map Discourse CSS custom properties to @1001-digital/styles equivalents.
 * Each entry is [discourseVar, [...targetVars]].
 */
const DISCOURSE_VAR_MAP: [string, string[]][] = [
  ['--primary', ['--color', '--primary']],
  ['--secondary', ['--background']],
  ['--danger', ['--error']],
  ['--success', ['--success']],
  ['--primary-medium', ['--muted']],
  ['--font-family', ['--font-family']],
  ['--border-color', ['--content-border-color', '--border-color']],
  ['--button-background', ['--d-button-default-bg-color']],
]

/**
 * Read Discourse theme CSS variables from the host document and return
 * a `:host {}` block that overrides the @1001-digital/styles defaults.
 * Returns an empty string when no Discourse variables are present
 * (e.g. in standalone dev mode).
 */
export function getHostCSSOverrides(): string {
  const computed = getComputedStyle(document.documentElement)
  const declarations: string[] = []

  for (const [discourseVar, targetVars] of DISCOURSE_VAR_MAP) {
    const value = computed.getPropertyValue(discourseVar).trim()
    if (!value) continue
    for (const target of targetVars) {
      declarations.push(`${target}: ${value};`)
    }
  }

  return declarations.length ? `:host { ${declarations.join(' ')} }` : ''
}

/**
 * Attach a shadow root to the host element with an inner mount
 * point and a teleport target for dialogs/overlays.
 */
export function createShadowRoot(host: Element) {
  const shadow = host.attachShadow({ mode: 'open' })

  const root = document.createElement('div')
  root.style.height = '100%'
  shadow.appendChild(root)

  // Teleport target — dialogs/overlays render here instead of <body>
  const teleportTarget = document.createElement('div')
  teleportTarget.id = 'teleports'
  shadow.appendChild(teleportTarget)

  return { shadow, root, teleportTarget }
}

/**
 * Inject a CSS string into the shadow root via a <style> element.
 * Uses <style> rather than adoptedStyleSheets so that @layer ordering
 * is shared with component <style> blocks captured by captureDevStyles.
 * Remaps :root/html/body selectors to :host so custom properties
 * and base styles apply within the shadow tree.
 */
export function injectStyles(shadow: ShadowRoot, css: string) {
  const style = document.createElement('style')
  style.textContent = adaptStyles(css)
  shadow.appendChild(style)
}

/**
 * In dev mode, Vite injects Vue SFC <style> blocks into document.head
 * as <style data-vite-dev-id="..."> elements. We intercept them and
 * clone them into every registered shadow root so they:
 *   1. Don't leak into the host page
 *   2. Actually apply inside each shadow tree
 *
 * A shared registry + observer ensures multiple mount calls
 * all receive the same styles. On HMR updates Vite creates a fresh
 * <style> (it can't find the moved one inside shadow DOM) — we
 * deduplicate by removing the previous clone first.
 *
 * Returns a cleanup function that unregisters the shadow root and
 * tears down the observer when the last instance unmounts.
 */
const devStyleTargets = new Set<ShadowRoot>()
let devObserver: MutationObserver | null = null

function distributeStyle(style: HTMLStyleElement) {
  const id = style.getAttribute('data-vite-dev-id')

  for (const shadow of devStyleTargets) {
    if (id) {
      shadow.querySelector(`style[data-vite-dev-id="${id}"]`)?.remove()
    }

    const clone = style.cloneNode(true) as HTMLStyleElement
    if (clone.textContent) {
      clone.textContent = adaptStyles(clone.textContent)
    }
    shadow.appendChild(clone)
  }

  // Remove original so it doesn't leak into the host page
  style.remove()
}

export function captureDevStyles(shadow: ShadowRoot): () => void {
  // Clone already-captured styles from a sibling shadow (they were
  // moved out of <head> by an earlier mount).
  if (devStyleTargets.size > 0) {
    const [existing] = devStyleTargets
    for (const el of existing.querySelectorAll<HTMLStyleElement>(
      'style[data-vite-dev-id]',
    )) {
      shadow.appendChild(el.cloneNode(true))
    }
  }

  devStyleTargets.add(shadow)

  // Move any remaining Vite-injected styles from <head>
  for (const el of [
    ...document.head.querySelectorAll('style[data-vite-dev-id]'),
  ]) {
    distributeStyle(el as HTMLStyleElement)
  }

  // Shared observer — one for all mounted instances
  if (!devObserver) {
    devObserver = new MutationObserver((mutations) => {
      for (const { addedNodes } of mutations) {
        for (const node of addedNodes) {
          if (
            node instanceof HTMLStyleElement &&
            node.hasAttribute('data-vite-dev-id')
          ) {
            distributeStyle(node)
          }
        }
      }
    })
    devObserver.observe(document.head, { childList: true })
  }

  return () => {
    devStyleTargets.delete(shadow)
    if (devStyleTargets.size === 0 && devObserver) {
      devObserver.disconnect()
      devObserver = null
    }
  }
}



================================================
FILE: ui/src/SiweAuth.vue
================================================
<script setup lang="ts">
import { ref, watch } from 'vue'
import { useConnection, useDisconnect, useSignMessage } from '@wagmi/vue'
import { Button, Loading } from '@1001-digital/components'
import { EvmAccount, EvmConnect } from '@1001-digital/components.evm'

const props = defineProps<{
  messageUrl: string
  csrfToken: string
  statement?: string
}>()

const status = ref<'idle' | 'signing' | 'submitting' | 'error'>('idle')
const errorMessage = ref('')

const { address, chainId, isConnected, connector } = useConnection()
const { mutateAsync: signMessageAsync } = useSignMessage()
const { mutate: disconnectAccount } = useDisconnect()

const disconnect = () => {
  status.value = 'idle'
  errorMessage.value = ''
  disconnectAccount()
}

// Track whether the user actively connected via EvmConnect
// (as opposed to an auto-reconnect on page load).
const userInitiated = ref(false)

async function fetchSiweMessage(
  ethAccount: string,
  chain: number,
): Promise<string> {
  const url = new URL(props.messageUrl, window.location.origin)
  url.searchParams.set('eth_account', ethAccount)
  url.searchParams.set('chain_id', String(chain))

  const res = await fetch(url.toString(), {
    headers: {
      Accept: 'application/json',
      'X-Requested-With': 'XMLHttpRequest',
      'X-CSRF-Token': props.csrfToken,
    },
  })
  if (!res.ok)
    throw new Error(`Failed to fetch SIWE message: ${res.statusText}`)
  const { message } = await res.json()
  return message
}

function submitForm(message: string, signature: string) {
  const setField = (id: string, value: string) => {
    const el = document.getElementById(id) as HTMLTextAreaElement | null
    if (el) el.value = value
  }

  setField('eth_message', message)
  setField('eth_signature', signature)

  const form = document.getElementById('siwe-sign') as HTMLFormElement | null
  form?.submit()
}

async function signIn() {
  if (!address.value || !chainId.value) return

  status.value = 'signing'
  errorMessage.value = ''

  try {
    const message = await fetchSiweMessage(address.value, chainId.value)

    const signature = await signMessageAsync({ message })

    status.value = 'submitting'
    submitForm(message, signature)
  } catch (err: unknown) {
    status.value = 'error'
    if (err instanceof Error) {
      // User rejected signature
      if (
        err.message.includes('User rejected') ||
        err.message.includes('user rejected')
      ) {
        errorMessage.value = 'Signature rejected. Please try again.'
      } else {
        errorMessage.value = err.message
      }
    } else {
      errorMessage.value = 'An unknown error occurred.'
    }
  }
}

// Auto-sign only when the user actively connects (not on page-load reconnect)
watch([isConnected, address], ([connected, addr]) => {
  if (connected && addr && status.value === 'idle' && userInitiated.value) {
    signIn()
  }
})
</script>

<template>
  <div class="siwe-auth">
    <Loading
      v-if="status === 'signing'"
      spinner
      stacked
      :txt="
        connector?.name
          ? `Requesting signature from ${connector.name}...`
          : 'Requesting signature...'
      "
    />

    <Loading
      v-else-if="status === 'submitting'"
      spinner
      stacked
      txt="Verifying signature..."
    />

    <template v-else-if="isConnected && status === 'error'">
      <p class="error">{{ errorMessage }}</p>
      <Button
        class="block danger"
        @click="signIn"
      >
        Try again
      </Button>
      <hr />
    </template>

    <template v-if="isConnected && address">
      <Button
        v-if="status === 'idle'"
        class="block"
        @click="signIn"
      >
        {{ statement || 'Sign in with Ethereum' }}
      </Button>
      <Button
        class="block tertiary"
        @click="disconnect()"
      >
        Switch wallet (<EvmAccount
          :address="address"
          class="siwe-address"
        />)
      </Button>
    </template>

    <EvmConnect
      v-else-if="status !== 'submitting'"
      @connecting="userInitiated = true"
    />
  </div>
</template>

<style scoped>
.siwe-auth {
  flex-direction: column;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100%;
  gap: var(--spacer);
  padding: var(--spacer);

  > * {
    width: 100%;
  }

  .error {
    color: var(--error);
  }

  .centered {
    text-align: center;
  }
}
</style>



================================================
FILE: ui/src/wagmi.ts
================================================
import { http, createConfig, type CreateConnectorFn } from '@wagmi/core'
import { mainnet } from 'viem/chains'
import { injected, metaMask, safe, walletConnect } from '@wagmi/connectors'

export interface WagmiOptions {
  walletConnectProjectId?: string
}

const configCache = new Map<string, ReturnType<typeof createConfig>>()

export function createWagmiConfig(options: WagmiOptions) {
  const key = options.walletConnectProjectId ?? ''
  const cached = configCache.get(key)
  if (cached) return cached

  const connectors: CreateConnectorFn[] = [
    injected(),
    safe(),
    metaMask({
      headless: true,
      dappMetadata: { name: 'Sign-in with Ethereum', iconUrl: '', url: '' },
    }),
  ]

  if (options.walletConnectProjectId) {
    connectors.push(
      walletConnect({
        projectId: options.walletConnectProjectId,
        showQrModal: false,
      }),
    )
  }

  const config = createConfig({
    chains: [mainnet],
    batch: { multicall: true },
    connectors,
    transports: {
      [mainnet.id]: http(),
    },
  })

  configCache.set(key, config)
  return config
}



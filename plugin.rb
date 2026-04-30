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
gem 'rbsecp256k1',   '6.0.0',  require: false

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

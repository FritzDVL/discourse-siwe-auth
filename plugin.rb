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

gem 'pkg-config',    require: false
gem 'mini_portile2', require: false
gem 'ffi',           require: false
gem 'ffi-compiler',  require: false

gem 'keccak',      '~> 1.3', require: false
gem 'rbsecp256k1', '~> 6.0', require: false
gem 'scrypt',      '~> 3.0', require: false
gem 'konstructor', '~> 1.0', require: false

gem 'eth',  '~> 0.5', '>= 0.5.16', require: false
gem 'siwe', '~> 1.1', '>= 1.1.2',  require: false

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

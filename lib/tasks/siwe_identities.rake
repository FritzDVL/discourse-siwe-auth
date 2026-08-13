# frozen_string_literal: true

namespace :siwe do
  desc 'Backfill web3 identity custom fields and group memberships for existing SIWE users'
  task :migrate_identities, %i[dry_run force] => :environment do |_t, args|
    dry_run = args[:dry_run] == 'true'
    force   = args[:force] == 'true'
    migrated = 0

    UserAssociatedAccount.where(provider_name: 'siwe').find_each do |assoc|
      user = assoc.user
      next unless user

      wallet = assoc.provider_uid&.downcase
      next if wallet.blank?

      already_migrated = user.custom_fields['wallet_address'].present?
      next if already_migrated && !force

      puts "#{dry_run ? '[dry-run] ' : ''}Migrating #{user.username} (ID: #{user.id})"

      unless dry_run
        user.custom_fields['wallet_address'] = wallet

        ens_name, ens_avatar = DiscourseSiwe::EnsResolver.resolve(wallet)
        user.custom_fields['ens_name']   = ens_name   if ens_name
        user.custom_fields['ens_avatar'] = ens_avatar if ens_avatar

        society = DiscourseSiwe::IdentityResolver.resolve(wallet)
        DiscourseSiwe::IdentityStore.store_society(user, society)
        user.custom_fields['preferred_identity'] =
          DiscourseSiwe::IdentityStore.default_preference(user.custom_fields)

        user.save_custom_fields

        # Re-sync mapped group memberships even for already-migrated users
        # when force=true.
        DiscourseSiwe::BadgeGroupSync.sync(user)

        # Do not rewrite existing display names during bulk migration.
        # The user's display name will update the next time they log in or
        # change their preferred identity in preferences.
        sleep 0.5
      end

      migrated += 1
    end

    puts "Done. #{migrated} users #{dry_run ? 'would be' : 'were'} migrated."
  end
end

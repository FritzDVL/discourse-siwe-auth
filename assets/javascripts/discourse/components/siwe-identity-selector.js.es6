import Component from '@ember/component'
import { computed } from '@ember/object'
import { ajax } from 'discourse/lib/ajax'
import { popupAjaxError } from 'discourse/lib/ajax-error'

export default Component.extend({
  saving: false,

  identities: computed('model.web3_identities', function () {
    const identities = (this.model && this.model.web3_identities) || {}
    if (!identities.wallet_address) return []

    const list = [
      {
        id: 'wallet',
        label: identities.wallet_address,
        sourceKey: 'wallet',
      },
    ]

    if (identities.ens_name) {
      list.push({
        id: 'ens',
        label: identities.ens_name,
        sourceKey: 'ens',
        avatar: identities.ens_avatar,
      })
    }

    if (identities.society_badge_id) {
      list.push({
        id: 'society',
        label: identities.society_name,
        sourceKey: 'society',
        avatar: identities.society_avatar,
      })
    }

    return list
  }),

  actions: {
    selectIdentity(identity) {
      if (this.saving) return
      const previous =
        this.model &&
        this.model.web3_identities &&
        this.model.web3_identities.preferred_identity
      if (identity === previous) return

      this.set('saving', true)
      ajax('/discourse-siwe/update-identity', {
        type: 'POST',
        data: { preferred_identity: identity },
      })
        .then(() => {
          this.set('model.web3_identities.preferred_identity', identity)
        })
        .catch((err) => {
          this.set('model.web3_identities.preferred_identity', previous)
          popupAjaxError(err)
        })
        .finally(() => {
          if (this.isDestroying || this.isDestroyed) return
          this.set('saving', false)
        })
    },
  },
})

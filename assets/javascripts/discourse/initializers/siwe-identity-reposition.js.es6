import { withPluginApi } from 'discourse/lib/plugin-api'
import { schedule } from '@ember/runloop'

/**
 * The user-preferences-profile plugin outlet renders at the bottom of the
 * profile form. For web3 users the display-identity choice is one of the most
 * important fields on this page, so after render we move it to the top of the
 * same form. If the expected DOM is not present, we leave it where it is.
 */
export default {
  name: 'siwe-identity-reposition',

  initialize() {
    withPluginApi('1.0.0', (api) => {
      api.modifyClass('route:preferences.profile', {
        pluginId: 'siwe-identity-reposition',

        didTransition() {
          this._super(...arguments)
          schedule('afterRender', this, this._moveSiweIdentitySelector)
        },

        _moveSiweIdentitySelector() {
          const selector = document.querySelector(
            '.siwe-identity-selector.control-group',
          )
          if (!selector) {
            return
          }

          // Find the form/wrapper that contains the profile fields.
          const container =
            selector.closest('form') ||
            document.querySelector('.user-preferences-outlet form') ||
            document.querySelector('.user-preferences .form-horizontal')
          if (!container) {
            return
          }

          // Avoid unnecessary DOM churn and event re-firing.
          if (container.firstElementChild === selector) {
            return
          }

          container.prepend(selector)
        },
      })
    })
  },
}

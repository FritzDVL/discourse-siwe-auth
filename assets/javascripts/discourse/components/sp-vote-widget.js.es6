import Component from '@ember/component'
import { computed } from '@ember/object'
import { ajax } from 'discourse/lib/ajax'
import { popupAjaxError } from 'discourse/lib/ajax-error'
import loadScript from 'discourse/lib/load-script'

export default Component.extend({
  classNames: ['sp-vote-widget-container'],

  loading: true,
  submitting: false,
  proposal: null,
  tally: null,
  userVote: null,
  userPower: 0,
  userWallet: null,
  selectedChoice: null,
  errorMessage: null,
  successMessage: null,

  hasVoted: computed('userVote', function () {
    return !!this.userVote
  }),

  formattedEndsAt: computed('proposal.ends_at', function () {
    if (!this.proposal || !this.proposal.ends_at) return ''
    try {
      const d = new Date(this.proposal.ends_at)
      return d.toLocaleString()
    } catch (e) {
      return this.proposal.ends_at
    }
  }),

  canVote: computed(
    'proposal.is_active',
    'hasVoted',
    'submitting',
    'userPower',
    'userWallet',
    function () {
      return (
        this.proposal &&
        this.proposal.is_active &&
        !this.hasVoted &&
        !this.submitting &&
        this.userWallet &&
        this.userPower > 0
      )
    },
  ),

  didInsertElement() {
    this._super(...arguments)
    this.loadData()
  },

  async loadData() {
    this.set('loading', true)
    this.set('errorMessage', null)

    const topicId = this.topic && this.topic.id
    if (!topicId) {
      this.set('loading', false)
      return
    }

    try {
      // Ensure web3 signer bundle is loaded
      if (!window.SiweAuth) {
        await loadScript(
          '/plugins/discourse-siwe-auth/javascripts/siwe.iife.js',
        )
      }

      const res = await ajax(`/sp-voting/proposal/${topicId}`)
      if (this.isDestroying || this.isDestroyed) return

      if (res && res.exists) {
        this.set('proposal', res.proposal)
        this.set('tally', res.tally)
        this.set('userVote', res.user_vote)
        this.set('userPower', res.user_power || 0)
        this.set('userWallet', res.user_wallet)

        if (res.user_vote && Array.isArray(res.user_vote.choice)) {
          this.set('selectedChoice', res.user_vote.choice[0])
        }
      }
    } catch (err) {
      if (!this.isDestroying && !this.isDestroyed) {
        this.set('errorMessage', 'Failed to load governance proposal data.')
      }
    } finally {
      if (!this.isDestroying && !this.isDestroyed) {
        this.set('loading', false)
      }
    }
  },

  actions: {
    selectOption(idx) {
      if (this.hasVoted || !this.proposal.is_active) return
      this.set('selectedChoice', idx)
      this.set('errorMessage', null)
    },

    async castVote() {
      if (!this.canVote || this.selectedChoice === null) return

      this.set('submitting', true)
      this.set('errorMessage', null)
      this.set('successMessage', null)

      try {
        if (!window.SiweAuth || !window.SiweAuth.signVotePayload) {
          throw new Error(
            'Web3 signing client not initialized. Please refresh the page.',
          )
        }

        const topicId = this.proposal.topic_id
        const timestamp = Math.floor(Date.now() / 1000)
        const chainId =
          parseInt(this.siteSettings.siwe_voting_chain_id, 10) || 1
        const projectId = this.siteSettings.siwe_project_id || ''

        // Warn if connected wallet doesn't match Discourse SIWE account
        const activeWallet =
          window.SiweAuth.getConnectedAddress &&
          window.SiweAuth.getConnectedAddress(projectId)
        if (
          activeWallet &&
          this.userWallet &&
          activeWallet.toLowerCase() !== this.userWallet.toLowerCase()
        ) {
          throw new Error(
            `Wallet mismatch: Your connected wallet (${activeWallet.slice(0, 6)}...${activeWallet.slice(-4)}) ` +
              `does not match your logged-in forum address (${this.userWallet.slice(0, 6)}...${this.userWallet.slice(-4)}). ` +
              `Please switch accounts in your wallet.`,
          )
        }

        const { signature } = await window.SiweAuth.signVotePayload({
          topicId,
          choice: [this.selectedChoice],
          timestamp,
          chainId,
          walletConnectProjectId: projectId,
        })

        if (!signature) {
          throw new Error('Signature cancelled or failed.')
        }

        const res = await ajax('/sp-voting/cast-vote', {
          type: 'POST',
          data: {
            topic_id: topicId,
            choice: [this.selectedChoice],
            signature,
            timestamp,
          },
        })

        if (this.isDestroying || this.isDestroyed) return

        if (res && res.success) {
          this.set('userVote', {
            choice: res.choice,
            voting_power: res.voting_power,
            signed_at: timestamp,
          })
          if (res.tally) {
            this.set('tally', res.tally)
          }
          this.set(
            'successMessage',
            'Your vote has been successfully cast and recorded on-chain/snapshot!',
          )
        }
      } catch (err) {
        if (!this.isDestroying && !this.isDestroyed) {
          const msg =
            (err &&
              err.jqXHR &&
              err.jqXHR.responseJSON &&
              err.jqXHR.responseJSON.error) ||
            err.message ||
            'An error occurred while signing or submitting your vote.'
          this.set('errorMessage', msg)
        }
      } finally {
        if (!this.isDestroying && !this.isDestroyed) {
          this.set('submitting', false)
        }
      }
    },
  },
})

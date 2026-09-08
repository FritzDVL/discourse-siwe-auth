import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { concat, fn } from "@ember/helper";
import { i18n } from "discourse-i18n";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import RadioButton from "discourse/components/radio-button";

export default class SiweIdentitySelector extends Component {
  @tracked saving = false;

  get identities() {
    const identities = this.args.model?.web3_identities || {};
    if (!identities.wallet_address) {
      return [];
    }

    const list = [
      {
        id: "wallet",
        label: identities.wallet_address,
        sourceKey: "wallet",
      },
    ];

    if (identities.ens_name) {
      list.push({
        id: "ens",
        label: identities.ens_name,
        sourceKey: "ens",
        avatar: identities.ens_avatar,
      });
    }

    if (identities.society_badge_id) {
      list.push({
        id: "society",
        label: identities.society_name,
        sourceKey: "society",
        avatar: identities.society_avatar,
      });
    }

    return list;
  }

  @action
  selectIdentity(identity) {
    if (this.saving) {
      return;
    }

    const web3 = this.args.model?.web3_identities;
    const previous = web3?.preferred_identity;
    if (identity === previous) {
      return;
    }

    this.saving = true;
    ajax("/discourse-siwe/update-identity", {
      type: "POST",
      data: { preferred_identity: identity },
    })
      .then(() => {
        if (web3) {
          web3.preferred_identity = identity;
        }
      })
      .catch((err) => {
        if (web3) {
          web3.preferred_identity = previous;
        }
        popupAjaxError(err);
      })
      .finally(() => {
        this.saving = false;
      });
  }

  <template>
    {{#if this.identities.length}}
      <div class="control-group siwe-identity-selector">
        <label class="control-label">
          {{i18n "discourse_siwe.identity.title"}}
        </label>
        <div class="controls">
          {{#each this.identities as |identity|}}
            <label class="identity-option">
              <RadioButton
                @value={{identity.id}}
                @selection={{@model.web3_identities.preferred_identity}}
                @onChange={{fn this.selectIdentity identity.id}}
              />
              <span class="identity-name">{{identity.label}}</span>
              <span class="identity-source">
                {{i18n (concat "discourse_siwe.identity.source." identity.sourceKey)}}
              </span>
              {{#if identity.avatar}}
                <img
                  src={{identity.avatar}}
                  class="identity-preview"
                  alt=""
                />
              {{/if}}
            </label>
          {{/each}}
        </div>
      </div>
    {{/if}}
  </template>
}

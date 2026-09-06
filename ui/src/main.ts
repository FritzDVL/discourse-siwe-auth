import { createApp, h } from 'vue'
import { VueQueryPlugin } from '@tanstack/vue-query'
import { WagmiPlugin } from '@wagmi/vue'
import globalStyles from '@1001-digital/styles?inline'
import {
  Globals,
  defaultIconAliases,
  IconAliasesKey,
} from '@1001-digital/components'
import { EvmConfigKey } from '@1001-digital/components.evm'
import SiweAuth from './SiweAuth.vue'
import { createWagmiConfig } from './wagmi'
import {
  createShadowRoot,
  injectStyles,
  captureDevStyles,
  getHostCSSOverrides,
} from './shadow'

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

import { signTypedData, getAccount, reconnect } from '@wagmi/core'

export interface VotePayload {
  topicId: number
  choice: number[]
  timestamp: number
  chainId?: number
  walletConnectProjectId?: string
}

export async function signVotePayload(
  payload: VotePayload,
): Promise<{ signature: string; address: string }> {
  const config = createWagmiConfig({
    walletConnectProjectId: payload.walletConnectProjectId,
  })

  let account = getAccount(config)
  if (!account.isConnected) {
    try {
      await reconnect(config)
      account = getAccount(config)
    } catch {
      // Continue if user prompts connection
    }
  }

  const domain = {
    name: 'Society Protocol Governance',
    version: '1',
    chainId: payload.chainId || 1,
  } as const

  const types = {
    Vote: [
      { name: 'topicId', type: 'uint256' },
      { name: 'choice', type: 'uint256[]' },
      { name: 'timestamp', type: 'uint256' },
    ],
  } as const

  const signature = await signTypedData(config, {
    domain,
    types,
    primaryType: 'Vote',
    message: {
      topicId: BigInt(payload.topicId),
      choice: payload.choice.map((c) => BigInt(c)),
      timestamp: BigInt(payload.timestamp),
    },
  })

  return {
    signature,
    address: account.address || '',
  }
}

export function getConnectedAddress(
  walletConnectProjectId?: string,
): string | undefined {
  const config = createWagmiConfig({ walletConnectProjectId })
  const account = getAccount(config)
  return account.address
}

// Expose globally for Discourse's loadScript() usage
;(window as any).mountSiwe = mountSiwe
;(window as any).SiweAuth = {
  mountSiwe,
  signVotePayload,
  getConnectedAddress,
  createWagmiConfig,
}

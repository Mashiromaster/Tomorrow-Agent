export interface Env {
  /** Attested App Attest public keys, keyed by `dev:<keyId>`. */
  DEVICES: KVNamespace
  /** Monthly request counters, keyed by `q:<keyId>:<YYYY-MM>`. */
  QUOTA: KVNamespace

  /** Apple Developer Team ID. Combined with the bundle ID to form the App ID. */
  APPLE_TEAM_ID: string
  /** The iOS app's bundle identifier. */
  APP_BUNDLE_ID: string
  /** "development" also accepts debug-build attestations. */
  APP_ATTEST_ENV: 'development' | 'production'
  /** Upstream origin — the DeepSeek Anthropic-compatible endpoint. */
  UPSTREAM_BASE_URL: string

  FREE_MONTHLY_REQUESTS: string
  PRO_MONTHLY_REQUESTS: string

  /** Secret. Injected into the upstream request; never leaves the Worker. */
  DEEPSEEK_API_KEY: string
  /** Secret. HMAC-SHA256 key for short-lived device tokens. */
  JWT_SIGNING_KEY: string
}

/** `TEAMID.com.example.App` — the value whose SHA-256 appears in authData. */
export function appId(env: Env): string {
  return `${env.APPLE_TEAM_ID}.${env.APP_BUNDLE_ID}`
}

export type Tier = 'free' | 'pro'

export function monthlyLimit(env: Env, tier: Tier): number {
  const raw = tier === 'pro' ? env.PRO_MONTHLY_REQUESTS : env.FREE_MONTHLY_REQUESTS
  const parsed = Number.parseInt(raw, 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

/**
 * Stateless attestation challenges.
 *
 * A challenge is `<issuedAt>.<random>.<HMAC>` — self-authenticating, so the
 * proxy stores nothing to validate one later. That keeps the "代理保持无状态"
 * property from IMPLEMENTATION.md §2.3 intact even for the handshake.
 *
 * Replay within the 5-minute window is handled by the layers above, not here:
 *   · attestation — `POST /v1/attest` refuses a keyId that is already enrolled,
 *     and the attestation itself is cryptographically bound to this challenge.
 *   · assertion — the Secure Enclave counter must strictly increase, so a
 *     captured assertion is rejected even with a still-valid challenge.
 */

import { fromBase64, timingSafeEqual, toBase64Url, utf8 } from './bytes'
import type { Env } from './env'
import { badRequest, unauthorized } from './errors'

export const CHALLENGE_TTL_SECONDS = 5 * 60

const HMAC_SHA256 = { name: 'HMAC', hash: 'SHA-256' } as const

/** Domain separation: an attestation challenge must not work as an assertion one. */
export type ChallengePurpose = 'attest' | 'assert'

async function hmac(env: Env, message: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    'raw',
    utf8(env.JWT_SIGNING_KEY).slice(),
    HMAC_SHA256,
    false,
    ['sign'],
  )
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, utf8(message).slice()))
}

export async function issueChallenge(
  env: Env,
  purpose: ChallengePurpose,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  const random = toBase64Url(crypto.getRandomValues(new Uint8Array(32)))
  const body = `${purpose}.${nowSeconds}.${random}`
  return `${body}.${toBase64Url(await hmac(env, body))}`
}

/**
 * Confirms the challenge is one we issued, for this purpose, and still fresh.
 * Returns the exact bytes the device must have signed — callers pass these
 * straight into App Attest verification.
 */
export async function verifyChallenge(
  env: Env,
  challenge: string,
  purpose: ChallengePurpose,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<Uint8Array> {
  const segments = challenge.split('.')
  if (segments.length !== 4) throw badRequest('malformed challenge')
  const [presentedPurpose, issuedAtRaw, , encodedSignature] = segments as [string, string, string, string]

  const body = segments.slice(0, 3).join('.')
  let presented: Uint8Array
  try {
    presented = fromBase64(encodedSignature)
  } catch {
    throw badRequest('malformed challenge signature')
  }
  if (!timingSafeEqual(presented, await hmac(env, body))) {
    throw unauthorized('challenge was not issued by this proxy')
  }

  if (presentedPurpose !== purpose) throw unauthorized('challenge was issued for a different purpose')

  const issuedAt = Number.parseInt(issuedAtRaw, 10)
  if (!Number.isFinite(issuedAt)) throw badRequest('malformed challenge timestamp')
  if (nowSeconds - issuedAt > CHALLENGE_TTL_SECONDS) throw unauthorized('challenge has expired')
  // Tolerate a little clock skew, but reject a far-future timestamp.
  if (issuedAt - nowSeconds > 60) throw unauthorized('challenge timestamp is in the future')

  // The device signs the challenge string exactly as it received it.
  return utf8(challenge)
}

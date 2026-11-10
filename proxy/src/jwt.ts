/**
 * Short-lived device tokens (HMAC-SHA256 JWT).
 *
 * The device proves possession of its Secure Enclave key once (an assertion),
 * and receives a token good for a few minutes of Claude requests. This keeps
 * the expensive assertion off the hot path without ever handing the client
 * anything long-lived — and nothing that is useful if extracted from the
 * binary (IMPLEMENTATION.md §2.3).
 */

import { fromBase64, timingSafeEqual, toBase64Url, utf8 } from './bytes'
import type { Env, Tier } from './env'
import { unauthorized } from './errors'

export const TOKEN_TTL_SECONDS = 15 * 60

export interface DeviceClaims {
  /** The App Attest keyId. Identifies the device for quota accounting. */
  sub: string
  tier: Tier
  iat: number
  exp: number
}

const HMAC_SHA256 = { name: 'HMAC', hash: 'SHA-256' } as const

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

const encodeSegment = (value: unknown): string => toBase64Url(utf8(JSON.stringify(value)))

const decodeSegment = (segment: string): unknown =>
  JSON.parse(new TextDecoder().decode(fromBase64(segment))) as unknown

export async function issueDeviceToken(
  env: Env,
  keyId: string,
  tier: Tier,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<{ token: string; expiresAt: number }> {
  const claims: DeviceClaims = {
    sub: keyId,
    tier,
    iat: nowSeconds,
    exp: nowSeconds + TOKEN_TTL_SECONDS,
  }
  const signingInput = `${encodeSegment({ alg: 'HS256', typ: 'JWT' })}.${encodeSegment(claims)}`
  const signature = toBase64Url(await hmac(env, signingInput))
  return { token: `${signingInput}.${signature}`, expiresAt: claims.exp }
}

/** Throws `ProxyError(401)` on any problem — never returns partial trust. */
export async function verifyDeviceToken(
  env: Env,
  token: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<DeviceClaims> {
  const segments = token.split('.')
  if (segments.length !== 3) throw unauthorized('malformed device token')
  const [encodedHeader, encodedClaims, encodedSignature] = segments as [string, string, string]

  let presented: Uint8Array
  try {
    presented = fromBase64(encodedSignature)
  } catch {
    throw unauthorized('malformed device token signature')
  }
  if (!timingSafeEqual(presented, await hmac(env, `${encodedHeader}.${encodedClaims}`))) {
    throw unauthorized('device token signature is not valid')
  }

  // Signature verified before parsing: the segments below are our own bytes.
  let header: { alg?: unknown }
  let claims: DeviceClaims
  try {
    header = decodeSegment(encodedHeader) as { alg?: unknown }
    claims = decodeSegment(encodedClaims) as DeviceClaims
  } catch {
    throw unauthorized('malformed device token')
  }

  // Reject `alg: none` and friends even though the signature already passed.
  if (header.alg !== 'HS256') throw unauthorized('unsupported device token algorithm')

  if (typeof claims.sub !== 'string' || claims.sub.length === 0) throw unauthorized('device token has no subject')
  if (claims.tier !== 'free' && claims.tier !== 'pro') throw unauthorized('device token has an unknown tier')
  if (typeof claims.exp !== 'number' || claims.exp <= nowSeconds) throw unauthorized('device token has expired')

  return claims
}

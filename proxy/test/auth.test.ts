/**
 * Device authentication: challenge → attestation → assertion → token.
 *
 * Apple's attestation certificate chain cannot be forged locally, so the
 * happy path of `/v1/attest` is only reachable on a real device. What is
 * testable here — and what actually protects the API key — is every way the
 * proxy must *refuse*: a forged challenge, a replayed assertion, an assertion
 * minted for another App ID, a token that has expired or been re-signed.
 *
 * The assertion path is fully exercised, because an assertion is a plain
 * ECDSA signature over `SHA256(authenticatorData ‖ SHA256(clientData))` and
 * the test harness can produce a genuine one (see `buildAssertion`).
 */

import { beforeEach, describe, expect, it } from 'vitest'
import { toBase64Url, utf8 } from '../src/bytes'
import { deviceKvKey, type DeviceRecord } from '../src/appattest'
import { issueChallenge } from '../src/challenge'
import { issueDeviceToken, verifyDeviceToken, TOKEN_TTL_SECONDS } from '../src/jwt'
import {
  buildAssertion,
  callWorker,
  clearKv,
  createTestDeviceKey,
  enrollDevice,
  env,
} from './helpers'

beforeEach(async () => {
  await clearKv()
})

/** Signs JWT segments with the test signing key, so we can craft hostile tokens. */
async function signSegments(signingInput: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    utf8(env.JWT_SIGNING_KEY).slice(),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  return toBase64Url(new Uint8Array(await crypto.subtle.sign('HMAC', key, utf8(signingInput).slice())))
}

const post = (path: string, body: unknown) =>
  callWorker(
    new Request(`https://proxy.test${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    }),
  )

async function freshChallenge(path: '/v1/attest/challenge' | '/v1/token/challenge'): Promise<string> {
  const response = await callWorker(new Request(`https://proxy.test${path}`, { method: 'POST' }))
  const { challenge } = (await response.json()) as { challenge: string }
  return challenge
}

describe('challenge issuance', () => {
  it('issues a self-authenticating challenge with a TTL', async () => {
    const response = await callWorker(
      new Request('https://proxy.test/v1/token/challenge', { method: 'POST' }),
    )
    expect(response.status).toBe(200)

    const body = (await response.json()) as { challenge: string; expires_in: number }
    expect(body.expires_in).toBe(300)
    // purpose.issuedAt.random.signature
    expect(body.challenge.split('.')).toHaveLength(4)
    expect(body.challenge.startsWith('assert.')).toBe(true)
  })

  it('issues distinct challenges on repeat calls', async () => {
    const [first, second] = await Promise.all([
      freshChallenge('/v1/token/challenge'),
      freshChallenge('/v1/token/challenge'),
    ])
    expect(first).not.toBe(second)
  })
})

describe('attestation refusals', () => {
  it('rejects a challenge this proxy did not issue', async () => {
    const device = await createTestDeviceKey()
    const response = await post('/v1/attest', {
      key_id: device.keyId,
      attestation: 'AAAA',
      challenge: 'attest.1762765200.forged.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    })

    expect(response.status).toBe(401)
    const body = (await response.json()) as { error: { type: string; message: string } }
    expect(body.error.type).toBe('authentication_error')
    expect(body.error.message).toMatch(/not issued by this proxy/)
  })

  it('rejects an assertion challenge presented for attestation', async () => {
    // Domain separation: the two challenge kinds are not interchangeable.
    const device = await createTestDeviceKey()
    const response = await post('/v1/attest', {
      key_id: device.keyId,
      attestation: 'AAAA',
      challenge: await freshChallenge('/v1/token/challenge'),
    })

    expect(response.status).toBe(401)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/different purpose/)
  })

  it('rejects an expired challenge', async () => {
    const device = await createTestDeviceKey()
    const nowSeconds = Math.floor(Date.now() / 1000)
    const stale = await issueChallenge(env, 'attest', nowSeconds - 400)

    const response = await post('/v1/attest', {
      key_id: device.keyId,
      attestation: 'AAAA',
      challenge: stale,
    })

    expect(response.status).toBe(401)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/expired/)
  })

  it('refuses to re-enroll a key, which would reset its replay counter', async () => {
    const device = await createTestDeviceKey()
    await enrollDevice(device, { signCount: 42 })

    const response = await post('/v1/attest', {
      key_id: device.keyId,
      attestation: 'AAAA',
      challenge: await freshChallenge('/v1/attest/challenge'),
    })

    expect(response.status).toBe(400)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/already enrolled/)

    // The stored counter is untouched.
    const stored = JSON.parse((await env.DEVICES.get(deviceKvKey(device.keyId)))!) as DeviceRecord
    expect(stored.signCount).toBe(42)
  })

  it('rejects an attestation that is not valid base64 or CBOR', async () => {
    const device = await createTestDeviceKey()

    const notBase64 = await post('/v1/attest', {
      key_id: device.keyId,
      attestation: '!!!not base64!!!',
      challenge: await freshChallenge('/v1/attest/challenge'),
    })
    expect(notBase64.status).toBe(400)

    const notCbor = await post('/v1/attest', {
      key_id: device.keyId,
      // Valid base64, but not a CBOR map.
      attestation: 'aGVsbG8gd29ybGQ=',
      challenge: await freshChallenge('/v1/attest/challenge'),
    })
    expect(notCbor.status).toBe(400)
    const body = (await notCbor.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/CBOR|attestation/)
  })

  it('requires key_id, attestation, and challenge', async () => {
    const response = await post('/v1/attest', { key_id: 'only-this' })
    expect(response.status).toBe(400)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/`attestation` is required/)
  })
})

describe('token exchange', () => {
  it('issues a token for a genuine assertion and advances the counter', async () => {
    const device = await createTestDeviceKey('pro')
    await enrollDevice(device)

    const challenge = await freshChallenge('/v1/token/challenge')
    const assertion = await buildAssertion({
      device,
      clientData: utf8(challenge),
      signCount: 1,
    })

    const response = await post('/v1/token', {
      key_id: device.keyId,
      assertion,
      challenge,
    })

    expect(response.status).toBe(200)
    const body = (await response.json()) as { token: string; expires_at: number; tier: string }
    expect(body.tier).toBe('pro')

    const claims = await verifyDeviceToken(env, body.token)
    expect(claims.sub).toBe(device.keyId)
    expect(claims.tier).toBe('pro')
    expect(claims.exp - claims.iat).toBe(TOKEN_TTL_SECONDS)

    const stored = JSON.parse((await env.DEVICES.get(deviceKvKey(device.keyId)))!) as DeviceRecord
    expect(stored.signCount).toBe(1)
  })

  it('rejects a replayed assertion once the counter has advanced', async () => {
    const device = await createTestDeviceKey()
    await enrollDevice(device)

    const challenge = await freshChallenge('/v1/token/challenge')
    const assertion = await buildAssertion({ device, clientData: utf8(challenge), signCount: 1 })

    const first = await post('/v1/token', { key_id: device.keyId, assertion, challenge })
    expect(first.status).toBe(200)

    // Captured verbatim and sent again — the Secure Enclave counter no longer
    // exceeds the stored value, so this is the replay defence firing.
    const replay = await post('/v1/token', { key_id: device.keyId, assertion, challenge })
    expect(replay.status).toBe(401)
    const body = (await replay.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/replay/)
  })

  it('rejects an assertion signed by a different device key', async () => {
    const enrolled = await createTestDeviceKey()
    const attacker = await createTestDeviceKey()
    await enrollDevice(enrolled)

    const challenge = await freshChallenge('/v1/token/challenge')
    const assertion = await buildAssertion({
      device: attacker,
      clientData: utf8(challenge),
      signCount: 1,
    })

    const response = await post('/v1/token', {
      key_id: enrolled.keyId,
      assertion,
      challenge,
    })

    expect(response.status).toBe(401)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/signature is not valid/)
  })

  it('rejects an assertion minted for a different App ID', async () => {
    const device = await createTestDeviceKey()
    await enrollDevice(device)

    const challenge = await freshChallenge('/v1/token/challenge')
    const assertion = await buildAssertion({
      device,
      clientData: utf8(challenge),
      signCount: 1,
      appId: 'OTHERTEAM.com.attacker.App',
    })

    const response = await post('/v1/token', { key_id: device.keyId, assertion, challenge })
    expect(response.status).toBe(401)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/different App ID/)
  })

  it('rejects an assertion bound to a challenge other than the one presented', async () => {
    const device = await createTestDeviceKey()
    await enrollDevice(device)

    const signedOver = await freshChallenge('/v1/token/challenge')
    const presented = await freshChallenge('/v1/token/challenge')
    const assertion = await buildAssertion({
      device,
      clientData: utf8(signedOver),
      signCount: 1,
    })

    const response = await post('/v1/token', {
      key_id: device.keyId,
      assertion,
      challenge: presented,
    })

    expect(response.status).toBe(401)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/signature is not valid/)
  })

  it('rejects a device that was never enrolled', async () => {
    const device = await createTestDeviceKey()
    const challenge = await freshChallenge('/v1/token/challenge')
    const assertion = await buildAssertion({ device, clientData: utf8(challenge), signCount: 1 })

    const response = await post('/v1/token', { key_id: device.keyId, assertion, challenge })
    expect(response.status).toBe(401)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toMatch(/not enrolled/)
  })
})

describe('device token verification', () => {
  it('rejects a token signed with the wrong key', async () => {
    const foreign = { ...env, JWT_SIGNING_KEY: 'a-different-signing-key' }
    const { token } = await issueDeviceToken(foreign, 'key-id', 'pro')

    await expect(verifyDeviceToken(env, token)).rejects.toThrow(/signature is not valid/)
  })

  it('rejects an expired token', async () => {
    const nowSeconds = Math.floor(Date.now() / 1000)
    const { token } = await issueDeviceToken(env, 'key-id', 'pro', nowSeconds - TOKEN_TTL_SECONDS - 60)

    await expect(verifyDeviceToken(env, token)).rejects.toThrow(/expired/)
  })

  it('rejects `alg: none` even when the HMAC checks out', async () => {
    // A correctly-signed token whose header claims no algorithm: the classic
    // JWT downgrade. The signature passes; the header check must still refuse.
    const header = toBase64Url(utf8(JSON.stringify({ alg: 'none', typ: 'JWT' })))
    const claims = toBase64Url(
      utf8(
        JSON.stringify({
          sub: 'key-id',
          tier: 'pro',
          iat: Math.floor(Date.now() / 1000),
          exp: Math.floor(Date.now() / 1000) + 600,
        }),
      ),
    )
    const token = `${header}.${claims}.${await signSegments(`${header}.${claims}`)}`

    await expect(verifyDeviceToken(env, token)).rejects.toThrow(/unsupported device token algorithm/)
  })

  it('rejects an unknown tier', async () => {
    const header = toBase64Url(utf8(JSON.stringify({ alg: 'HS256', typ: 'JWT' })))
    const claims = toBase64Url(
      utf8(
        JSON.stringify({
          sub: 'key-id',
          tier: 'unlimited',
          iat: Math.floor(Date.now() / 1000),
          exp: Math.floor(Date.now() / 1000) + 600,
        }),
      ),
    )
    const token = `${header}.${claims}.${await signSegments(`${header}.${claims}`)}`

    await expect(verifyDeviceToken(env, token)).rejects.toThrow(/unknown tier/)
  })

  it('rejects a structurally malformed token', async () => {
    await expect(verifyDeviceToken(env, 'not.a.jwt.at.all')).rejects.toThrow(/malformed/)
    await expect(verifyDeviceToken(env, 'onlyonesegment')).rejects.toThrow(/malformed/)
  })
})

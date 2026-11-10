/**
 * Shared test scaffolding.
 *
 * Tests drive the Hono app directly (`app.fetch(request, env, ctx)`) rather
 * than through a service binding, so each case can inspect the exact `Request`
 * the proxy would have sent upstream. That is what makes the byte-stability
 * assertions in `cache-stability.test.ts` possible.
 */

import { env as testEnv } from 'cloudflare:test'
import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test'
import { encode as cborEncode } from 'cborg'
import { vi } from 'vitest'
import app from '../src/index'
import { concat, sha256, toBase64, utf8 } from '../src/bytes'
import type { Env } from '../src/env'
import { deviceKvKey, type DeviceRecord } from '../src/appattest'
import { issueDeviceToken } from '../src/jwt'

export const env = testEnv as unknown as Env

/** The App ID the test bindings describe: `TEAMID1234.com.example.PAgent`. */
export const TEST_APP_ID = `${env.APPLE_TEAM_ID}.${env.APP_BUNDLE_ID}`

export const UPSTREAM_MESSAGES_URL = `${env.UPSTREAM_BASE_URL}/v1/messages`

/** Isolated storage is per-test-file, not per-test — clear explicitly. */
export async function clearKv(): Promise<void> {
  for (const namespace of [env.DEVICES, env.QUOTA]) {
    const { keys } = await namespace.list()
    await Promise.all(keys.map((k) => namespace.delete(k.name)))
  }
}

/** Runs a request through the worker and drains any `waitUntil` work. */
export async function callWorker(request: Request): Promise<Response> {
  const ctx = createExecutionContext()
  const response = await app.fetch(request, env, ctx)
  await waitOnExecutionContext(ctx)
  return response
}

/**
 * A `/v1/messages` request carrying a valid device token.
 *
 * `body` is passed through as a string so tests control the exact bytes —
 * never `JSON.stringify` inside this helper, or the byte-stability assertions
 * would be testing the helper rather than the proxy.
 */
export async function messagesRequest(options: {
  body: string
  keyId?: string
  tier?: 'free' | 'pro'
  headers?: Record<string, string>
  token?: string
}): Promise<Request> {
  const token =
    options.token ??
    (await issueDeviceToken(env, options.keyId ?? 'test-key-id', options.tier ?? 'pro')).token

  return new Request('https://proxy.test/v1/messages', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      ...options.headers,
    },
    body: options.body,
  })
}

export interface UpstreamStub {
  /** Every request the proxy sent upstream, in order. */
  readonly calls: Request[]
  /** Body bytes of call `index`, captured before the body was consumed. */
  bodyBytes(index: number): Uint8Array
  restore(): void
}

/**
 * Replaces global `fetch`. The worker module shares this isolate, so the stub
 * intercepts `forwardToAnthropic`.
 */
export function stubUpstream(respond: (request: Request) => Response | Promise<Response>): UpstreamStub {
  const calls: Request[] = []
  const bodies: Uint8Array[] = []

  const mock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const outgoing = new Request(input as RequestInfo, init)

    // Read the bytes once, then rebuild an equivalent Request so assertions can
    // still read the body. Teeing via repeated `clone()` is avoidable here.
    const bytes = new Uint8Array(await outgoing.arrayBuffer())
    bodies.push(bytes)

    const captured =
      outgoing.method === 'GET' || outgoing.method === 'HEAD'
        ? new Request(outgoing.url, { method: outgoing.method, headers: outgoing.headers })
        : new Request(outgoing.url, {
            method: outgoing.method,
            headers: outgoing.headers,
            body: bytes,
          })
    calls.push(captured)

    return respond(captured)
  })

  vi.stubGlobal('fetch', mock)

  return {
    calls,
    bodyBytes(index: number): Uint8Array {
      const bytes = bodies[index]
      if (!bytes) throw new Error(`no upstream call at index ${index}`)
      return bytes
    },
    restore() {
      vi.unstubAllGlobals()
    },
  }
}

/** A minimal non-streaming Messages response, shaped like the real API. */
export function messagesResponse(usage: Record<string, number> = {}): Response {
  return new Response(
    JSON.stringify({
      id: 'msg_test',
      type: 'message',
      role: 'assistant',
      model: 'deepseek-v4-pro',
      content: [{ type: 'text', text: 'ok' }],
      stop_reason: 'end_turn',
      usage: { input_tokens: 10, output_tokens: 5, ...usage },
    }),
    { status: 200, headers: { 'content-type': 'application/json', 'request-id': 'req_upstream' } },
  )
}

/** Builds an SSE body from already-serialised frames. */
export function sseResponse(frames: string[]): Response {
  return new Response(frames.join(''), {
    status: 200,
    headers: { 'content-type': 'text/event-stream' },
  })
}

export function sseFrame(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
}

// ── App Attest fixtures ─────────────────────────────────────────────────────

const EC_P256 = { name: 'ECDSA', namedCurve: 'P-256' } as const

/**
 * `generateKey` is typed `CryptoKey | CryptoKeyPair` because the return shape
 * depends on the algorithm; ECDSA always yields a pair.
 */
export async function generateP256KeyPair(): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey(EC_P256, false, ['sign', 'verify'])) as CryptoKeyPair
}

export interface TestDeviceKey {
  keyId: string
  privateKey: CryptoKey
  record: DeviceRecord
}

/**
 * Generates a Secure-Enclave-shaped key pair and the `DeviceRecord` the proxy
 * would have stored after a successful attestation. This lets assertion tests
 * run without Apple's certificate chain, which cannot be forged locally — the
 * attestation path is exercised through its failure modes instead.
 */
export async function createTestDeviceKey(tier: 'free' | 'pro' = 'free'): Promise<TestDeviceKey> {
  const pair = await generateP256KeyPair()
  const rawPublicKey = new Uint8Array(
    (await crypto.subtle.exportKey('raw', pair.publicKey)) as ArrayBuffer,
  )
  const keyId = toBase64(await sha256(rawPublicKey))

  return {
    keyId,
    privateKey: pair.privateKey,
    record: {
      publicKey: toBase64(rawPublicKey),
      signCount: 0,
      attestedAt: new Date('2026-11-01T00:00:00Z').toISOString(),
      tier,
    },
  }
}

export async function enrollDevice(device: TestDeviceKey, record?: Partial<DeviceRecord>): Promise<void> {
  await env.DEVICES.put(deviceKvKey(device.keyId), JSON.stringify({ ...device.record, ...record }))
}

/** `rpIdHash ‖ flags ‖ signCount` — the assertion form, with no credential data. */
export async function buildAuthenticatorData(
  signCount: number,
  appId: string = TEST_APP_ID,
): Promise<Uint8Array> {
  const rpIdHash = await sha256(utf8(appId))
  const tail = new Uint8Array(5)
  tail[0] = 0x00 // flags: no attested credential data on an assertion
  new DataView(tail.buffer).setUint32(1, signCount, false)
  return concat(rpIdHash, tail)
}

export interface BuildAssertionOptions {
  device: TestDeviceKey
  /** The exact bytes the proxy will hash as client data (the challenge string). */
  clientData: Uint8Array
  signCount: number
  /** Override to simulate an assertion minted for a different app. */
  appId?: string
}

/** Produces a base64 CBOR assertion object, signed by the device key. */
export async function buildAssertion(options: BuildAssertionOptions): Promise<string> {
  const authenticatorData = await buildAuthenticatorData(
    options.signCount,
    options.appId ?? TEST_APP_ID,
  )
  const nonce = await sha256(concat(authenticatorData, await sha256(options.clientData)))
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      options.device.privateKey,
      nonce.slice(),
    ),
  )
  return toBase64(
    cborEncode({ signature: rawToDerEcdsaSignature(rawSignature), authenticatorData }),
  )
}

/** WebCrypto emits `r ‖ s`; App Attest assertions carry DER. */
export function rawToDerEcdsaSignature(raw: Uint8Array): Uint8Array {
  const encodeInteger = (value: Uint8Array): Uint8Array => {
    let start = 0
    while (start < value.byteLength - 1 && value[start] === 0x00) start++
    let trimmed = value.subarray(start)
    // DER integers are signed: prepend 0x00 when the high bit is set.
    if ((trimmed[0]! & 0x80) !== 0) trimmed = concat(new Uint8Array([0x00]), trimmed)
    return concat(new Uint8Array([0x02, trimmed.byteLength]), trimmed)
  }

  const half = raw.byteLength / 2
  const body = concat(encodeInteger(raw.subarray(0, half)), encodeInteger(raw.subarray(half)))
  return concat(new Uint8Array([0x30, body.byteLength]), body)
}

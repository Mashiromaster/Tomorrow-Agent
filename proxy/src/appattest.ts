/**
 * Apple App Attest verification.
 *
 * Two flows, matching Apple's "Validating Apps That Connect to Your Server":
 *
 *   1. `verifyAttestation` — once per device, when the app generates a key.
 *      Proves the key lives in the Secure Enclave of a genuine device running
 *      our App ID. Yields the public key, which we store.
 *   2. `verifyAssertion` — every time the device wants a token. Proves the
 *      holder controls that same key, and that this is not a replay (the
 *      Secure Enclave's monotonic counter must strictly increase).
 *
 * The client never holds the Anthropic API key; it holds a Secure Enclave key
 * that only ever yields short-lived proxy tokens (IMPLEMENTATION.md §2.3).
 */

// `@peculiar/x509` pulls in tsyringe, which requires `Reflect.getMetadata`.
// workerd does not ship it, so the polyfill must be evaluated before the
// x509 import below — ESM runs side effects in declaration order.
import 'reflect-metadata'
import { decode as cborDecode } from 'cborg'
import * as x509 from '@peculiar/x509'
import { concat, fromBase64, sha256, timingSafeEqual, toBase64, utf8 } from './bytes'
import { derToRawEcdsaSignature } from './bytes'
import { appId, type Env } from './env'
import { badRequest, forbidden, unauthorized } from './errors'

x509.cryptoProvider.set(crypto as unknown as Crypto)

/** https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem */
const APPLE_APP_ATTEST_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`

/** Apple's nonce extension on the attestation credential certificate. */
const NONCE_EXTENSION_OID = '1.2.840.113635.100.8.2'

/** "appattest" + 7 NUL bytes. Production attestations. */
const AAGUID_PRODUCTION = utf8('appattest\0\0\0\0\0\0\0')
/** Exactly 16 chars. Debug builds attached to Xcode. */
const AAGUID_DEVELOPMENT = utf8('appattestdevelop')

const EC_P256 = { name: 'ECDSA', namedCurve: 'P-256' } as const
const EC_P256_VERIFY = { name: 'ECDSA', hash: 'SHA-256' } as const

export interface DeviceRecord {
  /** Base64 of the 65-byte uncompressed EC point (`0x04 ‖ X ‖ Y`). */
  publicKey: string
  /** Last accepted Secure Enclave counter. Must strictly increase. */
  signCount: number
  attestedAt: string
  tier: 'free' | 'pro'
}

export const deviceKvKey = (keyId: string) => `dev:${keyId}`

// ── Minimal DER reader ──────────────────────────────────────────────────────
// Used only to pull the nonce out of Apple's private certificate extension.

interface Tlv {
  tag: number
  value: Uint8Array
  nextOffset: number
}

function readTlv(buf: Uint8Array, offset: number): Tlv {
  if (offset + 2 > buf.byteLength) throw new Error('truncated DER')
  const tag = buf[offset]!
  let pos = offset + 1
  let length = buf[pos++]!
  if (length & 0x80) {
    const lengthBytes = length & 0x7f
    if (lengthBytes === 0 || lengthBytes > 4) throw new Error('unsupported DER length')
    length = 0
    for (let i = 0; i < lengthBytes; i++) {
      if (pos >= buf.byteLength) throw new Error('truncated DER length')
      length = (length << 8) | buf[pos++]!
    }
  }
  if (pos + length > buf.byteLength) throw new Error('DER value overruns buffer')
  return { tag, value: buf.subarray(pos, pos + length), nextOffset: pos + length }
}

const isConstructed = (tag: number) => (tag & 0x20) !== 0
const OCTET_STRING = 0x04

/**
 * Descend through constructed DER nodes and return the first OCTET STRING of
 * `expectedLength`. Apple documents the extension as
 * `SEQUENCE { [1] { OCTET STRING nonce } }`; walking generically keeps us
 * working if a wrapper layer is added, and a mismatched value still fails the
 * nonce comparison that follows.
 */
function findOctetString(der: Uint8Array, expectedLength: number, depth = 0): Uint8Array | null {
  if (depth > 8) return null
  let offset = 0
  while (offset < der.byteLength) {
    const tlv = readTlv(der, offset)
    if (tlv.tag === OCTET_STRING && tlv.value.byteLength === expectedLength) return tlv.value
    if (isConstructed(tlv.tag)) {
      const found = findOctetString(tlv.value, expectedLength, depth + 1)
      if (found) return found
    }
    offset = tlv.nextOffset
  }
  return null
}

// ── authenticatorData ───────────────────────────────────────────────────────

interface AuthenticatorData {
  rpIdHash: Uint8Array
  signCount: number
  /** Present on attestation only. */
  aaguid?: Uint8Array
  credentialId?: Uint8Array
}

const AUTH_DATA_HEADER_LENGTH = 37 // rpIdHash(32) + flags(1) + signCount(4)

function parseAuthenticatorData(authData: Uint8Array, withCredentialData: boolean): AuthenticatorData {
  if (authData.byteLength < AUTH_DATA_HEADER_LENGTH) throw new Error('authenticatorData too short')
  const view = new DataView(authData.buffer, authData.byteOffset, authData.byteLength)
  const parsed: AuthenticatorData = {
    rpIdHash: authData.subarray(0, 32),
    signCount: view.getUint32(33, false),
  }
  if (!withCredentialData) return parsed

  if (authData.byteLength < 55) throw new Error('authenticatorData missing attested credential data')
  const credentialIdLength = view.getUint16(53, false)
  if (55 + credentialIdLength > authData.byteLength) throw new Error('credentialId overruns authenticatorData')
  return {
    ...parsed,
    aaguid: authData.subarray(37, 53),
    credentialId: authData.subarray(55, 55 + credentialIdLength),
  }
}

// ── Attestation ─────────────────────────────────────────────────────────────

interface AttestationObject {
  fmt: string
  attStmt: { x5c: Uint8Array[]; receipt?: Uint8Array }
  authData: Uint8Array
}

function decodeAttestationObject(bytes: Uint8Array): AttestationObject {
  let decoded: unknown
  try {
    decoded = cborDecode(bytes)
  } catch {
    throw badRequest('attestation is not valid CBOR')
  }
  if (typeof decoded !== 'object' || decoded === null) throw badRequest('attestation is not a CBOR map')

  const obj = decoded as Record<string, unknown>
  const attStmt = obj.attStmt as Record<string, unknown> | undefined
  const x5c = attStmt?.x5c

  if (typeof obj.fmt !== 'string') throw badRequest('attestation is missing fmt')
  if (!(obj.authData instanceof Uint8Array)) throw badRequest('attestation is missing authData')
  if (!Array.isArray(x5c) || x5c.length < 2) throw badRequest('attestation is missing a certificate chain')
  if (!x5c.every((c): c is Uint8Array => c instanceof Uint8Array)) {
    throw badRequest('attestation certificate chain is malformed')
  }

  return { fmt: obj.fmt, attStmt: { x5c }, authData: obj.authData }
}

export interface VerifyAttestationInput {
  keyId: string
  /** Base64 of the CBOR attestation object from `DCAppAttestService`. */
  attestation: string
  /** The exact challenge bytes this proxy issued. */
  challenge: Uint8Array
  env: Env
}

/**
 * Returns the device's public key (base64 raw EC point) on success.
 * Throws a `ProxyError` on any verification failure.
 */
export async function verifyAttestation(input: VerifyAttestationInput): Promise<{ publicKey: string; signCount: number }> {
  const { keyId, env } = input
  const attestationBytes = (() => {
    try {
      return fromBase64(input.attestation)
    } catch {
      throw badRequest('attestation is not valid base64')
    }
  })()

  const attestation = decodeAttestationObject(attestationBytes)

  // 1. Format must be Apple's.
  if (attestation.fmt !== 'apple-appattest') {
    throw forbidden(`unexpected attestation format: ${attestation.fmt}`)
  }

  // 2. Chain must terminate at the pinned Apple App Attest root.
  const [credCertDer, ...intermediateDers] = attestation.attStmt.x5c
  const credCert = new x509.X509Certificate(credCertDer!.slice().buffer)
  const intermediates = intermediateDers.map((der) => new x509.X509Certificate(der.slice().buffer))
  const rootCert = new x509.X509Certificate(APPLE_APP_ATTEST_ROOT_CA_PEM)

  const now = new Date()
  let child: x509.X509Certificate = credCert
  for (const issuer of [...intermediates, rootCert]) {
    const ok = await child.verify({ publicKey: issuer.publicKey, date: now }).catch(() => false)
    if (!ok) throw forbidden('attestation certificate chain is not valid')
    child = issuer
  }
  // `rootCert` is the embedded copy, so reaching it *is* the pin. Verifying it
  // against itself additionally confirms the chain ended at a self-signed root
  // rather than stopping early at an attacker-supplied intermediate.
  if (!(await rootCert.verify({ publicKey: rootCert.publicKey, date: now }).catch(() => false))) {
    throw forbidden('attestation chain did not terminate at the Apple root CA')
  }

  // 3/4. nonce = SHA256(authData ‖ SHA256(challenge)); must match the cert extension.
  const clientDataHash = await sha256(input.challenge)
  const expectedNonce = await sha256(concat(attestation.authData, clientDataHash))

  const nonceExtension = credCert.getExtension(NONCE_EXTENSION_OID)
  if (!nonceExtension) throw forbidden('attestation certificate has no nonce extension')
  const presentedNonce = findOctetString(new Uint8Array(nonceExtension.value), 32)
  if (!presentedNonce) throw forbidden('attestation nonce extension is malformed')
  if (!timingSafeEqual(presentedNonce, expectedNonce)) {
    throw forbidden('attestation nonce does not match the issued challenge')
  }

  // 5. keyId must be SHA256 of the credential public key.
  const spki = credCert.publicKey.rawData
  const publicKey = await crypto.subtle.importKey('spki', spki, EC_P256, true, ['verify']).catch(() => {
    throw forbidden('attestation public key is not an EC P-256 key')
  })
  // `exportKey` is typed `ArrayBuffer | JsonWebKey`; the 'raw' format always
  // yields the former — the 65-byte uncompressed EC point.
  const rawPublicKey = new Uint8Array(
    (await crypto.subtle.exportKey('raw', publicKey)) as ArrayBuffer,
  )
  const derivedKeyId = await sha256(rawPublicKey)

  const presentedKeyId = (() => {
    try {
      return fromBase64(keyId)
    } catch {
      throw badRequest('keyId is not valid base64')
    }
  })()
  if (!timingSafeEqual(derivedKeyId, presentedKeyId)) {
    throw forbidden('keyId does not match the attested public key')
  }

  // 6. rpIdHash must be SHA256 of our App ID — binds the key to *this* app.
  const authenticatorData = (() => {
    try {
      return parseAuthenticatorData(attestation.authData, true)
    } catch (cause) {
      throw badRequest(`authenticatorData is malformed: ${(cause as Error).message}`)
    }
  })()
  const expectedRpIdHash = await sha256(utf8(appId(env)))
  if (!timingSafeEqual(authenticatorData.rpIdHash, expectedRpIdHash)) {
    throw forbidden('attestation was produced for a different App ID')
  }

  // 7. A fresh key has never signed anything.
  if (authenticatorData.signCount !== 0) {
    throw forbidden('attestation counter is not zero')
  }

  // 8. aaguid must match the environment. A development attestation accepted in
  //    production would let a debug build mint tokens.
  const aaguid = authenticatorData.aaguid!
  const aaguidOk =
    timingSafeEqual(aaguid, AAGUID_PRODUCTION) ||
    (env.APP_ATTEST_ENV === 'development' && timingSafeEqual(aaguid, AAGUID_DEVELOPMENT))
  if (!aaguidOk) throw forbidden('attestation aaguid is not accepted in this environment')

  // 9. credentialId must equal the keyId.
  if (!timingSafeEqual(authenticatorData.credentialId!, presentedKeyId)) {
    throw forbidden('credentialId does not match keyId')
  }

  return { publicKey: toBase64(rawPublicKey), signCount: 0 }
}

// ── Assertion ───────────────────────────────────────────────────────────────

interface AssertionObject {
  signature: Uint8Array
  authenticatorData: Uint8Array
}

function decodeAssertion(bytes: Uint8Array): AssertionObject {
  let decoded: unknown
  try {
    decoded = cborDecode(bytes)
  } catch {
    throw badRequest('assertion is not valid CBOR')
  }
  if (typeof decoded !== 'object' || decoded === null) throw badRequest('assertion is not a CBOR map')
  const obj = decoded as Record<string, unknown>
  if (!(obj.signature instanceof Uint8Array)) throw badRequest('assertion is missing signature')
  if (!(obj.authenticatorData instanceof Uint8Array)) throw badRequest('assertion is missing authenticatorData')
  return { signature: obj.signature, authenticatorData: obj.authenticatorData }
}

export interface VerifyAssertionInput {
  /** Base64 of the CBOR assertion object. */
  assertion: string
  /** The exact bytes the client signed. */
  clientData: Uint8Array
  device: DeviceRecord
  env: Env
}

/** Returns the new counter value to persist. Throws `ProxyError` on failure. */
export async function verifyAssertion(input: VerifyAssertionInput): Promise<{ signCount: number }> {
  const assertionBytes = (() => {
    try {
      return fromBase64(input.assertion)
    } catch {
      throw badRequest('assertion is not valid base64')
    }
  })()
  const assertion = decodeAssertion(assertionBytes)

  const clientDataHash = await sha256(input.clientData)
  const nonce = await sha256(concat(assertion.authenticatorData, clientDataHash))

  const publicKey = await crypto.subtle
    .importKey('raw', fromBase64(input.device.publicKey).slice(), EC_P256, false, ['verify'])
    .catch(() => {
      throw unauthorized('stored device key is unusable; re-attest the device')
    })

  const rawSignature = (() => {
    try {
      return derToRawEcdsaSignature(assertion.signature)
    } catch {
      throw unauthorized('assertion signature is malformed')
    }
  })()

  // Apple signs the nonce itself; WebCrypto applies SHA-256 over it.
  const signatureValid = await crypto.subtle.verify(EC_P256_VERIFY, publicKey, rawSignature.slice(), nonce.slice())
  if (!signatureValid) throw unauthorized('assertion signature is not valid for this device key')

  const authenticatorData = (() => {
    try {
      return parseAuthenticatorData(assertion.authenticatorData, false)
    } catch (cause) {
      throw badRequest(`authenticatorData is malformed: ${(cause as Error).message}`)
    }
  })()

  const expectedRpIdHash = await sha256(utf8(appId(input.env)))
  if (!timingSafeEqual(authenticatorData.rpIdHash, expectedRpIdHash)) {
    throw unauthorized('assertion was produced for a different App ID')
  }

  // The Secure Enclave counter is the replay defence: a captured assertion
  // carries a counter that is no longer greater than the stored one.
  if (authenticatorData.signCount <= input.device.signCount) {
    throw unauthorized('assertion counter did not advance (replay)')
  }

  return { signCount: authenticatorData.signCount }
}

/** Binary helpers. No Node APIs — everything here runs on the Workers runtime. */

export function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.byteLength, 0)
  const out = new Uint8Array(total)
  let offset = 0
  for (const p of parts) {
    out.set(p, offset)
    offset += p.byteLength
  }
  return out
}

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  // `data.slice()` detaches from any larger backing buffer, so a subarray view
  // never hashes its neighbours.
  const digest = await crypto.subtle.digest('SHA-256', data.slice())
  return new Uint8Array(digest)
}

/** Timing-safe equality. Length is not secret; content may be. */
export function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false
  let diff = 0
  for (let i = 0; i < a.byteLength; i++) diff |= a[i]! ^ b[i]!
  return diff === 0
}

export function fromBase64(input: string): Uint8Array {
  // Accept base64url as well — iOS clients commonly send either.
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/')
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4)
  let binary: string
  try {
    binary = atob(padded)
  } catch {
    throw new Error('invalid base64')
  }
  const out = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i)
  return out
}

export function toBase64(bytes: Uint8Array): string {
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary)
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
}

const encoder = new TextEncoder()
export const utf8 = (s: string): Uint8Array => encoder.encode(s)

/**
 * Convert a DER-encoded ECDSA signature (`SEQUENCE { INTEGER r, INTEGER s }`)
 * to the fixed-width `r ‖ s` form WebCrypto requires.
 *
 * App Attest assertions carry DER; `crypto.subtle.verify` with `ECDSA` wants
 * raw. Skipping this conversion makes every assertion fail verification.
 */
export function derToRawEcdsaSignature(der: Uint8Array, coordinateBytes = 32): Uint8Array {
  let pos = 0
  const readByte = (): number => {
    if (pos >= der.byteLength) throw new Error('truncated DER signature')
    return der[pos++]!
  }

  if (readByte() !== 0x30) throw new Error('DER signature is not a SEQUENCE')

  // Length octets. App Attest signatures are short, but parse long form anyway.
  let seqLen = readByte()
  if (seqLen & 0x80) {
    const lenBytes = seqLen & 0x7f
    if (lenBytes === 0 || lenBytes > 2) throw new Error('unsupported DER length')
    seqLen = 0
    for (let i = 0; i < lenBytes; i++) seqLen = (seqLen << 8) | readByte()
  }
  if (pos + seqLen !== der.byteLength) throw new Error('DER signature length mismatch')

  const readInteger = (): Uint8Array => {
    if (readByte() !== 0x02) throw new Error('DER signature component is not an INTEGER')
    const len = readByte()
    if (len & 0x80) throw new Error('unsupported DER integer length')
    if (pos + len > der.byteLength) throw new Error('truncated DER integer')
    let value = der.subarray(pos, pos + len)
    pos += len
    // Strip the leading 0x00 sign byte DER adds for values with the high bit set.
    while (value.byteLength > 1 && value[0] === 0x00) value = value.subarray(1)
    if (value.byteLength > coordinateBytes) throw new Error('DER integer too large for curve')
    const padded = new Uint8Array(coordinateBytes)
    padded.set(value, coordinateBytes - value.byteLength)
    return padded
  }

  const r = readInteger()
  const s = readInteger()
  if (pos !== der.byteLength) throw new Error('trailing bytes in DER signature')
  return concat(r, s)
}

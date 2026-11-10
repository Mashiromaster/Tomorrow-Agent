/**
 * Binary primitives.
 *
 * `derToRawEcdsaSignature` gets the most attention here: App Attest assertions
 * carry DER-encoded signatures while WebCrypto's `ECDSA` verify expects fixed
 * width `r ‖ s`. Get the conversion wrong — in particular the leading sign
 * byte DER adds whenever a component's high bit is set — and *every* assertion
 * fails verification, which looks exactly like a client bug.
 */

import { describe, expect, it } from 'vitest'
import {
  concat,
  derToRawEcdsaSignature,
  fromBase64,
  sha256,
  timingSafeEqual,
  toBase64,
  toBase64Url,
  toHex,
  utf8,
} from '../src/bytes'
import { generateP256KeyPair, rawToDerEcdsaSignature } from './helpers'

describe('base64', () => {
  it('round-trips arbitrary bytes', () => {
    const bytes = crypto.getRandomValues(new Uint8Array(96))
    expect(fromBase64(toBase64(bytes))).toEqual(bytes)
  })

  it('accepts base64url, which iOS clients commonly send', () => {
    // 0xFB 0xFF 0xBF encodes with both '+' and '/' in standard base64.
    const bytes = new Uint8Array([0xfb, 0xff, 0xbf])
    const standard = toBase64(bytes)
    const urlSafe = toBase64Url(bytes)

    expect(standard).not.toBe(urlSafe)
    expect(fromBase64(standard)).toEqual(bytes)
    expect(fromBase64(urlSafe)).toEqual(bytes)
  })

  it('accepts input with missing padding', () => {
    expect(fromBase64('aGk')).toEqual(utf8('hi'))
    expect(fromBase64('aGk=')).toEqual(utf8('hi'))
  })

  it('throws on input that is not base64', () => {
    expect(() => fromBase64('!!!')).toThrow(/invalid base64/)
  })
})

describe('timingSafeEqual', () => {
  it('compares content, not identity', () => {
    expect(timingSafeEqual(utf8('abc'), utf8('abc'))).toBe(true)
    expect(timingSafeEqual(utf8('abc'), utf8('abd'))).toBe(false)
  })

  it('returns false for differing lengths rather than throwing', () => {
    expect(timingSafeEqual(utf8('abc'), utf8('abcd'))).toBe(false)
    expect(timingSafeEqual(new Uint8Array(0), new Uint8Array(0))).toBe(true)
  })
})

describe('sha256', () => {
  it('matches the known digest of the empty string', async () => {
    expect(toHex(await sha256(new Uint8Array(0)))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    )
  })

  it('hashes only the view, not the whole backing buffer', async () => {
    const backing = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])
    const view = backing.subarray(2, 5)
    expect(await sha256(view)).toEqual(await sha256(new Uint8Array([3, 4, 5])))
  })
})

describe('concat', () => {
  it('joins in order', () => {
    expect(concat(utf8('ab'), utf8('cd'), utf8('ef'))).toEqual(utf8('abcdef'))
    expect(concat()).toEqual(new Uint8Array(0))
  })
})

describe('derToRawEcdsaSignature', () => {
  it('round-trips a real WebCrypto P-256 signature', async () => {
    const pair = await generateP256KeyPair()
    const raw = new Uint8Array(
      await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, utf8('payload').slice()),
    )

    expect(raw.byteLength).toBe(64)
    expect(derToRawEcdsaSignature(rawToDerEcdsaSignature(raw))).toEqual(raw)
  })

  it('round-trips many signatures, covering the high-bit sign-byte case', async () => {
    // One in four random signatures has a high bit set in r or s, which is
    // when DER prepends 0x00 and a naive parser produces a 65-byte component.
    const pair = await generateP256KeyPair()

    for (let i = 0; i < 40; i++) {
      const raw = new Uint8Array(
        await crypto.subtle.sign(
          { name: 'ECDSA', hash: 'SHA-256' },
          pair.privateKey,
          utf8(`payload-${i}`).slice(),
        ),
      )
      const converted = derToRawEcdsaSignature(rawToDerEcdsaSignature(raw))
      expect(converted.byteLength, `iteration ${i}`).toBe(64)
      expect(converted, `iteration ${i}`).toEqual(raw)
    }
  })

  it('left-pads a short component back to full width', () => {
    // r = 0x01, s = 0x02 — DER omits leading zeros, raw form must restore them.
    const der = new Uint8Array([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02])
    const raw = derToRawEcdsaSignature(der)

    expect(raw.byteLength).toBe(64)
    expect(raw[31]).toBe(0x01)
    expect(raw[63]).toBe(0x02)
    expect(raw.subarray(0, 31).every((b) => b === 0)).toBe(true)
  })

  it('strips the DER sign byte rather than treating it as data', () => {
    const r = concat(new Uint8Array([0x00, 0x80]), new Uint8Array(30))
    const der = rawToDerEcdsaSignature(concat(new Uint8Array([0x80]), new Uint8Array(31), new Uint8Array(32)))

    // 0x80 has its high bit set, so the encoder added 0x00 before it.
    expect(der[3]).toBe(0x21)
    expect(der[4]).toBe(0x00)

    const raw = derToRawEcdsaSignature(der)
    expect(raw.byteLength).toBe(64)
    expect(raw[0]).toBe(0x80)
    expect(r[1]).toBe(0x80) // sanity: the fixture is what we think it is
  })

  it('rejects malformed DER instead of returning a wrong signature', () => {
    expect(() => derToRawEcdsaSignature(new Uint8Array([0x02, 0x01, 0x01]))).toThrow(/not a SEQUENCE/)
    expect(() => derToRawEcdsaSignature(new Uint8Array([0x30, 0x40, 0x02, 0x01, 0x01]))).toThrow(
      /length mismatch/,
    )
    expect(() => derToRawEcdsaSignature(new Uint8Array([0x30]))).toThrow()
    // A component wider than the curve must not be silently truncated.
    const oversized = concat(
      new Uint8Array([0x30, 0x46, 0x02, 0x21]),
      new Uint8Array(33).fill(0x11),
      new Uint8Array([0x02, 0x21]),
      new Uint8Array(33).fill(0x22),
    )
    expect(() => derToRawEcdsaSignature(oversized)).toThrow(/too large for curve/)
  })
})

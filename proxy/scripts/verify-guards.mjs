#!/usr/bin/env node
// Exercises the proxy's refusal paths against a running instance.
//
//     node scripts/verify-guards.mjs                       # local wrangler dev
//     JWT_SIGNING_KEY=... node scripts/verify-guards.mjs \
//       --target https://<worker>.workers.dev
//
// ## What this covers that the unit tests do not
//
// `proxy/test/` drives the same logic through Miniflare, which is the real
// workerd engine — so this is not about a more faithful runtime. It is about
// the parts that only exist once something is deployed: that the secret
// actually in place verifies the tokens, that KV writes survive, that the
// guards sit where the deployed bundle puts them rather than where the source
// says they do.
//
// Every case here must be refused **before** the upstream call, which is what
// `x-pagent-error-source: proxy` asserts. That ordering is not cosmetic: a
// quota check after the forward would still return 429 while having already
// spent the money it exists to protect.
//
// The quota case is skipped unless --quota is passed, because it consumes the
// device's monthly allowance to prove exhaustion.

import { createHmac } from 'node:crypto'
import { readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const proxyRoot = path.resolve(here, '..')

// ── Arguments ───────────────────────────────────────────────────────────────

const options = { target: 'http://127.0.0.1:8787', quota: false }
for (let i = 2; i < process.argv.length; i++) {
  switch (process.argv[i]) {
    case '--target':
      options.target = process.argv[++i]
      break
    case '--quota':
      options.quota = true
      break
    case '--help':
    case '-h':
      console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n\nimport')[0])
      process.exit(0)
    default:
      fail(`unknown argument: ${process.argv[i]}`)
  }
}

function fail(message) {
  console.error(`\n✘ ${message}\n`)
  process.exit(1)
}

const isLocal = (() => {
  try {
    const { hostname } = new URL(options.target)
    return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]'
  } catch {
    return false
  }
})()

// Same rule as verify-cache.mjs: `.dev.vars` is the local secret and a
// deployment has its own, so never silently use one for the other.
function signingKey() {
  if (process.env.JWT_SIGNING_KEY) return process.env.JWT_SIGNING_KEY
  if (!isLocal) {
    fail(
      `JWT_SIGNING_KEY is not set, and ${options.target} is not a local wrangler dev.\n` +
        '  Pass the deployment\'s signing secret:\n\n' +
        `    JWT_SIGNING_KEY='<value>' node scripts/verify-guards.mjs --target ${options.target}`
    )
  }
  const devVars = path.join(proxyRoot, '.dev.vars')
  if (!existsSync(devVars)) fail('JWT_SIGNING_KEY is not set and proxy/.dev.vars does not exist.')
  for (const line of readFileSync(devVars, 'utf8').split('\n')) {
    const match = /^\s*JWT_SIGNING_KEY\s*=\s*"?([^"\n]+)"?\s*$/.exec(line)
    if (match) return match[1]
  }
  fail('proxy/.dev.vars has no JWT_SIGNING_KEY line.')
}

// ── Tokens ──────────────────────────────────────────────────────────────────

const secret = signingKey()
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const now = () => Math.floor(Date.now() / 1000)

function sign(claims, key = secret) {
  const input = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64(claims)}`
  return `${input}.${createHmac('sha256', key).update(input).digest('base64url')}`
}

/** A fresh subject per run, so a rerun is not charged the previous run's quota. */
const freshSubject = (label) => `${label}-${now()}-${Math.random().toString(36).slice(2, 8)}`
const validClaims = (sub) => ({ sub, iat: now(), exp: now() + 600, tier: 'free' })

const bodyFor = (model) =>
  JSON.stringify({ model, max_tokens: 1, messages: [{ role: 'user', content: 'hi' }] })

async function post(token, body) {
  const headers = { 'content-type': 'application/json', 'anthropic-version': '2023-06-01' }
  if (token) headers.authorization = `Bearer ${token}`
  let response
  try {
    response = await fetch(`${options.target}/v1/messages`, { method: 'POST', headers, body })
  } catch (error) {
    fail(
      `could not reach ${options.target}: ${error.message}\n` +
        (isLocal
          ? '  Is `npx wrangler dev --local` running?'
          : '  *.workers.dev is DNS-poisoned from mainland China and Node ignores\n' +
            '  the system proxy. Try NODE_USE_ENV_PROXY=1 HTTPS_PROXY=http://127.0.0.1:<port>')
    )
  }
  return {
    status: response.status,
    source: response.headers.get('x-pagent-error-source') ?? '-',
    retryAfter: response.headers.get('retry-after'),
    text: await response.text(),
  }
}

// ── Cases ───────────────────────────────────────────────────────────────────

const cases = [
  ['no Authorization header', null, bodyFor('deepseek-flash'), 401],
  ['signed with the wrong key', sign(validClaims(freshSubject('guard')), 'not-the-real-key'), bodyFor('deepseek-flash'), 401],
  ['expired token', sign({ ...validClaims(freshSubject('guard')), exp: now() - 10 }), bodyFor('deepseek-flash'), 401],
  ['unknown tier', sign({ ...validClaims(freshSubject('guard')), tier: 'enterprise' }), bodyFor('deepseek-flash'), 401],
  ['malformed token', 'not.a.jwt', bodyFor('deepseek-flash'), 401],
  ['no subject', sign({ ...validClaims(''), sub: '' }), bodyFor('deepseek-flash'), 401],
  ['model not on the allowlist', sign(validClaims(freshSubject('guard'))), bodyFor('gpt-4o'), 400],
  ['a different DeepSeek model', sign(validClaims(freshSubject('guard'))), bodyFor('deepseek-chat'), 400],
]

console.log(`target: ${options.target}\n`)
console.log('── Refusals ────────────────────────────────────────────────')

let failures = 0
for (const [name, token, body, expected] of cases) {
  const r = await post(token, body)
  // Both halves matter. The status says it was refused; the source says it was
  // refused *here*, before anything was spent upstream.
  const ok = r.status === expected && r.source === 'proxy'
  if (!ok) failures++
  console.log(
    `  ${ok ? '✔' : '✘'} ${name.padEnd(30)} ${r.status} source=${r.source}` +
      (ok ? '' : `  (expected ${expected} from proxy)\n      ${r.text.slice(0, 160)}`)
  )
}

// ── Quota ───────────────────────────────────────────────────────────────────

if (options.quota) {
  console.log('\n── Quota ───────────────────────────────────────────────────')
  console.log('  Spends real requests until the device is cut off.')

  const token = sign(validClaims(freshSubject('quota')))
  let exhaustedAt = null

  // Capped well below the configured limit so a misconfigured deployment does
  // not turn this into an unbounded spend.
  const CEILING = 12
  for (let i = 1; i <= CEILING; i++) {
    const r = await post(token, bodyFor('deepseek-flash'))
    if (r.status === 429) {
      exhaustedAt = i
      const days = r.retryAfter ? (Number(r.retryAfter) / 86400).toFixed(1) : '?'
      console.log(`  ✔ cut off on request #${i}, retry-after ${r.retryAfter}s (~${days} days)`)
      if (r.source !== 'proxy') {
        failures++
        console.log(`  ✘ but source=${r.source} — the upstream call was already made`)
      }
      break
    }
    if (r.status !== 200) {
      failures++
      console.log(`  ✘ request #${i} returned ${r.status} source=${r.source}: ${r.text.slice(0, 160)}`)
      break
    }
  }

  if (exhaustedAt === null) {
    console.log(
      `  — not exhausted within ${CEILING} requests. Lower FREE_MONTHLY_REQUESTS\n` +
        '    and redeploy to exercise this, then put it back.'
    )
  }
}

console.log(
  failures === 0
    ? '\nEvery guard refused before reaching upstream.'
    : `\n✘ ${failures} guard(s) did not behave as expected.`
)
process.exit(failures === 0 ? 0 : 1)

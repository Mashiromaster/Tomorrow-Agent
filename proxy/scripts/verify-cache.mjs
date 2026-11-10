#!/usr/bin/env node
/**
 * R8, live.
 *
 * ## What this answers that no offline test can
 *
 * The suites already prove the proxy forwards bytes verbatim, the client
 * encodes deterministically, and a timestamp in the stable prefix breaks four
 * assertions. All of that is necessary and none of it proves the cache is
 * *working* — because the failure mode is silent: the API returns 200,
 * `cache_read_input_tokens` stays 0, and every request pays cache-miss price
 * forever (30× the hit rate on `deepseek-v4-pro`).
 *
 * DeepSeek caches automatically, so there is no write step to observe — only
 * the read. The signal is therefore one field on the *second* call:
 *
 *   call 1   cache_read_input_tokens == 0   expected; the unit is being built
 *   call 2   cache_read_input_tokens  > 0   the prefix matched a persisted unit
 *
 * A zero on call 2 means the stable region differed between the two requests,
 * because a hit requires a **full match** against a persisted cache prefix
 * unit (`docs/DEEPSEEK.md`). Note caching is best-effort and construction
 * takes seconds, so a single zero is suggestive rather than conclusive — the
 * script retries before reporting failure.
 *
 * The two bodies are emitted separately, so they carry **different timestamps**
 * in the user turn. That is the real-world scenario: volatile content in the
 * tail must not disturb the stable prefix ahead of it.
 *
 * ## Usage
 *
 *     cd proxy
 *     cp .dev.vars.example .dev.vars    # then fill in DEEPSEEK_API_KEY
 *     npx wrangler dev                  # in another terminal
 *     node scripts/verify-cache.mjs                      # both models
 *     node scripts/verify-cache.mjs --model deepseek-v4-pro
 *     node scripts/verify-cache.mjs --target https://pagent-proxy.example.workers.dev
 *
 * Against a deployed proxy, `JWT_SIGNING_KEY` must match that deployment's
 * secret. Against `wrangler dev` it comes from `.dev.vars`.
 */

import { createHmac } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const proxyRoot = path.resolve(here, '..')
const coreRoot = path.resolve(proxyRoot, '..', 'core')

// ── Arguments ───────────────────────────────────────────────────────────────

function parseArguments(argv) {
  const options = { target: 'http://localhost:8787', models: [] }
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--target':
        options.target = argv[++i]
        break
      case '--model':
        options.models.push(argv[++i])
        break
      case '--help':
      case '-h':
        console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0])
        process.exit(0)
      default:
        fail(`unknown argument: ${argv[i]}`)
    }
  }
  if (options.models.length === 0) {
    // Both tiers §4.3 budgets for.
    options.models = ['deepseek-flash', 'deepseek-v4-pro']
  }
  return options
}

function fail(message) {
  console.error(`\n✘ ${message}\n`)
  process.exit(1)
}

// ── Device token ────────────────────────────────────────────────────────────

/**
 * Mints a device token directly, bypassing App Attest.
 *
 * Legitimate here, and worth being explicit about why: attestation is a
 * *separate* layer with its own 24 tests, and it cannot run off-device
 * (`DCAppAttestService` returns `invalidKey` without a provisioned App ID).
 * Signing a token with the deployment's own `JWT_SIGNING_KEY` exercises the
 * `/v1/messages` path under test without needing a device — and without
 * weakening the shipped code, since nothing in `src/` is modified.
 *
 * Must match `src/jwt.ts`: base64url(header).base64url(claims).base64url(hmac).
 */
function mintDeviceToken(secret, keyID, tier = 'pro', ttlSeconds = 900) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const signingInput = `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode({
    sub: keyID,
    tier,
    iat: now,
    exp: now + ttlSeconds,
  })}`
  const signature = createHmac('sha256', secret).update(signingInput).digest('base64url')
  return `${signingInput}.${signature}`
}

/** Reads `JWT_SIGNING_KEY` from the environment, falling back to `.dev.vars`. */
function signingKey() {
  if (process.env.JWT_SIGNING_KEY) return process.env.JWT_SIGNING_KEY

  const devVars = path.join(proxyRoot, '.dev.vars')
  if (!existsSync(devVars)) {
    fail(
      'JWT_SIGNING_KEY is not set and proxy/.dev.vars does not exist.\n' +
        '  cp proxy/.dev.vars.example proxy/.dev.vars   and fill it in.'
    )
  }
  for (const line of readFileSync(devVars, 'utf8').split('\n')) {
    const match = /^\s*JWT_SIGNING_KEY\s*=\s*"?([^"\n]+)"?\s*$/.exec(line)
    if (match) return match[1]
  }
  fail('proxy/.dev.vars has no JWT_SIGNING_KEY line.')
}

// ── Request body ────────────────────────────────────────────────────────────

/**
 * Asks the Swift executable for the real request body.
 *
 * Each call produces a fresh timestamp in the user turn, which is the point —
 * see the header note.
 */
function emitRequestBody(model) {
  try {
    return execFileSync(
      'swift',
      ['run', '--package-path', coreRoot, '-q', 'pagent-emit-request', model],
      { maxBuffer: 16 * 1024 * 1024 }
    )
  } catch (error) {
    const detail = error.stderr?.toString().trim() || error.message
    fail(`could not emit a request body for ${model}:\n${detail}`)
  }
}

// ── Send ────────────────────────────────────────────────────────────────────

/** Pulls `message_start` usage out of an SSE stream. */
function usageFromSSE(text) {
  for (const line of text.split('\n')) {
    if (!line.startsWith('data:')) continue
    const payload = line.slice(5).trim()
    if (!payload || payload === '[DONE]') continue
    let event
    try {
      event = JSON.parse(payload)
    } catch {
      continue
    }
    if (event.type === 'message_start' && event.message?.usage) return event.message.usage
    if (event.type === 'error') {
      fail(`the API returned an in-band error: ${JSON.stringify(event.error)}`)
    }
  }
  return null
}

async function send(target, token, body) {
  let response
  try {
    response = await fetch(`${target}/v1/messages`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
        accept: 'text/event-stream',
        'anthropic-version': '2023-06-01',
      },
      body,
    })
  } catch (error) {
    fail(
      `could not reach ${target}: ${error.message}\n` +
        '  Is `npx wrangler dev` running?'
    )
  }

  const text = await response.text()
  if (!response.ok) {
    fail(
      `HTTP ${response.status} from ${target}\n` +
        `  x-pagent-error-source: ${response.headers.get('x-pagent-error-source') ?? '(absent)'}\n` +
        `  ${text.slice(0, 600)}`
    )
  }

  const usage = usageFromSSE(text)
  if (!usage) fail('no message_start event in the response stream')
  return usage
}

// ── Report ──────────────────────────────────────────────────────────────────

function describe(label, usage) {
  console.log(
    `  ${label}  input=${usage.input_tokens ?? 0}` +
      `  cache_write=${usage.cache_creation_input_tokens ?? 0}` + // always 0 on DeepSeek
      `  cache_read=${usage.cache_read_input_tokens ?? 0}`
  )
}

async function check(target, token, model) {
  console.log(`\n── ${model} ${'─'.repeat(Math.max(0, 56 - model.length))}`)

  // Cache construction takes seconds and is best-effort, so one zero is not a
  // verdict. Up to three attempts, with a pause, before calling it a failure.
  let read = 0
  for (let attempt = 1; attempt <= 3 && read === 0; attempt++) {
    const usage = await send(target, token, emitRequestBody(model))
    describe(`call ${attempt}`, usage)
    read = usage.cache_read_input_tokens ?? 0
    if (read === 0 && attempt < 3) await new Promise((r) => setTimeout(r, 3000))
  }

  if (read === 0) {
    console.log(
      '\n  ✘ no cache hit after three attempts.\n' +
        '    A hit needs a full byte match against a persisted cache prefix unit,\n' +
        '    so this means the stable region differed between calls. That is the R8\n' +
        '    failure the offline suites are built to catch — diff two emitted bodies\n' +
        '    up to `"messages"` to find it:\n' +
        `      swift run --package-path core -q pagent-emit-request ${model} > /tmp/a.json\n` +
        `      swift run --package-path core -q pagent-emit-request ${model} > /tmp/b.json\n` +
        '      diff <(jq -S "del(.messages)" /tmp/a.json) <(jq -S "del(.messages)" /tmp/b.json)'
    )
    return false
  }

  console.log(`\n  ✔ cache hit: ${read} tokens read back.`)
  return true
}

// ── Main ────────────────────────────────────────────────────────────────────

const options = parseArguments(process.argv.slice(2))
const token = mintDeviceToken(signingKey(), 'verify-cache-local')

console.log(`target: ${options.target}`)

let allPassed = true
for (const model of options.models) {
  allPassed = (await check(options.target, token, model)) && allPassed
}

console.log(
  allPassed
    ? '\nR8 verified live for every model checked.\n'
    : '\nR8 is NOT satisfied for at least one model — see above.\n'
)
process.exit(allPassed ? 0 : 1)

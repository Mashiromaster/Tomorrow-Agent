# PAgent

*auto plan your tomorrow*

A resident personal agent for iOS. It builds an explainable picture of your
interests and rhythm from the system data you authorise, plans concrete
itineraries around your real constraints, and — only after you confirm —
writes them to your calendar.

Design document: [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md).
Current state: [`docs/PHASE0.md`](docs/PHASE0.md).
Model backend: [`docs/DEEPSEEK.md`](docs/DEEPSEEK.md).

## Four principles, and where they are enforced

Each row is a structural guarantee with a test that fails if it is removed —
not a convention.

| Principle | Enforcement |
|---|---|
| Raw data never leaves the device | Only a ≤500-token profile card is sent. `cloudKitDatabase: .none` on the store and no iCloud entitlement at all; the proxy cannot log request bodies (`RequestMetrics` has no field for them) |
| Writes require confirmation | `create_calendar_events` is not a tool. The model can only produce a proposal; `confirm(eventIdentifiers:at:)` is reachable only from `.presented`, called by the UI after a tap |
| The profile is explainable and vetoable | Every tag carries evidence rows tracing back to a source signal; a rejected tag is dropped from the card by the query itself, not ranked last |
| Device does atomic tasks, cloud does reasoning | Forced by the 4096-token on-device window (§2.1), not by preference |

## Layout

```
core/     PAgentCore  platform-independent logic (SPM)        262 tests ✅
          PAgentNet   proxy transport + device tokens          44 tests ✅
ios/      PAgentData  SwiftData schema (SPM)                   30 tests ✅
          App/        planner UI, App Attest, background task  compiles ✅
          ShareExtension/  §9.4 capture path                   compiles ✅
proxy/    Stateless Cloudflare Workers proxy                   81 tests ✅
docs/     IMPLEMENTATION.md · PHASE0.md · DEEPSEEK.md
```

The agent loop runs **on the device** (§3.1): it holds the `messages` array,
executes tools in-process against EventKit and MapKit, and appends results
locally. The proxy adds an API key and forwards bytes — it is stateless, stores
nothing, and understands nothing about calendars or interests.

## The model backend

DeepSeek, via its **Anthropic-compatible endpoint**
(`https://api.deepseek.com/anthropic`). Two models:

| Role | Model |
|---|---|
| Multi-day, multi-constraint planning | `deepseek-v4-pro` |
| Single-day planning, Q&A, cloud fallback for on-device classification | `deepseek-flash` |

Choosing the compatible endpoint meant the SSE parser, `ContentBlock` coding,
tool-call round trip, and the whole proxy passthrough carried over unchanged.
What did change is written up in [`docs/DEEPSEEK.md`](docs/DEEPSEEK.md), with
sources — the two that matter most:

- **Caching is automatic.** No `cache_control`, no minimum prefix length. A hit
  requires the request to *fully match* a persisted cache prefix unit, so byte
  stability matters as much as it ever did — only the markers went away.
- **~18× cheaper than the Anthropic design assumed.** A heavy user's month
  costs about **$0.074** against §4.3's $1.31, which is why the free tier is
  100 requests rather than 20.

## Running it

### `core/` — 306 tests

```sh
cd core
swift build
swift test
```

#### Driving a real turn from the command line

`AgentLoop` takes its transport and tool executor as protocols, so a macOS
CLI can run the shipping path — real `ProxyTransport`, real SSE parse, real
DeepSeek, real caching:

```sh
cd proxy && npx wrangler dev --local     # one terminal
cd core  && swift run pagent-chat        # another
swift run pagent-chat --model deepseek-v4-pro "周六上午排个行程"
```

Two things are substituted, and neither exists off-device anyway: the device
token is signed with the deployment's own `JWT_SIGNING_KEY` instead of App
Attest, and the EventKit/MapKit tools refuse every call — the same thing
`UnavailableToolExecutor` does in the app until Phase 1. A turn that needs a
tool therefore reports the refusal rather than inventing an answer, which
exercises §7.3's failed-tool recovery.

### `ios/` — 30 schema tests, plus the app build

```sh
cd ios
swift test                 # the SwiftData schema, on macOS

xcodegen generate          # PAgent.xcodeproj is generated, not committed
xcodebuild -project PAgent.xcodeproj -scheme PAgent \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The schema tests run under `swift test` on purpose: compiling a `@Model` class
does not prove SwiftData can *translate* it, and a bad `#Predicate` or an
unpersistable attribute fails at `ModelContainer` creation — which is to say at
launch. See [`ios/README.md`](ios/README.md).

Four `com.example` placeholders must be replaced before the app runs; the table
in `ios/README.md` lists them.

### `proxy/` — 81 tests

```sh
cd proxy
npm install
npm test          # vitest, in the real workerd runtime via Miniflare
npm run typecheck

cp .dev.vars.example .dev.vars    # then fill in the two secrets
npm run dev                        # local wrangler
```

## Deploying the proxy

```sh
npx wrangler login
cd proxy
./scripts/deploy.sh --dry-run     # see what it would do
./scripts/deploy.sh
```

The script creates the two KV namespaces, writes their generated ids into
`wrangler.jsonc`, checks both secrets are present, and deploys. It is
idempotent — re-running it is the normal way to confirm a deployment still
matches the config.

Secrets are never passed through the script, so they cannot land in a shell
history or a CI log:

```sh
npx wrangler secret put DEEPSEEK_API_KEY              # platform.deepseek.com
openssl rand -base64 48 | npx wrangler secret put JWT_SIGNING_KEY
```

**`APP_ATTEST_ENV` must be `production` before shipping**, together with
`appattest-environment` in `ios/App/PAgent.entitlements`. A production proxy
still accepting development attestations would let a debug build mint tokens
against the real API key. `deploy.sh` warns about this on every run.

### Verifying the cache (R8)

Sends the same request twice — with different timestamps in the user turn — and
reads `cache_read_input_tokens`. This is the one half of R8 no offline test can
reach: a broken cache produces no error, just a silent 30× input cost on
`deepseek-v4-pro`.

Against a local worker, which needs no Cloudflare account:

```sh
npx wrangler dev --local          # one terminal
node scripts/verify-cache.mjs     # another
```

Against the deployment, two things differ. The signing key is the deployed
secret, not the one in `.dev.vars`, and `wrangler secret put` is write-only —
so rotate it to a value you hold. And Node does not read the macOS system
proxy, which `workers.dev` currently requires:

```sh
KEY=$(openssl rand -base64 48)
printf %s "$KEY" | npx wrangler secret put JWT_SIGNING_KEY
NODE_USE_ENV_PROXY=1 HTTPS_PROXY=http://127.0.0.1:<port> \
JWT_SIGNING_KEY="$KEY" node scripts/verify-cache.mjs \
  --target https://<your-worker>.workers.dev
```

The script detects both of those situations and prints the fix rather than
failing with a bare 401 or `fetch failed`.

## Status

**417 tests pass.** The three Xcode targets build for the simulator with zero
errors and zero warnings under Swift 6 strict concurrency, and CI gates all of
it on every push.

**The proxy is deployed and R8 is verified live** against it — `deepseek-flash`
reads 1664 cached tokens, `deepseek-v4-pro` 1792. The full agent loop has also
been driven end to end from macOS with `swift run pagent-chat`: real transport,
real streaming, real tool rounds.

The Phase 0 acceptance criterion — a **real device** driving that round trip —
is **not met**, and that is now the only thing blocking it. App Attest returns
`invalidKey` off-device, which no amount of macOS testing can substitute for.

Before a device test is worth running, the proxy needs a **custom domain**:
`*.workers.dev` is DNS-poisoned from mainland China (measured, not assumed —
`docs/PHASE0.md` has the resolver output), so an iPhone there cannot reach it
and a failure would look like an App Attest bug.

`docs/PHASE0.md` has the full verified/unverified split, the mutation-test
results behind the R8 caching guarantees, the remaining blockers, and the
judgement calls worth a second opinion — notably `PrivacyInfo.xcprivacy`, the
one compliance artifact with no compiler and no test to catch drift.

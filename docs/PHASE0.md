# Phase 0 — status

> 2026-11-11 · against `IMPLEMENTATION.md` v1.0 §10 Phase 0
>
> The model backend moved from Anthropic to DeepSeek on 2026-11-11. §4.3 and
> §7.3 of the design document still describe the Anthropic surface; what
> actually ships is in `DEEPSEEK.md`, and the differences are called out below.

## Summary

Phase 0 lists four deliverables. **All four are done and tested.**

| §10 Phase 0 deliverable | Status |
|---|---|
| Cloudflare Workers 代理骨架：App Attest 校验 + SSE 透传 | ✅ **done** — 81 tests |
| SwiftData schema（§5 全部模型）+ 迁移策略 | ✅ **done** — compiles, 30 runtime tests |
| Xcode 项目骨架：App + ShareExtension + 共享 Framework 三 target | ✅ **done** — builds clean, 0 warnings |
| CI：`swift build` + Swift Testing，PR 门禁 | ✅ **done** — `.github/workflows/ci.yml`, all four suites |

**417 tests pass** across four packages. The three targets compile for the iOS
simulator with zero errors and zero warnings under Swift 6 strict concurrency,
and CI gates all of it on every push.

**Phase 0 acceptance** (真机跑通一次「本地构造 messages → 经代理 → 模型返回
流式文本 → UI 渲染」，不含任何个人数据) is **not met**. Both ends of that chain
are built and tested in isolation, `App/PlannerView.swift` is the screen that
will run it, and `proxy/scripts/deploy.sh` provisions the backend — but the run
itself needs a device, a deployed proxy, and a DeepSeek API key. See *Blocked*
below.

### One correction to the plan

§10 asserts the local machine has no Xcode and therefore no iOS SDK. The first
half was correct; the second was not — `SwiftData`, `CoreLocation`, and
`FoundationModels` all `canImport` from the Command Line Tools SDK. What was
genuinely blocked was narrower than "iOS code": it was **macros** (`@Model`,
`#Predicate`, `@Generable`) and UI/entitlement work.

That let most of Phase 1's and Phase 2's logic be built and tested before Xcode
arrived. Xcode 27.2 is now installed, which closed the macro gap — see
*What Xcode changed* below.

---

## What is where

| Package | Source | Tests | Status |
|---|---:|---:|---|
| `proxy/` — stateless proxy (TypeScript) | 1,441 | 1,620 | ✅ 81 passing |
| `core/PAgentCore` — pure logic | 3,063 | 3,746 | ✅ 262 passing |
| `core/PAgentNet` — proxy transport | 702 | 1,249 | ✅ 44 passing |
| `ios/PAgentData` — SwiftData schema | 951 | 637 | ✅ 30 passing |
| `ios/App` + `ios/ShareExtension` | 1,134 | — | ⚠️ compiles; see below |

```sh
cd proxy && npm test && npm run typecheck     # 81
cd core  && swift test                        # 262 + 44
cd ios   && swift test                        # 30
cd ios   && xcodebuild -project PAgent.xcodeproj -scheme PAgent \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

### `proxy/` — the stateless proxy

| Endpoint | Purpose |
|---|---|
| `POST /v1/attest/challenge` | Stateless, HMAC-signed enrollment challenge |
| `POST /v1/attest` | One-time App Attest enrollment; stores the device public key |
| `POST /v1/token/challenge` | Assertion challenge |
| `POST /v1/token` | Assertion → 15-minute device JWT |
| `POST /v1/messages` | Byte-exact passthrough to DeepSeek’s Anthropic-compatible endpoint |
| `GET /healthz` | Liveness |

Implemented from Apple's *Validating Apps That Connect to Your Server*: full
chain verification against a pinned App Attest root CA, nonce match, `keyId` ↔
public-key check, `rpIdHash` ↔ App ID check, aaguid environment check, and a
monotonic Secure Enclave counter for replay defence.

### `core/PAgentCore` — pure logic, no SDK imports

| Module | Covers |
|---|---|
| `TokenBudget` | §6.1 batching against a *read* `contextSize`; oversize items surfaced, never truncated |
| `InterestGraph` | §6.2 decay/reinforce, source weights, confirmed λ=0, rejected inert |
| `ProfileCard` | §6.3 ≤500-token render + measure + trim, pinned rhythm/geography lines |
| `AgentPrompt` | The frozen system prompt — `StaticString`, so it cannot carry a clock |
| `UntrustedContent` | §9.4 boundary framing with delimiter-forgery defence |
| `Availability` | §7.2 title redaction, free-slot interval arithmetic, routine windows |
| `ClaudeRequest` | §7.3 request shape, deterministic encoding, the R8 compile-time guard |
| `Tools` | §7.2 read-only tool surface |
| `StreamingResponse` | Chunk-safe SSE parser, `input_json_delta` accumulation, all stop reasons |
| `Router` | §7.1 intent → model, R2/R3 fallbacks, effort recommendations |
| `AgentLoop` | §3.1 device-side loop, parallel tools, merged `tool_result`s |
| `SignalRecord` / `Itinerary` | §5.1 signals and retention, §5.4 proposal lifecycle + feasibility |

### `core/PAgentNet` — the transport

`ProxyTransport` implements `PAgentCore.MessagesTransport`: attaches the device
token, re-authenticates once on a 401, maps status codes to typed errors, and
turns SSE bytes into `StreamEvent`s. Non-streaming responses (the §6.1 Flash
fallback) are replayed as the same event sequence, so the loop never needs to
know which mode produced a turn.

The logic is tested against a stubbed byte streamer; `URLSessionByteStreaming`
is a deliberately thin adapter at the edge. Those are the paths that only run
when something is already wrong — which is exactly when they are hardest to
exercise by hand.

---

## What Xcode changed

`libSwiftDataMacros.dylib` ships only inside Xcode, and it is what `@Model`,
`#Predicate`, and `#Index` need. Before Xcode, `ios/PAgentData` was
syntax-parsed only. Now:

| | Before | After |
|---|---|---|
| `@Model` macro expansion | ❌ impossible | ✅ 203 `PersistentModel`/`schemaMetadata` symbols in the built object |
| Type checking | ❌ blocked | ✅ device **and** simulator targets, 0 errors |
| Runtime schema validation | ❌ none | ✅ 30 tests |
| `core/` test invocation | needed `-Xswiftc -plugin-path …` | plain `swift test` |

### Three fixes, and one process note

**`#Predicate` and enum cases.** Three predicates needed rework, which
`ios/README.md` had predicted — but not the fix it predicted. Both inline
spellings fail: `.rejected` is "member access without an explicit base", and
`UserVerdict.rejected` becomes "key path cannot refer to enum case". A captured
local works, because the macro compiles its closure into a query expression and
a local arrives as a plain value. Full detail in `ios/README.md`.

**79 declarations made public.** `PAgentData`'s models were internal — written
when only the in-module test suite consumed them. Two app targets cannot see
internal declarations in a package.

**One strict-concurrency violation.** `BGTask` is not `Sendable` and the SDK
offers no async registration API. The first attempt (`MainActor.assumeIsolated`)
only moved the error, because that takes a `sending` closure. Resolved with a
single narrow `@unchecked Sendable` box whose comment describes a guarantee the
scheduler already makes rather than one we hope holds.

The process note: the first build reported errors only in
`InterestGraphModels.swift`, and the equivalent `.draft` comparisons in
`ItineraryModels.swift` appeared to compile. They did not — the compiler had
bailed before reaching that file. Worth remembering that "two errors reported"
is not "two errors."

---

## R8 — prompt caching, in detail

R8 is the risk most likely to cost money silently: a broken cache produces no
error, just a `cache_read_input_tokens` that stays at zero and a bill 30× what
it should be on `deepseek-v4-pro`.

### What the DeepSeek migration changed, and what it did not

**Changed: the mechanism.** DeepSeek caches on disk automatically and **ignores
`cache_control`** (`DEEPSEEK.md`). So the explicit breakpoints are gone —
including the second one added on 2026-11-10 to clear Opus's 4,096-token
minimum, which was inert here. `cachesConversation`, `BreakpointBlock`, and
`CacheablePrefix.cachingIsViable` were all deleted.

**Unchanged: the requirement.** A hit requires the request to **fully match** a
persisted *cache prefix unit*. One differing byte in the stable region still
costs the cache, exactly as before — so every guarantee below survived the
migration with only its justification rewritten.

It is covered at **three** points, because any one alone is insufficient.

**1. Construction (`core/PAgentCore`).** `AgentInstructions.init` takes a
`StaticString`. Swift forbids interpolation into one, so

```swift
AgentInstructions("Current time is \(Date())")   // does not compile
```

is rejected by the compiler. That is R8's "系统提示构造函数禁止传入时变参数（类型
层面约束）" as an actual type-level constraint rather than a review note. Time
reaches the model through `currentTimeBlock(at:timeZone:)`, which produces a
*user-turn* block — in the volatile tail, where a per-request value is free.
`ToolSet` sorts on construction, so an appended tool cannot reorder the prefix.
Encoding uses `.sortedKeys`, so bytes do not depend on Swift's per-process
dictionary seed.

**2. Transport (`core/PAgentNet`).** The body is encoded once and the same
`Data` is sent, including on the 401 retry. A re-encode before the retry is the
subtler half of the trap: the retry would carry semantically identical JSON
whose bytes might differ, so the unit the first attempt built would not match.

**3. Proxy (`proxy/`).** The request body is forwarded as the exact
`ArrayBuffer` that arrived. A decoded *copy* is parsed to read
`model`/`stream`/`max_tokens` for the allowlist; it is never re-encoded.

### These assertions were mutation-tested

Not assumed to work — each property was broken on purpose to confirm the test
fires:

| Mutation | Result |
|---|---|
| Proxy re-serialises: `body: JSON.stringify(JSON.parse(...))` | 2 tests fail — number and escape renormalisation caught |
| Client injects `Date()` into a third system block | 4 independent tests fail |
| Transport retry reuses the cached token instead of refreshing | 2 tests fail |
| 429 mapping ignores `x-pagent-error-source` | 1 test fails |
| `forProfileCard()` drops the rejected-tag filter | 1 test fails |
| `ModelConfiguration` enables CloudKit sync | 1 test fails |
| `RedactedEvent` ignores the title policy | 4 assertions fail |
| `UntrustedContent` skips delimiter neutralisation | 6 assertions fail across 4 tests |

Every file was restored and every suite re-run green afterwards.

### What is still unverified

That a **live** request reports `cache_read_input_tokens > 0`. That needs a
DeepSeek API key and a deployed proxy.

The check itself is written: `proxy/scripts/verify-cache.mjs` sends the same
request twice — bodies emitted separately, so they carry different timestamps in
the user turn — and reads the field. It sources its request body from
`swift run pagent-emit-request`, the **real** encoder, rather than a fixture; a
fixture would keep passing while the actual request path broke the cache, which
is precisely the failure R8 names.

It retries up to three times before reporting failure, because DeepSeek's cache
is best-effort and construction takes seconds — a single zero is not a verdict.

What *is* verified offline: the proxy observes and logs the field when upstream
sends it, `Usage.cacheHit` reads it correctly, and `PlannerView` puts it on
screen in green or grey, so a broken cache is noticed during development rather
than in a bill.

---

## Structural security properties

Three decisions from the document were implemented as structural guarantees
rather than conventions. Each has a test that fails if the guarantee is removed.

**`create_calendar_events` is not a tool** (§7.2, §9.4). The model can only
produce an `ItineraryProposalRecord`; the write path is
`confirm(eventIdentifiers:at:)`, reachable only from `.presented`, called by the
UI after a tap. A prompt-injected model — and shared web content is untrusted
input — has no path to EventKit at all. `ToolSurfaceTests` asserts that no tool
name contains a mutation verb and that every tool reads as a query.

**The proxy cannot log request content** (§4.2, §9). `RequestMetrics` has no
field capable of holding prompt or completion text, and `metrics.ts` is the only
module that calls `console.*`. The test drives a request carrying a distinctive
marker through the worker and asserts that marker — and the API key — appear in
no log line. Devices are identified by a truncated SHA-256 of the `keyId`, so
logs group for cost attribution without being device-linkable.

**Calendar titles cannot leave by accident** (§7.2). `RedactedEvent.init` takes
a `TitlePolicy` and stores the raw title *only* under `.allowTitles`; `title` is
`let` and there is no other initialiser. The model gets a category — the time
structure, not "和 X 谈离职".

### And one that is explicitly weaker

§9.4's boundary framing. The design is explicit that the structural protection
carries the weight, and the framing is the second line — which matters for what
is testable. "A model will not obey an injected instruction" is not a property
code can assert; it depends on the model. "A body cannot forge the closing
delimiter and escape its own box" *is* a property of this code, and that is what
the tests pin down: the whole `<<<` sequence is neutralised rather than just the
complete markers, and the truncation notice sits *after* the closing marker so a
body cannot forge "nothing was omitted".

---

## Not yet verified

### `ios/App/AppAttestTokenProvider.swift` — zero coverage

`DCAppAttestService` needs a provisioned device: unavailable in the simulator,
and it returns `invalidKey` without a real App ID. Every path in that file is
unexercised.

The mitigation is structural: the caching and single-flight policy lives in
`PAgentNet.CachingDeviceTokenProvider` and the retry/error mapping in
`PAgentNet.ProxyTransport`, both covered. What is left is three
`withCheckedThrowingContinuation` wrappers and a Keychain read.

### The SwiftUI layer

`PlannerView` and the Share Extension's `ShareViewController` compile but have
never been rendered. They are Phase 0 scaffolding — one text field, one stream,
one usage panel — and the UI worth testing arrives with Phase 1's proposal
cards.

### `PrivacyInfo.xcprivacy` — a judgement call worth a second opinion

The manifest declares the profile card and the user's typed text as
`OtherUserContent`, and declares the raw sources as *not collected*, on the
grounds that they never leave the device.

The card is however *derived from* calendar data, and a reviewer could
reasonably argue the source types belong in the manifest too. Over-declaring is
safe for review and misleading on the privacy label; under-declaring is a
rejection risk. The file documents the additive fix if review pushes back, plus
a per-phase table of what each later data source has to add. **It is the one
compliance artifact with no compiler and no test to catch drift** — re-audit it
whenever a data source is switched on.

---

## Blocked

| Blocked on | What it blocks |
|---|---|
| **Apple-Intelligence device** (iPhone 15 Pro+) | App Attest (the simulator returns `invalidKey`) · on-device model behaviour — §2.1 notes the simulator differs from a real device · guardrail false-positive rate (R3) · nightly digest battery measurement (<2%, Phase 2 acceptance) |
| **Apple Developer account** | Signing · the real `APPLE_TEAM_ID` / bundle ID / App Group · App Attest provisioning |
| **Anthropic API key + a deployed proxy** | Live cache-hit verification · the Phase 0 end-to-end acceptance |
| **A git repo** | CI, PR gating |

Note that `FoundationModels` imports fine, so the availability gating and the
`contextSize` / `tokenCount(for:)` plumbing can be written now — only the
`@Generable` macro output and real-device behaviour need hardware.

---

## Next steps

1. **Get a DeepSeek API key** from platform.deepseek.com, and
   `npx wrangler login`.
2. **Deploy the proxy.** `cd proxy && ./scripts/deploy.sh --dry-run`, then
   without the flag. The script creates both KV namespaces, writes their ids
   into `wrangler.jsonc`, and refuses to deploy if either secret is missing.
   It is idempotent, so re-running it is the normal way to confirm a
   deployment still matches the config.
3. **Verify the cache.**
   `node scripts/verify-cache.mjs --target https://<worker>.workers.dev`.
   This is the one half of R8 no offline test reaches, and it is the first
   thing that will confirm or refute the caching reasoning in `DEEPSEEK.md`.
4. **Fill in the four configuration placeholders** once there is an Apple
   Developer account — `ios/README.md` has the table. The one that matters
   most: `APP_ATTEST_ENV` / `appattest-environment` must be `production` on
   *both* sides before shipping, or a debug build can mint tokens against the
   real API key. `deploy.sh` warns about this on every run.
5. **Run the acceptance on a device.** `PlannerView` sends a placeholder card
   with no personal data, which is what §10 Phase 0 asks for. Send the same
   request twice and watch `cache_read_input_tokens` go green.
6. **Then Phase 1.** EventKit, the three device-side tools, and the proposal
   UI. The tool *protocol* and the loop already exist; what is missing is the
   EventKit and MapKit implementations behind `ToolExecuting`.

---

## Known gaps and judgement calls

Worth knowing before building on this:

- **Quota is a soft cap.** Workers KV has no atomic increment and is
  eventually consistent, so a device issuing concurrent requests from several
  edge locations can overshoot by roughly the number of in-flight requests.
  Adequate for bounding a stolen token's cost, which is what §4.2 asks for;
  `quota.ts` documents the Durable Object upgrade path, and `consume`'s
  signature is designed to port unchanged.
- **The assertion counter has the same race.** Two assertions arriving in
  different colos can briefly read the same stored counter. The window is small
  and bounded by the 15-minute token TTL; same remedy. `CachingDeviceTokenProvider`
  reduces the exposure from the client side by coalescing concurrent mints.
- **The §4.3 cost model is recomputed but unmeasured.** `DEEPSEEK.md` has the
  numbers, derived from the published rates and a *measured* prefix size. What
  is still estimated is the token count itself: it uses DeepSeek's rough
  guidance (~0.6 tok per Chinese character) rather than their offline
  tokenizer. Good enough to tell $0.07/month from $1.31; not good enough to
  bill against. The authoritative figures come back from the API as
  `input_tokens + cache_read_input_tokens`.
- **Peak/off-peak pricing is not modelled in code.** DeepSeek charges double
  during 01:00–04:00 and 06:00–10:00 UTC on weekdays, excluding Chinese public
  holidays. Nothing in the app or proxy is aware of this; the quota counts
  requests, not cost. A user who plans exclusively during peak hours costs 2×
  the off-peak estimate, which the current margin absorbs easily — revisit if
  the quota ever tightens.
- **Three `Effort` levels, not five.** DeepSeek maps `minimal`/`low` → low,
  `medium`/`high`/`xhigh` → high, `max`/`ultra` → max. The enum models only the
  three distinct levels, because sweeping the aliases would measure noise and
  conclude something false about cost.
- **`ItineraryItem.coordinate` deviates from §5.4**, which types it
  `CLLocationCoordinate2D?`. That struct is not `Codable`, so SwiftData cannot
  store it as a plain attribute. Replaced with a `Codable` `Coordinate`, which
  also keeps CoreLocation out of `core/`. Now confirmed to persist and
  round-trip correctly.
- **All-day events are not treated as busy by default.** Most are markers
  ("某人生日", "报销截止") rather than commitments, and treating them as busy
  would report a free user as fully booked — the more damaging of the two
  errors. They stay visible in `commitments` so the model can still reason
  about an all-day "出差"; `treatingAllDayAsBusy: true` is available per call.
- **`EventCategory.classify` is a keyword pass.** Phase 2 replaces it with the
  on-device model, which is what §7.1 routes `signalExtraction` to.
  Misclassification is cheap — every category is equally busy, so a wrong guess
  costs the model a little context and the schedule nothing.
- **Tier is hardcoded to `free` at enrollment.** StoreKit 2 is Phase 4 (§10);
  promotion will be a server-side write to `DeviceRecord.tier` after receipt
  validation.
- **`routingRationale` is not in §5.4's schema.** Added to `ItineraryProposal`
  because `modelUsed` alone records *what* was spent but not *why*, and R5's
  remedy is a routing review over real requests. R5 itself shifted with the
  migration: the misroute it names now costs ~7× (flash → v4-pro) rather than
  1.65×, so the *ratio* got worse while the absolute numbers became small
  enough that it is no longer a material risk at this scale.
- **`cloudKitDatabase: .none` is a compliance requirement, not a default.**
  §9.3 forbids writing HealthKit data to iCloud. Since `SignalEvent` holds every
  source in one table, enabling sync would propagate health signals the moment
  Phase 3 lands. The app also carries no iCloud entitlement at all, so the
  guarantee cannot be undone by a container setting changed later. Selective
  sync would need a separate container.
- **The system prompt has never been run against a model.** `PAgentPrompt.v1`
  is written and its invariants are tested (no clock, states the write
  boundary, declares the untrusted-content rule), but prompt quality is an
  iteration exercise that wants a real device and real traffic. Expect to
  revise it in Phase 1 — and note that changing those bytes invalidates every
  cached prefix at once, which is why it is versioned.

  It was also written for Claude and has not been re-tuned for DeepSeek. The
  instructions that matter structurally (no clock, no write capability,
  untrusted-content boundary) are backend-independent; the tone and verbosity
  guidance may not be.
- **Trimming tool descriptions beats trimming the prompt.** Measured: the five
  tool schemas cost ~889 tokens against the prompt's ~670, because ASCII JSON
  tokenises at roughly half the rate of Chinese prose. The character counts
  suggest the opposite, which is why this is recorded rather than left to
  intuition.

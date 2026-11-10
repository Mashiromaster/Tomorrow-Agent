# `ios/`

The iOS side: the SwiftData schema, the app, and the Share Extension.

```
Package.swift            PAgentData as an SPM package — so the schema is testable
PAgentData/              §5 models, queries, and the bridge to PAgentCore values
Tests/PAgentDataTests/   30 runtime schema tests
project.yml              XcodeGen spec for the two app targets
App/                     the app: planner UI, App Attest, background task
ShareExtension/          §9.4 capture path for shared links and text
```

`PAgent.xcodeproj` is generated and gitignored. Regenerate after editing
`project.yml`:

```sh
cd ios && xcodegen generate
```

## Verification status

| Layer | Status |
|---|---|
| `PAgentData/` — schema, queries, bridging | ✅ compiles + **30 runtime tests** |
| `App/` + `ShareExtension/` — three targets | ✅ **compiles, 0 errors, 0 warnings** |
| `App/AppAttestTokenProvider.swift` | ⚠️ **compiles only — zero coverage** |
| On-device behaviour end to end | ❌ needs a real device |

```sh
cd ios && swift test          # 30 tests — the schema
cd ios && xcodebuild -project PAgent.xcodeproj -scheme PAgent \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

### Why `PAgentData` is an SPM package and not just Xcode-target source

**Because compiling the schema does not verify it.** A `@Model` class that
compiles cleanly can still fail the moment `ModelContainer` tries to translate
it — a `Codable` struct SwiftData declines to persist, a `#Predicate` it cannot
lower into a query, an `@Relationship(inverse:)` keypath that does not pair up.
Those surface at container creation, which is to say at launch.

SwiftData runs on macOS, so `swift test` catches them. That is what the 30
tests in `Tests/PAgentDataTests/` are for, and it is how the four items that
were open questions before Xcode existed got settled.

### What `AppAttestTokenProvider` costs us

`DCAppAttestService` needs a provisioned device: it is unavailable in the
simulator and returns `invalidKey` without a real App ID. So every path in
that file is unexercised and there are no tests for it.

The response was to make it the thinnest possible shim. The caching and
single-flight policy lives in `PAgentNet.CachingDeviceTokenProvider`, the
retry and error mapping in `PAgentNet.ProxyTransport` — both covered by the 44
tests in `core/Tests/PAgentNetTests/`. What is left here is `withCheckedThrowingContinuation`
wrappers around three Apple callbacks and a Keychain read. Code that cannot be
tested should not also hold the decisions.

## What `#Predicate` actually required

`#Predicate` rejected the enum comparisons, as expected. The fix was **not**
what this file previously predicted, and the shape of the failure is worth
recording because the first correction made it worse:

```swift
$0.userVerdict != .rejected                 // error: Member access without an
                                            //        explicit base is not supported
$0.userVerdict != UserVerdict.rejected      // error: key path cannot refer to
                                            //        enum case 'rejected'
let rejected = UserVerdict.rejected
$0.userVerdict != rejected                  // ✅
```

Neither spelling works inline. The macro compiles its closure into a query
expression rather than merely typechecking it, and an enum case named inside
that closure becomes a key path on the metatype. A captured local arrives as a
plain value instead — which is also why `fromSource(_ source:)` compiled from
the start: its parameter was already a value.

Fixed in three places: `InterestTag.forProfileCard()`,
`InterestTag.awaitingReview()`, `ItineraryProposal.awaitingDecision()` and
`.committed()`.

One process note. The first build reported errors only in
`InterestGraphModels.swift`; the `.draft` comparisons in `ItineraryModels.swift`
looked fine. They were not — the compiler had bailed before reaching that file.
"Only two errors reported" is not the same as "only two errors."

## The other three open questions, now answered

| Question | Answer |
|---|---|
| Does SwiftData persist a `Codable` `Coordinate` as a stored attribute? | **Yes.** Round-trips exactly; `nil` stays `nil` rather than becoming (0, 0). The §5.4 deviation stands. |
| Do the `@Relationship(inverse:)` pairs wire up? | **Yes.** Both directions resolve, and `.cascade` removes orphaned `TagEvidence` / `ItineraryItem`. |
| Does `@ModelActor`'s generated `init` match the call site? | **Yes.** `RetentionSweeper(modelContainer:)` is what it generates. |

## The model backend

`App/PlannerView.swift` sends `deepseek-flash` through the proxy. Nothing in
this directory depends on which backend is in use — the request is built by
`PAgentCore` and the transport lives in `PAgentNet` — but the model name and
the `thinking: .enabled(...)` call site are here, so they are what changes if
the backend does. See `../docs/DEEPSEEK.md`.

## Configuration placeholders

Four values are `com.example` stand-ins. The app will not run until they are
real:

| Where | Value | Note |
|---|---|---|
| `project.yml`, both `Info.plist`s, both entitlements | `com.example.PAgent` | Bundle prefix |
| `App/PAgent.entitlements`, `ShareExtension/ShareExtension.entitlements`, `PAgentData/Schema.swift` | `group.com.example.PAgent` | App Group — **must match in all three** |
| `App/Info.plist` → `PAgentProxyBaseURL` | empty | Deliberately not defaulted; see `PAgentApp.swift` |
| `App/PAgent.entitlements` → `appattest-environment` | `development` | **Change to `production` before shipping**, together with the proxy's `APP_ATTEST_ENV` |

That last row is the one that matters. A production proxy still accepting
development attestations would let a debug build mint tokens against the real
API key — which is why it is called out in both files, from both sides.

## Design notes worth knowing before extending this

**The Share Extension writes and exits.** No summarising, no URL fetching, no
model call, and no App Attest entitlement — so there is no path from a hostile
shared page to the proxy through that process. Content is stored verbatim
(§5.1 replay, §9.4 untrusted input); sanitisation happens at render time in
`PAgentCore.UntrustedContent`.

**The store lives in the App Group**, because the extension is a separate
sandbox. If the group is unprovisioned, both processes refuse to start rather
than silently falling back to a private container — that failure mode presents
as "shared items sometimes vanish," which is far harder to diagnose than a
startup error.

**`NightlyMaintenance` runs retention before the digest, as separate passes.**
§9.3 undertakes that retention is automatic, and the digest is the part most
likely to fail (R3: guardrail false positives are a documented production
reality). Ordering them this way means a broken digest cannot quietly extend
the 180-day promise.

**`TaskHandle` is the only `@unchecked Sendable` in shipping code.** `BGTask`
carries no `NS_SWIFT_SENDABLE` and the SDK has no async registration API, so
something unchecked is unavoidable. The comment there describes a guarantee the
scheduler already makes — sole ownership handed to the launch handler — rather
than one we hope holds. (Three more live in test helpers, where a lock-guarded
recorder is the point.)

See `../docs/PHASE0.md` for the project-wide status and remaining blockers.

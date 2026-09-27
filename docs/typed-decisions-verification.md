# Typed decisions verification

Measured 27 September 2026 on the development Mac, macOS 27.0 (26A428),
Xcode 27.0 (27A266a), Swift 6.4. Package 0.1.0, contract 1, prompt 1,
Mail evidence policy `mail-evidence-v1`, rubric `mail-folder-fit-v1`.
The original brief is preserved byte-for-byte in `typed-decisions-brief.md`.

## Automated coverage

- Package: 10 offline tests pass; one live test is skipped unless explicitly enabled.
  Contracts cover ordering, boolean/choice/ordinal values, ID membership, invalid
  definitions, strict JSON, evidence isolation and insufficient evidence. Fake models
  cover independent sessions, comparative ordering, atomic errors, busy admission,
  cancellation and timeout while underlying work has not terminated. Backend schema
  tests cover explicit null decision values and fixed evidence-reference mappings.
- Shelf: 12 offline tests pass; one synthetic live Mail test is opt-in. Fixtures cover
  complete legacy top-five records after visible-message promotions, strong-hit
  precedence, six-candidate snapshots, omitted counts, shadow/fallback, protected
  stable ordering, stale selections, account/destination binding and evidence budgets.
  Four existing Safari identity tests are included in the count.
- Independent `Examples/DecisionConsumer` builds using only public package products;
  its document and task fixtures round-trip through `decision-replay --validate`.
  The core/backend package has no Shelf or third-party package dependencies.

## Live synthetic checks

Live checks used invented text, not the user's Mail or files, and the default on-device
model with greedy decoding. Generation required access to the normal user's model
service; the tool sandbox allowed availability checks but rejected actual generation.

| Check | Observed result |
| --- | --- |
| Three independent primitive questions | Complete typed response in 3.71 seconds |
| Two comparative candidates, no evidence references | Complete typed response in 1.31 seconds |
| Two comparative candidates with references | Complete typed response in 1.72 seconds |
| Actual Mail adapter, six synthetic folders | `shadow_ok` in 6.11 seconds, within the 8-second deadline |
| Two simultaneously launched consumer processes | Both completed two workflows; observed by 4.49 and 5.04 seconds, with their own namespaces |

These are single observations after development calls, not cold-start measurements,
percentiles, throughput guarantees or a sustained resource-contention test. Apple
exposes a runtime-managed model; no exact model asset revision is claimed.

For the six-folder fixture, baseline input was `f0,f1,f2,f3,f4,f5`; both proposed
policies returned `f0,f3,f2,f5,f1,f4`. The actual displayed list remained
`f0,f1,f2,f3,f4`. With an injected fixture that promotes `f5` above protected `f0`,
full reranking proposes `f5` first while the protected policy retains `f0` first.
These comparisons verify policy mechanics, not better destinations.

The document consumer classified the invoice and urgency as expected, but the boolean
task fixture returned false for "Please review the proposed meeting agenda." This is
a semantic error despite a valid contract, and remains a documented quality limitation.
The live tests assert structural contracts, not universal classification correctness.

During development the framework rejected enum-valued evidence arrays with an opaque
model-service error. Internal schemas now use fixed boolean support keys mapped back
to supplied evidence IDs; final live tests pass without retries or free-text repair.
A sparse development fixture also produced an inconsistent insufficient-evidence
status plus value; strict validation correctly rejected it instead of inventing a score.

## Build and reproduction

```sh
swift test --package-path Packages/TypedDecisions
swift test
swift build --package-path Examples/DecisionConsumer
Examples/DecisionConsumer/.build/debug/DecisionConsumer | Packages/TypedDecisions/.build/debug/decision-replay --validate
TYPED_DECISIONS_LIVE_TESTS=1 swift test --package-path Packages/TypedDecisions --filter LocalModelTests
TYPED_DECISIONS_LIVE_TESTS=1 swift test --filter MailDecisionAdapterTests/testOptInSixFolderLocalModelSnapshot
TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.921.5 make native-app
codesign --verify --deep --strict dist/Shelf.app
```

The explicit Metal toolchain is needed by Shelf's existing SwiftIntelligence dependency,
not TypedDecisions. The build selects an available development signing identity, or
accepts `SHELF_CODESIGN_IDENTITY` explicitly. Keep the development identity stable to
preserve privacy grants. Ad-hoc signing (`SHELF_CODESIGN_IDENTITY=-`) is only for
disposable builds and can invalidate existing Full Disk Access grants on rebuild.
The native release build and strict signature verification both passed; the resulting
bundle is `dist/Shelf.app`. Existing deprecated AppKit/SwiftUI calls still emit warnings.

## Promotion remains blocked

`rankingApproved` remains false and the default mode is off. Shadow mode can be enabled
in Settings and exports at most the last 100 in-memory, content-free assessment records.
It does not automatically collect content-bearing replay snapshots or change actions.

No prospective Mail accuracy, shortlist recall, harmful displacement, candidate-order
sensitivity, cold/warm distributions, UI profiling or sustained memory measurements
have been collected. No real message moves were performed for testing. The action
binding tests exercise pure identity checks, not every Mail/ScriptingBridge runtime case.
Older macOS runtimes and older SDK builds have not been exercised.

Before any live rerank rollout, collect authorized pre-move snapshots and observed
choices prospectively, freeze definitions, agree regression tolerances, and compare
full versus protected policies on the cases listed in `typed-decisions.md`. Include
all operational failures in end-to-end totals. Historical reconstruction from current
Mail state is not an acceptable substitute. This delivery establishes the reusable
foundation and shadow path, not evidence that model ranking improves Shelf.

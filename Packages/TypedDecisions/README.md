# TypedDecisions 0.1.0

An in-process Swift package for application-owned boolean, choice and ordinal decisions.
It has no Shelf dependency and no third-party package dependencies. Copy this directory
to its own repository and version/tag it to publish; Shelf currently uses a local path dependency.

## Products and contracts

| Product/API | Responsibility |
| --- | --- |
| `DecisionCore` | Immutable Codable/Sendable contracts, deterministic validation and app-scoped admission |
| `DecisionFoundationModels` / `AppleDecisionModel` | Built-in on-device Apple model, availability, schema compilation, token preflight and fresh sessions |
| `DecisionEngine.decide(_:timeout:) async throws` | Validate, admit one whole request, generate and validate atomic ordered results |
| `DecisionModel` | Injectable `availability()` and `generate(_:)` boundary for offline tests |
| `DecisionJSON.decodeRequest(_:)` | Strict JSON boundary rejecting unknown fields, invalid definitions and oversized records |
| `decision-replay` | One JSON request per stdin line; one typed result or explicit error per stdout line |

The core and consumer deployment target is macOS 13. The Apple backend is runtime-gated
to macOS 26 and requires eligible hardware, enabled Apple Intelligence and ready model assets.
This implementation is built and verified with Xcode 27 / Swift 6.4; it uses SDK 26.4 token
counting behind an availability check and also maps SDK 27 framework errors. Building
with an older SDK has not been verified. No custom model provider APIs are used.

Each caller creates its own engine with `DecisionEngine(model: AppleDecisionModel())` and
supplies a `DecisionRequest`. The identity includes app namespace, workflow/version,
contract version and request ID. Independent mode supplies ordered `Question` values;
comparative mode supplies `ComparativeAssessment` (instruction plus a versioned `Rubric`)
and ordered `DecisionCandidate` values. Examples live in `../../Examples/DecisionConsumer`.

Boolean definitions require explicit `yesWhen` and `noWhen` criteria, including the caller's
missing-information policy. Choices supply stable IDs, exact labels and descriptions;
rubrics supply at least two ordered levels. The model chooses an ID and the core derives
its exact label and zero-based score. `insufficient_evidence` carries neither value nor score.
Results preserve question/candidate order; the library does not rank application records.
Never compare ordinal scores across different rubrics or versions.

Independent mode calls the model separately for each question with a fresh session.
Comparative mode makes one joint call for the complete bounded set. A failure in any
question fails the entire request. The internal model schema uses safe `a0`, `a1`, ...
keys, runtime allowed-ID alternatives and an `@Generable` fixed boolean shape. Public
identities, labels and scores are assembled by code; no free-text JSON repair is used.
Evidence support uses fixed boolean keys mapped back to caller-supplied IDs; the public
response still contains an ordered evidence-ID array. This avoids an enum-array guided
generation failure observed on the tested macOS build.

## Limits, cancellation and ownership

Defaults: 8 questions, 8 candidates, 16 choices/levels, 32 evidence entries, 24,000 input
bytes and 12,000 definition/encoding bytes. These are configurable application limits,
not model limits. JSONL input is additionally capped at 64,000 bytes per record.
Default response reservation is 512 tokens plus 128 tokens of framing headroom; all
prompt, instructions and schema tokens are included in preflight against `contextSize`.
On macOS 26.0-26.3 a conservative UTF-8 byte upper bound replaces unavailable token
counting, so some otherwise valid requests may be rejected. No retries, truncation,
summaries, task splitting, tools, external inference or result caches are performed.

One engine admits one request at a time across its workflows. Concurrent calls return
`busy`; there is no queue. Cancellation or timeout resumes the waiting caller promptly,
cancels model work and discards its output, but retains admission until that work ends.
The default timeout is 8 seconds; callers can choose a positive duration up to 120 seconds.
An app should cancel superseded requests and independently check snapshot freshness.
Separate applications have separate gates and can contend for the system model.

Errors are `DecisionFailure` with `invalid_request`, `model_unavailable`, `context_limit`,
`refused`, `timeout`, `busy`, `cancelled` or `generation_failed`, plus a content-free reason.
Availability distinguishes unsupported OS/hardware, disabled intelligence, assets not
ready and unsupported locale. Refusal never becomes false or score zero.

`DecisionEngine` accepts a diagnostics closure reporting identity, elapsed time and outcome.
The package does not write files, transmit analytics, save prompts, share permissions,
retain sessions across requests or maintain application-global singletons. The caller
owns all input permissions, persistence and subsequent actions. Trust task definitions
only from app-authorized sources; definitions supplied via JSON require the same trust
decision as definitions supplied in Swift. Input and evidence are always treated as data.

## Build and replay

```sh
swift test --package-path Packages/TypedDecisions
swift run --package-path Examples/DecisionConsumer DecisionConsumer
swift run --package-path Packages/TypedDecisions decision-replay --availability
swift run --package-path Examples/DecisionConsumer DecisionConsumer | Packages/TypedDecisions/.build/debug/decision-replay --validate
TYPED_DECISIONS_LIVE_TESTS=1 swift test --package-path Packages/TypedDecisions --filter LocalModelTests
```

Commands above run from Shelf's root. The independently built consumer emits two unrelated
workflow fixtures by default and runs them only with `--live`; it imports public package
APIs and has no Shelf dependency. A JSONL record uses the Codable property names shown by
the emitted fixtures (camelCase); arrays, including empty arrays, are explicit. Ordinary
Swift calls require no JSON serialization. The CLI validates but does not authorize
externally supplied workflow instructions on the application's behalf.

Replay tools write only stdout. Redirecting requests/results explicitly creates local
content-bearing files owned by the caller: retain only for the evaluation, delete when
it ends, and exclude them from source control or shared locations. No replay capture is
enabled automatically. Live tests use synthetic text and are opt-in. Guided structure
does not guarantee semantic accuracy or repeatability across OS/model revisions.

Apple API references: [availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel),
[guided schemas](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation),
[sessions](https://developer.apple.com/documentation/foundationmodels/languagemodelsession),
[context budget](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window).

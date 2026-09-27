# Implementation brief: reusable typed decisions on a Mac

Build a standalone Swift package that multiple Mac applications can use for local, typed decisions through the built-in Apple Intelligence model. Each application can define multiple workflows that submit text and task definitions and receive well-defined yes/no answers, selected labels, ordinal scores and structured results. Shelf's Mail folder suggestions are the first consumer, not the package's organising abstraction.

The engine owns model interaction and output contracts. Workflows own their data sources, questions, labels, rubrics, evidence selection, fallback and any subsequent actions. No external model runtime, third-party checkpoint, cloud inference, training, probability distributions or confidence fields are required.

This self-contained brief supersedes the earlier generic and Mail-specific drafts. The Mail integration is a worked example with concrete constraints: preserve existing retrieval, semantic matching, move memory and user-confirmed actions; add optional reranking in shadow mode first. Its source description comes from the app owner and has not been independently inspected. Verify current code before editing.

## Platform and implementation shape

Use Swift's `FoundationModels` framework, `SystemLanguageModel.default` and `LanguageModelSession`. Target an eligible Apple-silicon Mac running macOS 26 or later, with Apple Intelligence enabled and its model assets ready. Check availability in the actual app user session; regional and language support also matter. No macOS 27 custom-provider APIs are needed.

Distribute one versioned Swift Package Manager dependency, independent of Shelf and every other consuming app. Each app links it and calls it in-process through public Swift types and `async throws` entry points. Keep JSON as a serialisation/replay interface, not a required hop between an app and the library. A thin JSONL CLI supports fixtures and local replay; no cross-app network service, daemon or singleton process is required.

## Shared engine and workflow boundaries

```text
Application workflow
  -> collect and bound input; define questions/labels/rubrics
  -> shared typed decision engine
       validate -> compile output schema -> admit -> generate -> validate
  -> typed result or explicit error
  -> workflow policy: display, sort, fall back or request confirmation
  -> application-owned action, if any
```

Keep three responsibilities separate:

* `DecisionCore` defines requests, result types, rubrics and deterministic validation. It has no Mail, Spotlight, UI or model dependencies and can be tested using plain fixtures.
* The Foundation Models implementation owns availability checks, schema compilation, prompt encoding, admission, cancellation and generation. It accepts application-prepared data and returns decisions; it does not collect evidence or execute actions.
* Workflow adapters own domain data, permissions, task definitions, evidence budgets, result interpretation and fallback. Existing application action handlers retain execution authority.

These can be targets within one standalone Swift package; do not create an ecosystem of packages or a plugin framework. Keep app/workflow adapters in their consuming apps or examples, outside the package's model-independent core. Use small public Swift types and an injectable model interface. Do not add a workflow DSL, automatic agent planning, tool calling or persistent conversation memory.

The shared engine must not import `ScriptingBridge`, `NSMetadataQuery`, `LatentSemanticMapping`, a Mail learning store or Shelf view types. Domain names such as `folder`, `sender` and `move` belong in the Mail adapter, never in the shared request model.

For example, document workflows can select a document type and urgency level; task workflows can answer whether an item is actionable and assign a priority; routing workflows can choose an allowed destination; candidate-selection workflows can assess alternatives against one rubric. Each defines its own permitted values and missing-information policy. None requires changing the engine's three decision primitives.

## Reuse across applications

Sharing a package shares implementation, not application data. Each app owns its engine instance, configuration, permissions, workflow definitions and lifecycle. It must obtain its own access to Mail, files or other resources and pass plain immutable snapshots to the package. No app implicitly inherits another app's permissions or Apple Intelligence availability.

Keep sessions, result caches, evidence stores and diagnostics isolated by app and workflow. Do not introduce a shared disk store, App Group, shared Keychain entry, global learning database or cross-app transcript. Immutable schema caches may be process-local and keyed by the complete schema identity; avoid model-result caching in the first implementation.

Use an app namespace with workflow IDs in local records to avoid collisions. These are identifiers, not authentication or permission grants. The package should accept injected diagnostics hooks with content omitted by default, rather than writing to an app-specific filesystem location.

One app-scoped engine coordinates admission across that app's workflows. Separate apps have separate processes and may contend for the system model; the library cannot claim device-wide exclusive access. Handle framework resource errors and test two consumer processes on the target Mac. A cross-app scheduler would require a separately approved service architecture and is outside this brief.

Consumers may have different deployment targets. Availability-gate the Foundation Models implementation so an app that supports older macOS can keep its existing non-model path. The package's core types and fake-model tests should not require the built-in model to be present. Verify the selected SDK's build and runtime availability requirements rather than raising every app's deployment target unnecessarily.

## Workflow contract and execution modes

Every invocation carries a contract version, workflow ID/version and request ID. Its ordered questions supply unique IDs, explicit instructions and either boolean criteria, allowed choices or an ordered rubric. Workflow definitions can be ordinary Swift values or validated data; no runtime plugin discovery is needed.

The workflow supplies a bounded input snapshot and optionally evidence records with opaque IDs. The engine treats input text and evidence as data. Trusted app code supplies or authorises the task definition; validate externally supplied definitions before accepting them as classifier instructions. Persist enough definition/version information to interpret results later without requiring live application state.

Support two explicit modes using the same primitives:

| Mode | Behaviour | Typical use |
|---|---|---|
| `independent` | Fresh session for each question using the same input snapshot; assemble results in question order. Default. | Unrelated extraction/classification questions, yes/no checks, rubric assignment |
| `comparative` | One bounded session sees all supplied alternatives and their common rubric; returns one assessment per alternative. | Mail folders, routing alternatives or other shortlists with overlapping meanings |

An independent request supplies `state` and ordered `questions`. A comparative request supplies `state`, one assessment instruction, a versioned ordered `rubric`, and an ordered `candidates` array of opaque IDs and descriptive data/evidence. Reuse the ranked-score primitive to assess each candidate. Candidate IDs must be unique, and a successful response contains exactly one assessment for each ID, in input order. Keep the generic candidate type free of domain-specific fields; the app encodes its bounded descriptive data.

Comparative mode is an explicit workflow choice because outputs can influence one another. The engine does not silently switch modes to save calls or split a comparative task when context is exhausted. Whole-request results are atomic initially: complete validated results or an error, never a mixture from partly completed generation.

Separate three kinds of order: declaration order controls prompt/schema presentation, result arrays preserve input identity/order, and any ranked list is application-derived from validated scores. A reusable stable-sort helper may sort results only when they share the same question/rubric version. Ranking policy and business priorities remain workflow-owned.

An ordinal level is not a universal priority score. A document urgency score, a task importance score and a Mail suitability score cannot be merged numerically. Workflows define whether higher scores sort first, how ties are handled and whether baseline rules override model decisions.

Where required, a workflow can declare an `insufficient_evidence` outcome with no decision value. Keep that semantic outcome separate from a framework refusal or operational error. Never make `false`, the first label or score `0` the implicit missing-information fallback. The engine returns the outcome; the workflow decides whether to ask the user, retain a baseline or stop.

Workflow policy also owns deadlines and freshness. Pass cancellation and request identity into the engine, then discard results that no longer match the application's current input snapshot. Use one app-owned engine and admission gate per process across its workflows, without a library-global singleton. Initially return `busy` rather than adding an internal queue. Superseded interactive requests must be cancelled; if the old call has not terminated, keep the workflow fallback and return `busy`. Do not accumulate stale selections ahead of current work.

## Reusable typed decisions

| Request type | Model-generated value | Application-owned result |
|---|---|---|
| `boolean` | A `Bool` | Question ID, type and `true`/`false` value |
| `choice` | One allowed option ID | Selected ID and its exact caller-supplied label |
| `ranked_score` | One allowed rubric-level ID | Selected ID, exact label and zero-based integer score |

A boolean question must define yes/no conditions and how absent evidence is treated. A refusal or runtime error must never become `false`. If a task needs an unknown outcome, use an explicit choice or an application-defined assessment status.

Choice options have unique stable IDs, distinct labels and short descriptions. Preserve the caller's order. Constrain generation to IDs; application code looks up labels rather than allowing the model to invent or alter them.

Ranked-score levels are ordered from lowest to highest. Their array positions define scores `0` through `N-1`; each level needs a description. Higher means more of the named property, such as suitability or severity. The application derives the score and label from the selected ID. Scores are only comparable under the same rubric and version.

Use ordered arrays for questions, choices and levels. Require non-empty questions, unique question IDs, at least one choice option and at least two rubric levels. Reject invalid definitions and unknown fields before inference. JSON object key order is not an interface guarantee.

A compact generic example, with an inline rubric supplied by the workflow:

```json
{
  "schema_version": 1,
  "workflow_id": "service-triage",
  "workflow_version": 1,
  "request_id": "example-1",
  "mode": "independent",
  "state": "The service is unavailable to every user and there is no workaround.",
  "questions": [
    {"id": "blocked", "type": "boolean", "prompt": "Is access explicitly blocked?", "yes_when": "Users cannot access the service.", "no_when": "Access is possible or blocked access is not established."},
    {"id": "team", "type": "choice", "prompt": "Which team should handle this?", "options": [
      {"id": "billing", "label": "Billing", "description": "Charges and invoices."},
      {"id": "technical", "label": "Technical", "description": "Service faults and access failures."}
    ]},
    {"id": "impact", "type": "ranked_score", "prompt": "Select the operational impact.", "levels": [
      {"id": "low", "label": "Low", "description": "Work can continue normally."},
      {"id": "high", "label": "High", "description": "Work is blocked without a workaround."}
    ]}
  ]
}
```

Illustrative response, not a measured model result:

```json
{
  "schema_version": 1,
  "workflow_id": "service-triage",
  "workflow_version": 1,
  "request_id": "example-1",
  "status": "ok",
  "answers": [
    {"id": "blocked", "type": "boolean", "value": true},
    {"id": "team", "type": "choice", "value": "technical", "label": "Technical"},
    {"id": "impact", "type": "ranked_score", "value": "high", "score": 1, "label": "High"}
  ]
}
```

The generic interface returns answers in question order. Independent questions use separate fresh sessions initially. A ranked score does not itself rearrange records; sorting belongs to the caller.

## Shared structured-output implementation

Use `@Generable` for fixed internal shapes, and `DynamicGenerationSchema` plus `GenerationSchema` for runtime labels, rubric levels and field definitions. Constrain selections to allowed IDs using runtime string alternatives. Descriptions explain the distinctions; application code supplies IDs, metadata, labels and derived scores in the final result.

Separate the internal generated schema from the public result schema. The model generates only boolean values or selected option/level IDs, permitted outcome statuses, and optional supplied evidence references. Use candidate/question identifiers only where needed to map generated records. Labels, integer scores, version/request metadata and ranked lists are derived by trusted code after validation; do not request or accept them from the model.

Validate generated membership, cardinality and cross-field rules even when generation is schema-constrained. Assemble the public response using application types and `Codable`/`JSONEncoder`. Do not repair free-text JSON, coerce unknown labels to nearby options, or return partially streamed objects as final decisions.

Keep nested output predictable: ordered arrays of typed answers, assessments or records assembled by the application are sufficient initially. Fixed workflow-specific `@Generable` records can be added through a typed entry point if needed. An arbitrary recursive schema language is not required for the first delivery.

Keep task templates, generation settings and schema versions explicit. Share only immutable metadata or compiled schemas with matching identities; do not reuse transcripts across requests or workflows. Prefer greedy decoding initially, without promising identical decisions across OS/model updates. Operational errors are workflow-neutral; fallback is not built into model generation.

## Worked integration: Mail folder suggestions

### Existing Mail pipeline to preserve

The owner describes the following implementation; inspect these locations before making changes.

| Stage | Current behaviour described by the owner | Source to inspect on the Mac |
|---|---|---|
| Collection | Mail `ScriptingBridge` / `SBApplication` reads the selected message and folders. Spotlight `NSMetadataQuery` and a local Mail-header cache supply candidate messages. | `Sources/Shelf/SpotlightMessageRanker.swift:163` |
| Semantic matching | `LatentSemanticMapping` trains a category per folder on up to eight candidate messages; `LSMResultGetScore` compares the selected message with each category. | `SpotlightMessageRanker.swift:789` |
| Message scoring | Combines retrieval rank, LSM similarity, direct matches and move-memory evidence. | `SpotlightMessageRanker.swift:390` |
| Move memory | Successful moves are compared using sender/thread equality, subject/body overlap, recency, frequency and separate LSM similarity. These can supply fallback suggestions without related-message hits. | `Sources/Shelf/MailMoveLearningStore.swift:195` |
| Folder ranking and action | Excludes Trash/Junk/Spam, groups evidence by folder, promotes strong repeated evidence or at least two visible related messages, and offers the top five. `moveTo:` runs after the user chooses an action. | `SpotlightMessageRanker.swift:468` |

Source root: `/Users/rcarmo/Build/shelf`. Line numbers are navigation hints and may change.

The owner supplied this candidate-message score for a real similar-message hit:

```text
max(1, 81 - rank)
+ 80 * LSM
+ 80 * match
+ 160 * moveMemory
+ 8 * min(moveCount, 6)
+ 12 * min(senderMoveCount, 6)
+ 26.7
```

`match` adds 1.2 for the same sender, 0.9 for the same thread, 0.5 for a Mail-native match, and up to 0.45 for subject overlap. Retain this calculation and the existing folder aggregation/promotion logic unchanged for the baseline. The message-level formula is not a specification of the final folder sort key; inspect that separately.

### Integration point

Create a snapshot after eligibility filtering, evidence grouping and baseline folder ranking, but before reducing the list to the five displayed actions:

```text
Existing collection + LSM + move memory
    -> existing folder filtering, aggregation and baseline order
    -> immutable shortlist/evidence snapshot
    -> optional Apple Intelligence assessment
    -> validation and application ranking policy
    -> existing five suggestion actions
    -> user choice -> existing moveTo: handler
```

Preserve the baseline top five and the full baseline shortlist order. Include more than five candidates when the context budget permits; a reranker cannot recover a destination omitted from its input. Use the existing baseline order to select the shortlist and preserve move-memory-only candidates where the baseline includes them.

Attach a request generation token and stable identity for the selected message to each snapshot. If the selection, message, account or candidate set changes while inference is running, cancel or discard the stale result. Verify the message and destination again when the user activates an action. A folder's display name is insufficient identity, especially across accounts or nested mailboxes.

Do not move buttons underneath an active pointer or keyboard selection when a late result arrives. Keep displayed actions stable once interaction begins, or apply the new ranking on the next suggestion refresh. A late or stale result must never change what an already chosen action does.

### Mail evidence supplied to the model

Supply a compact description of the selected message: sender, subject and a bounded body excerpt. Each candidate folder gets an opaque request-local ID, an account-qualified display path where necessary, and evidence that explains its use:

* Representative subjects and short excerpts from messages actually filed there.
* Application-computed same-sender and same-thread facts, plus source-message references.
* Related-message counts, including whether these are visible related messages used by the existing promotion rule.
* Relevant successful previous moves and the supporting recency/frequency facts already available to the app.

Retain existing numeric scores and exact baseline position in the application snapshot. The initial model prompt can use concrete evidence without the arbitrary composite score, reducing pressure to repeat the baseline ranking. Any experiment that exposes the score should be labelled separately.

Give evidence items request-local IDs. Keep provenance and exact folder/message mappings in application code. Deduplicate overlapping hits from Mail, Spotlight, the header cache and move memory so the model does not mistake repeated descriptions of one event for independent support.

Compute sender/thread equality in code; do not spend a model call asking it to rediscover those facts. Restrict its role to semantic suitability based on the supplied evidence. No mailbox scans, body fetches, online lookups or tools may be initiated by the model.

Evidence selection is an explicit, versioned preprocessing policy: fixed excerpt limits, deterministic representative selection and recorded omitted-item counts. Never describe a partial excerpt as a complete message. If the policy cannot produce the required bounded snapshot, make no model call and record an adapter outcome such as `evidence_budget_exceeded`; use the baseline. Separately, the engine can report `context_limit` during token preflight or generation even when the adapter's limits passed. Neither outcome permits iterative trimming to force success. Do not add model-generated summaries in the first version.

### Folder suitability rubric

Use one application-owned rubric, `mail-folder-fit-v1`, shared by every candidate in a request:

| Score | ID | Meaning |
|---:|---|---|
| 0 | `unsuitable` | Supplied evidence positively indicates a different purpose or topic. |
| 1 | `weak` | A broad connection exists, with little support for filing here. |
| 2 | `plausible` | Topic or usage fits, but supporting evidence is incomplete. |
| 3 | `strong` | Clear fit supported by related messages or established filing behaviour. |
| 4 | `direct` | Clear continuation of a conversation or filing pattern represented in this folder. |

Lack of evidence is not evidence of unsuitability. Add a separate `insufficient_evidence` assessment status with no level or numeric score. For the initial reranking policy, if any candidate cannot be assessed, retain the complete baseline ranking rather than inventing a comparison with scored candidates. Record the outcome for evaluation.

A level is an ordinal category. Do not add it to the current weighted score, average it with LSM or treat the gaps between adjacent levels as calibrated numerical distances.

### Mail output and validation

Assess the whole bounded shortlist in one fresh session. Folder suitability is a comparative task: folders can overlap in meaning, so joint assessment is a deliberate exception to independent generic questions. This can introduce ordering effects; test candidate-order permutations.

Require exactly one assessment per supplied candidate. The model selects a level/status and, optionally, supporting evidence IDs from those supplied for that candidate. It does not generate folder names, scores, request metadata or actions.

Illustrative application-owned response for a two-candidate test fixture; `e1` and `e2` are evidence items supplied for their respective candidates:

```json
{
  "schema_version": 1,
  "workflow_id": "mail-folder-suggestions",
  "workflow_version": 1,
  "request_id": "mail-selection-17",
  "rubric_id": "mail-folder-fit-v1",
  "status": "ok",
  "assessments": [
    {"candidate_id": "f1", "status": "assessed", "level": "weak", "score": 1, "evidence_ids": ["e1"]},
    {"candidate_id": "f2", "status": "assessed", "level": "strong", "score": 3, "evidence_ids": ["e2"]}
  ],
  "ranked_candidate_ids": ["f2", "f1"]
}
```

Return `assessments` in the original shortlist order. Application code derives `score` from the rubric and constructs `ranked_candidate_ids`. Keep the model's raw candidate assessments separate from whichever ranking is actually displayed, particularly in shadow mode.

Use `@Generable` for fixed internal shapes and `DynamicGenerationSchema`/`GenerationSchema` for runtime allowed values. Internally, a per-candidate property schema with application-generated safe keys can avoid relying on an array to enforce uniqueness. If used, validate it by key, then reconstruct the public `assessments` array strictly from the input candidate order; never enumerate object keys to establish order. An internal array instead requires explicit completeness, membership and uniqueness checks. Constrained generation alone does not enforce every cross-field rule.

Reject unknown/missing/duplicate candidate IDs, unsupported levels, evidence references from the wrong candidate, inconsistent statuses, or malformed values. Do not accept a partial assessment set or repair it by assigning missing candidates a low score. The model does not produce the ranking. For `insufficient_evidence`, require score and level to be absent. Evidence references show what the model selected as support; they do not prove that its interpretation is correct.

Serialise the validated result using application types and `Codable`/`JSONEncoder`. Do not ask for free-text JSON and repair it afterwards. Do not publish partial streamed objects as final decisions. Explanations and generated rationale text are outside the initial scope.

### Mail ranking policies and rollout

Start with a feature flag whose modes are `off`, `shadow` and, only after evaluation, `rerank`.

In `off`, preserve the exact existing path. In `shadow`, run and record model assessments without changing actions. In `rerank`, proceed only if all candidates have valid assessed levels. Apply a stable sort by derived suitability score descending over the immutable baseline shortlist order. Equal levels retain that order, which already includes the app's numeric scores and promotions; introduce no other tie-breaker or folder-score aggregation.

If any candidate has `insufficient_evidence`, do not construct or use a reranked display list. Retain the exact baseline shortlist order. Operational or validation failures have the same display fallback but different diagnostic outcomes.

Compare full reranking against a conservative policy that applies the same stable sort only within pre-declared baseline evidence groups. Inspect existing promotion rules before defining those groups. Do not silently remove strong-evidence protections during integration. Choose the active policy from measured results, and record its version.

Return the first five candidates from the accepted ordering, or all candidates if fewer exist. Ranking cannot introduce new folders or bypass Trash/Junk/Spam exclusions and other existing eligibility rules. Learning updates still occur only after a successful user-confirmed move, never from a model prediction or merely displaying an action.

## Shared availability and resource handling

The engine checks built-in model availability, validates request limits and reserves response capacity. It returns complete typed results or explicit errors: `invalid_request`, `model_unavailable`, `context_limit`, `refused`, `timeout`, `busy`, `cancelled` and `generation_failed`. Distinguish unsupported OS/hardware, disabled Apple Intelligence and assets not ready within availability diagnostics when the framework exposes the reason.

Do not silently retry, switch models, truncate, summarise or split workflow input. Each app/workflow determines its own fallback; the Mail baseline is one example, not a requirement on other callers. No fallback may quietly send data to a cloud model.

Use one active model call per app-scoped engine initially with explicit admission control. An actor can be re-entered across `await`, so an actor alone does not enforce single admission. Honour cancellation and deadlines; discard late outputs and do not admit a replacement over still-running model work merely because the caller timed out. Release admission when work has terminated, and discard failed sessions. Reuse immutable schemas only where their complete identity matches.

Apple currently documents a 4,096-token context window for the built-in model. Instructions, prompts, schemas and output share that budget. Query the supported context size and use token counting where available in the chosen SDK; reserve completion space. Define configurable limits for questions, candidates, evidence entries and body bytes. Excerpt selection belongs to the workflow. These are application policies, not claimed framework maxima.

Inference and preprocessing must not block an app's main thread. Pass cancellation through from its UI or background task and preserve request identity through completion. No background work should outlive its intended lifecycle without an explicit app policy.

### Mail fallback and UI deadlines

Keep baseline suggestions available regardless of model state. Set a bounded UI deadline; on expiry use the unchanged baseline and discard late results for that display generation. The user must remain able to choose a baseline suggestion without waiting for inference.

The Mail adapter uses the unchanged baseline on every model error, stale result or completed but unscorable shortlist. Preserve a machine-readable fallback reason separately from user-visible suggestions. Other apps can instead display an unavailable state, ask for input or leave an operation unchanged.

## Privacy and reproducibility

Use trusted classifier instructions and pass application content as untrusted data. Mail messages, documents and other inputs can contain text that attempts to redirect the model. Prompt separation helps, but application validation and lack of tool authority enforce the operational boundary. Model decisions never themselves authorise filesystem, Mail or other side effects.

Keep inference and evidence local and app-owned. Do not log input content by default; for Mail this includes bodies, subjects and addresses. Make content-bearing replay capture explicit and local, with a documented retention/deletion policy. Ordinary telemetry should record timings, status, versions and aggregate outcomes without raw content. The package must not add analytics transmission.

Use greedy decoding for the initial configuration. Record macOS build, available model metadata, prompt/schema version, evidence-selection version and ranking policy. Apple controls built-in model updates; regression-test after OS changes. Stable output structure does not guarantee classification accuracy or identical decisions across model versions.

## Evaluation and acceptance

Demonstrate reuse with the Mail adapter and an independently built consumer example, such as a document-classification CLI using labels and urgency scores. Both must import the same package through its public API without access to Shelf internals, copied engine code or special-case branches. This validates cross-app reuse without building a second full application. Include two unrelated workflows in the consumer fixtures to check workflow isolation as well.

Offline tests use an injected fake model. Cover boolean/choice/rubric contracts, ordering, invalid IDs, rubric lookup, duplicate candidates, evidence-reference validation, unscorable status, single admission, cancellation, timeouts and complete baseline fallback. Verify stale results cannot affect a new selection, and selected actions remain bound to the intended message and folder.

On the target Mac, collect shadow results before enabling reranking. Measure top-one and top-five destination accuracy, destination recall in the candidate shortlist, promotions and demotions relative to baseline, and especially cases where the model displaces a previously correct suggestion. Report refusals, incomplete assessments, context failures and timeouts separately while keeping them in end-to-end totals. Also measure first/warm latency, UI responsiveness and repeated-request memory behaviour.

Historical replay requires the actual pre-move shortlist, evidence snapshot and baseline order captured at decision time, or an equivalent verified historical snapshot. Exclude that move from learning data and all later messages, moves and counts from the evidence. Do not rebuild replay inputs from today's Mail, Spotlight, header cache or learning store: future information can leak through retrieval, representative examples and promotions even if the selected message itself is excluded. Where reliable historical snapshots are unavailable, use prospective shadow collection only. User moves provide useful observed choices; they do not establish that every alternative folder is objectively wrong.

Test same-sender/different-topic messages, overlapping folder names, cross-account duplicates, sparse evidence, contradictory move history, move-memory-only suggestions, long messages and hostile instructions embedded in mail. Permute candidate order to measure sensitivity while restoring output to the input identity mapping.

Freeze prompts and rubric before the evaluation set. Agree on a UI latency budget and regression tolerance before promotion from shadow mode. No accuracy, throughput or latency improvement has been measured for this design yet.

## Deliverables

Deliver a standalone, versioned Swift Package Manager library with public request/result types, the three typed primitives, explicit independent/comparative modes, ordered results, strict validators and an injectable fake-model interface. Document deployment requirements, cancellation, resource ownership, error semantics and package compatibility. Include a thin JSONL fixture/replay tool and an independently built consumer example to prove cross-app reuse.

Deliver the first in-process adapter for Mail with bounded evidence snapshots, `mail-folder-fit-v1`, off/shadow/rerank controls and unchanged baseline fallback. Include offline tests, opt-in Mac tests and a report comparing shadow rankings with existing behaviour. The first integration must not replace retrieval/LSM, alter move-memory learning rules or add automatic moves.

A new app should add the package dependency, create its app-scoped engine, define its workflows and supply authorised input snapshots. It should not need its own model session implementation, JSON-repair code or copied availability checks. Each app still owns its availability UI, data access, result policy and actions.

## Apple references

* [SystemLanguageModel and availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
* [Guided generation, declaration order and runtime schemas](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
* [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
* [Context management](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
* [Model-version changes](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions)

Prepared 27 September 2026 from the supplied app description and Apple API research. Verify source integration and SDK compilation on the target Mac before implementation claims.

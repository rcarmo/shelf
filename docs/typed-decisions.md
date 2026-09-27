# Typed decisions in Shelf

The [source brief](typed-decisions-brief.md) is preserved as the design reference. Its first
implementation is the local [TypedDecisions package](../Packages/TypedDecisions/README.md),
version 0.1.0 / contract 1 / prompt 1. It can move into a separate repository without
extracting Shelf files: Shelf links its public products via a path dependency today.
`Examples/DecisionConsumer` is an independently built consumer with document-classification
and task-actionability workflows. Future Shelf action assessments can share the same
app-scoped engine and define their own rubrics and evidence policies.

## Mail integration

Existing Spotlight, Mail scripting, header-cache retrieval, LSM scoring and move learning
remain the baseline. Folder sorting retains the old weighted formula, strong-hit
precedence and visible-related-message promotion. The original early-cut top five is
computed intact, including its metadata, and the remaining baseline candidates extend it
for the adapter's full shortlist. Regression fixtures compare the complete old top-five
records with the first five records of the retained shortlist.

`MailDecisionAdapter` selects the first six baseline candidates and records the remaining
count. It retains their baseline scores locally but omits those scores from model input.
Policy `mail-evidence-v1` uses sender <=160 UTF-8 bytes, subject <=200, selected-message body
excerpt <=600, at most two evidence records per folder, evidence subjects <=120 and
excerpts <=160. Every body is marked as a partial excerpt with omitted-byte counts; omitted
record and candidate counts are retained. The encoded request must fit 12,000 bytes or
returns `evidence_budget_exceeded`, without iterative trimming. Framework token preflight
can independently return `context_limit`.

Duplicate message evidence uses a sender/subject/date-minute/folder fingerprint across
retrieval sources, preferring the longest available excerpt with source-path ties. This is
a heuristic where the source has no common message ID. Representatives then use newest
date with source-identity ties, preserving one successful move and one message when both
exist. Sender/thread facts come from code. Snapshot provenance maps opaque evidence IDs
back to source records in app memory; no model tools or additional fetches are involved.

The baseline historically groups by display path, including across accounts. The adapter
rejects detected conflicting account evidence instead of treating it as one trustworthy
destination. Removing that historical baseline limitation is a separate migration;
user-confirmed move actions now resolve an unambiguous account-ID plus nested path and
capture all selected message IDs/accounts. At click time both selection and destination
are verified again, so a stale button cannot move a newly selected message or silently
pick the first folder with the same name. Successful moves alone feed the existing store.

## Rollout and evaluation

Settings > Folder assessments defaults to **Off**. **Shadow** assesses the shortlist with
`mail-folder-fit-v1` and records validated results without changing actions. **Rerank** is
present but disabled by the code-level `rankingApproved` gate until prospective evaluation.
Setting a preference to `rerank` cannot bypass that gate. Baseline actions are always ready
while generation runs; an eight-second UI deadline cancels and falls back. New selection
or refresh generations cancel and invalidate previous assessments. Pointer entry, keyboard
interaction and chosen actions lock any future live reorder for that display generation.

Shadow records compare two stable policies: `full-v1` sorts ordinal suitability descending,
with baseline-order ties; `protected-groups-v1` does that only within baseline visible-hit,
strong-hit and ordinary groups, preserving their original slots. If any assessment is
insufficient or invalid, no proposed order is constructed. Scores are never added to LSM
or the weighted baseline. The proposed orders and raw assessments remain distinct from
displayed actions. The existing optional prose summary is suspended while shadow mode is
active; it is not input to this adapter.

The last 100 assessment records are held only in application memory. Export Assessments
explicitly writes a chosen local JSON file containing opaque IDs, levels, timings, OS and
contract metadata, policy versions, counts and proposed orders; it contains no messages,
addresses, folder paths or source identities. Closing Shelf deletes the in-memory records.
The user owns exported-file retention and deletion. Content-bearing historical replay
capture is not enabled in Shelf in this release; the package JSONL tool can replay explicitly
provided, authorized snapshots. Never reconstruct historical evidence from today's Mail
or include the evaluated move in its own learning data.

Before unlocking live reranking, collect prospective authorized shadow snapshots and
observed user choices, freeze prompts/rubric/policy, and agree a latency budget and regression
tolerance. Measure shortlist recall, top-one/top-five accuracy, harmful displacement of a
correct baseline, policy promotions/demotions, refusal/context/timeout/invalid-result rates,
cold/warm latency, responsiveness and repeated-request memory use. Evaluate same sender
with different topics, conflicting move memory, sparse evidence, memory-only suggestions,
duplicate account paths, long/hostile inputs and candidate-order permutations. Observed
choices are useful labels, not proof that every alternative is wrong.

See [verification report](typed-decisions-verification.md) for measured checks and remaining
evaluation work; no Mail accuracy or performance gain is claimed by this foundation.

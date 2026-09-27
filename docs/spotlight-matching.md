# Spotlight matching

The September 2026 retrieval update improves recall without changing the LSM or
learned-move scoring formula:

- Subject queries accept any two of the first eight distinct meaningful subject terms,
  rather than requiring every term. Single-term subjects still work. Subject searches
  stay limited to subject/title/display-name metadata; body queries run separately.
- Semantic queries retain three-character terms such as API. Sender queries can use a
  display name when no address exists. Empty queries no longer scan all indexed mail.
- Queries stream gathering progress and wait for completion, with timeouts of four
  seconds for topic/subject searches and 2.5 seconds for sender searches. The old
  first-result timers could end collection before later matches arrived.
- Progress snapshots are throttled to 300 ms, parsed files are cached for the query's
  lifetime, and superseded streams stop their metadata queries.
- Strong related messages remain first, but relevant weaker topic matches fill unused
  slots instead of disappearing whenever a strong match exists. Shared domains alone
  are not enough to qualify a weaker match. The ten-result cap and Junk/Trash exclusions
  remain in place.
- Duplicate hits are resolved after relevance scoring, so a header-only hit cannot
  suppress a better copy with body evidence.

Seven regression tests in `SpotlightMailMatchingTests` cover managed-mail paths, partial and single-term
subjects, empty queries, short acronyms, mixed-strength results, duplicate quality,
result limits and exclusions. They use synthetic metadata and messages; actual recall
on the user's selected messages has not been measured. No reindexing or Mail data
changes are performed. Missing index entries and Full Disk Access restrictions can
still prevent retrieval. Additional visible messages may legitimately change existing
folder promotions; this change is separate from the disabled model reranking feature.

## Subject-first similarity

A subsequent weighting update adds shared subject evidence to Spotlight preselection,
header-cache preselection, related-message scoring and filing similarity. Exact normalized
subjects receive a 300-point related-message bonus (previous thread-only bonus: 90),
while sender equality contributes 45 (previously 95). Substantial overlap receives 120
points, requiring at least two shared terms, Jaccard similarity >=0.35 and coverage of
at least half the smaller subject. Term overlap adds up to 108 points plus 80 times
Jaccard similarity. A lone shared word gets no substantial-overlap bonus.

Spotlight's thread bonus is now 640 versus 140 for sender equality, plus subject overlap;
filing similarity uses 3.0 for an exact subject, 1.5 for substantial overlap, 1.2 times
Jaccard similarity, and 0.6 for sender equality. Existing LSM and move-memory learning
remain unchanged; filing evidence and location promotion are described below.

Thread inference remains subject-based, not RFC Message-ID/In-Reply-To linkage. Reply
prefixes and counters are normalized; bracketed identifiers and short numbers are retained
to avoid treating different tickets/projects as an exact thread. Six additional tests
verify cross-sender threads and substantial subject matches outrank same-sender boilerplate,
while exact subjects remain ahead of partial subjects, generic correspondence words do not
qualify a match, and the native fallback considers generic folder names in the current account.

## Retrieval coverage and cost

- Spotlight scopes to the current user's `~/Library/Mail` and validates mailbox paths
  before accepting a hit. Saved `.eml`/`.emlx` files elsewhere are excluded.
- Spotlight snapshots metadata items on the main queue; file parsing, scoring and
  sorting use a serial worker. Scores are computed once per candidate before sorting.
- Native Mail fallback builds an account-scoped destination pool, including local Mail
  mailboxes. It samples at most 24 folders per eight-second pass, reading one 256-header
  page from each instead of skipping folders with more than 5,000 messages. Pages
  alternate between the beginning and end of Mail's ordering and advance on later passes.
  The cache holds at most 64 folders and 1,024 headers per folder; page cursors survive
  header eviction. Completed passes refresh after 60 seconds, partial passes after at
  least two seconds. Each Apple Event has a two-second timeout; the pass deadline remains
  cooperative, not a hard interruption of a script/event in flight.
- Generic correspondence labels such as `Follow up` and `Update` do not contribute
  subject evidence. The native source bonus cannot qualify an otherwise unrelated hit.
- Header warmup resumes its enumerator instead of restarting the same prefix of the
  library. Each pass is limited to eight seconds/8,192 entries and yields every 128 entries;
  cache trimming is batched. Later requests can resume an unfinished pass after 30 seconds,
  while completed scans retain the 15-minute refresh interval.
- Cached results no longer suppress the Full Disk Access warning. Native fallback is
  bounded, not a substitute for a complete Spotlight index or readable local Mail storage.

The live failing example had no matching sender or subject in the persisted header cache;
the UI was instead displaying unrelated generic follow-up subjects. This demonstrates a
candidate-coverage failure, not just a misplaced final score. Private message content is
not included in regression fixtures or diagnostics documentation.

## Filing follows matching locations

The final filing update promotes eligible locations in related-message relevance order,
even when a folder has only one visible match, before taking the five-item display limit.
It no longer manufactures destinations after an early cut or puts folders first merely
because they have several visible weak hits. Folder score, account, sample path and hit
metadata are retained. The shadow policy protects single visible matching locations too
(`protected-groups-v2`); model reranking remains disabled.

Every visible related message from managed Mail storage contributes its eligible folder
to the destination shortlist, even when it does not meet the stronger sender/subject
threshold. Additional non-visible examples still require an exact/strong subject match
or the same sender. Inbox (case-insensitive, even in another account), Drafts, Outbox,
Sent, excluded folders and the current mailbox are not
move destinations. Tests verify that visible weaker cross-sender matches cannot lose
their destinations, while exact-thread folders remain ahead of weak generic matches.

Cached messages enter the same candidate stream as all other sources. Each update
publishes messages and destinations atomically; there is no messages-only fast path and
no retention of old messages alongside a newer empty destination list. All eligible
visible folders enter the full shortlist, even when only five destinations fit on screen.

Foreground header scans prefer the selected message's account UUID under the current
Mail storage version, falling back when unavailable. A handful of unrelated cached
sender hits no longer suppresses that foreground scan.

## Weighted destination sampling

`MailDestinationCandidate` is the explicit pool entry: account/path, cached unique sender,
exact-thread and strong-subject hit counts, folder-topic overlap, and account affinity.
Its sampling weight is:

```
1 + 2 * sameAccount + 3 * topicMatch
  + 6 * log2(1 + senderHits)
  + 18 * log2(1 + threadHits)
  + 10 * log2(1 + strongSubjectHits)
```

Unfileable/current folders have weight 0.25 so their messages remain available for related
message search. We sample without replacement using `-log(U) / weight` ascending. Every
fourth slot, starting with the first, instead explores the oldest due folder, including
never-read folders. This prevents the first 24 folders and already-known destinations
from permanently excluding others. Weights use observed cached headers, not total folder
size, and are discovery priorities, not confidence probabilities. Final suggestion ranking
is evidence-based, not random; sampling does not itself authorize or create a move action.

Spotlight sender snapshots inspect up to 2,000 metadata items (1,600 at the normal result
limit), instead of 160. Native, Spotlight, and local-header sources preserve their best
half of message matches, then admit up to eight examples per eligible destination in
relevance order before filling remaining slots. Inbox volume can no longer consume the
entire candidate budget when actual filed matches are available. Metadata-only folders
do not count toward the foreground scan's four-message stopping condition.

Final folder evidence is deduplicated across native/Spotlight sources and kept separate
by account. Exact-thread evidence precedes bulk sender history; the UI names thread or
sender filing evidence explicitly. The five visible suggestions remain the best eligible
destinations rather than an arbitrary padded list. Tests cover weighted inclusion bias,
exploration, large-folder paging/cache bounds, account isolation, duplicate evidence, and
an Inbox flood that previously hid filed sender examples.

Before any message or destination grouping, account aliases from all sources are mapped
to Mail's stable account IDs, not just the selected message's account. This merges a
Spotlight UUID and native Mail account name for the same mailbox without merging identically
named folders in different accounts or parents. A separate actor batches an account-only
directory read (maximum 32 accounts), caches it for 60 seconds, and backs off for 10 seconds
on failures. Unknown or ambiguous account names are not guessed. Local `Mailboxes` storage
and native local mailbox hints share the `local` identity. UI labels use readable account
names separately from identity keys; destination binding still revalidates before moving.
Move action details put the qualified destination path first, wrap instead of forcing one
line, and expose the complete description in a tooltip. Actual subfolders of Inbox remain
eligible; only Inbox itself is excluded as a destination.

The final publishing step resolves shortlisted locations against Mail and groups by the
returned `MailDestinationIdentity` (actual account ID plus full mailbox path). In particular,
older learned moves with a missing account are resolved only when Mail has exactly one
matching destination; they then merge with message-backed evidence for that mailbox.
Unresolved or ambiguous candidates are not exposed as move actions. The five-item limit
is applied after this merge, and duplicate source records do not inflate counts. Discovery
and action execution share the destination cache (60-second positive / 10-second negative
TTL); each publishing pass considers at most 40 locations, starts at most 16 uncached
resolutions, and uses a cooperative two-second budget. All Mail reads remain off the UI
actor, and an actual move still revalidates selection and destination.

When filed-message evidence is sparse, existing catalog folders whose leaf name matches
a meaningful subject term can fill spare suggestion slots. Simple singular/plural matches
are accepted; generic folder names and parent-only matches are not. These fallbacks stay
below message-backed and learned destinations and display "Folder name matches message
topic" with zero message hits. They no longer depend on an LSM threshold trained on the
same short folder names, and one message-backed folder does not hide all fallback options.

Mail actions no longer depend solely on finding a contact or filing destination. For a
single bound message, Reply, Reply All and Forward open drafts after validating the current
message ID and account. No action sends automatically. Sender/details copying and bounded
HTTP(S) preview-link actions also work without Contacts or Full Disk Access. Synthetic tests
cover absent/ambiguous selection, script compilation, link bounds and body exclusion from
copied details; tests do not create drafts or move real messages.

## Signing and permissions

The observed storage warning cleared after restoring the existing Apple Development
signature. The test build had been ad-hoc signed: its designated requirement contained
only a changing binary hash, rather than the stable developer identity associated with
the user's existing grant. No new Full Disk Access grant was needed for the development
signed build. Local builds now default to ad-hoc signing at the user's request; an explicit
`SHELF_CODESIGN_IDENTITY` opts into certificate signing. Permission warnings include a
direct System Settings action; macOS still owns the grant itself. Rebuilding with an ad-hoc
identity may require renewing the Full Disk Access grant.

### Revoked certificate diagnosis

The development-signed build passed strict signature verification but macOS rejected
launch with a malware warning. Subsequent `syspolicy_check` and `spctl` diagnostics confirmed
the signing certificate was revoked (`CSSMERR_TP_CERT_REVOKED`). Signature integrity alone
was insufficient. An ad-hoc local build was subsequently launched and inspected, without
changing security settings or quarantine attributes. Live Mail inspection showed matching
messages and filing actions, but the protected Mail storage access warning had returned.

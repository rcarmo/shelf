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
- Native Mail fallback no longer excludes folders whose names lack subject terms.
  It prioritizes the current account and mailbox, then folder-name evidence, and examines
  at most 24 folders with at most 5,000 messages each in an eight-second pass. Its catalog
  and up to 24 header batches are cached for 60 seconds. Each Apple Event has a two-second
  timeout; a pass deadline is cooperative, not a hard interruption of an event in flight.
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

Filing examples require an exact/strong subject match or the same sender. Generic body,
footer or one-word cross-sender matches may appear as weak related messages but do not
constitute filing evidence. Drafts, Outbox, Sent and the current mailbox are not move
destinations. Tests verify that one real match in a folder beats 80 unrelated generic
hits, and that a single matching location outside the original top five is promoted.

Foreground header scans prefer the selected message's account UUID under the current
Mail storage version, falling back when unavailable. A handful of unrelated cached
sender hits no longer suppresses that foreground scan.

## Signing and permissions

The observed storage warning cleared after restoring the existing Apple Development
signature. The test build had been ad-hoc signed: its designated requirement contained
only a changing binary hash, rather than the stable developer identity associated with
the user's existing grant. No new Full Disk Access grant was needed for the development
signed build. The build script now fails visibly on signing errors/no available identity;
ad-hoc signing requires explicit `SHELF_CODESIGN_IDENTITY=-`. Permission warnings include
a direct System Settings action; macOS still owns the grant itself.

### Latest launch is blocked

The subsequent final build passed strict signature verification, but macOS rejected
its launch with a malware warning and the bundle is now absent from `dist`. The cause
is unconfirmed: the system security log store was inaccessible to this session.
Signature integrity is not a malware/trust assessment. Do not treat the earlier
development-signed launch as verification of this final artifact. No security settings
or quarantine attributes were changed to bypass the warning. Final source tests passed
(29 tests, one opt-in model test skipped), but live verification of the final filing
rules remains incomplete pending a trusted, launchable build.

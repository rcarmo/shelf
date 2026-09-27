# Shelf performance profile

Measured on September 27, 2026 with macOS 27.0 (26A428), arm64, using `sample` at
one-millisecond intervals across all process threads. These are wall-clock stack
samples, not CPU percentages or an exhaustive workload benchmark. No messages were
moved or modified. Raw samples remain in `/tmp`, outside the repository.

## Confirmed stall and verification

| Scenario | Main-thread samples | Observation |
| --- | ---: | --- |
| Original beachball, five-second capture | 1,727 | Every sample in action construction/destination resolution; synchronous Mail Apple Events and sibling mailbox walking |
| Original Safari context, ten-second capture | 7,587 | 7,297 normal event-wait samples (96.2%); 277 in browser AppleScript extraction |
| First rebuilt app, Mail activation, twenty-second capture | 15,045 | 14,406 normal event-wait samples (95.8%); no main-thread destination walk; 168 in synchronous Mail context extraction |
| Subsequent rebuilt app, ten-second settled capture | 6,792 | 6,635 normal event-wait samples (97.7%); no sampled destination walk; low context-poll activity |

The confirmed blocking chain was `ContextMonitor.refreshMessageLocations` ->
`AutomationRunner.actions` -> `moveSelectedMailAction` -> `resolvedDestination` ->
`findMailbox` -> `AESendMessage`. Streaming results repeatedly rebuilt actions and
repeated this traversal on the UI actor.

Destination resolution now runs in `MailActionService`, uses direct named path lookups,
reuses one binding task per destination/selection and caches at most 128 identities.
Positive cache TTL is 60 seconds; negative TTL is ten seconds. A move freshly resolves
its destination and checks the captured selection before execution; no script objects
are stored in this identity cache. Tests cover expiration, capacity, account separation,
and nonblocking repeated action construction.

Physical footprint was 79.3 MB during the original stall and 59.8 MB in the rebuilt Mail
capture; respective peaks were 161.9 MB and 162.6 MB. Different capture conditions mean
this is not evidence of a memory reduction. Background work and normal UI layout were
present, but the sample did not demonstrate a new comparable UI stall.

## Additional changes

Spotlight parsing/ranking moved off the main queue, progress work is coalesced, and
scores are computed once before sorting. Header walking now has resumable, yielding,
bounded passes and batched trimming, rather than a synchronous 120-second actor pass
with full-cache grouping after every message. Native Mail retrieval caches its bounded
mailbox/header reads. See `spotlight-matching.md` for limits and coverage caveats.

## Remaining opportunities

1. **Main-actor context polling:** Mail ScriptingBridge, browser AppleScript and Contacts
   resolution still execute synchronously during polling. Mail extraction and browser
   polling were observed in samples, but not as sustained hangs in those captures.
   Move extraction to isolated workers with generation checks and cancellation, and
   cache unchanged selection snapshots. Do not let an old response replace a newer app.
2. **Native Mail fallback coverage:** folder/message/time limits deliberately leave large
   accounts incomplete. Cache invalidation and resumable account traversal should be
   driven by selection/account changes; never remove limits to compensate for a missing
   index. Current catalog and header caches refresh after 60 seconds.
3. **Streaming LSM rebuilds:** each candidate chunk can retrain the folder classifier.
   Coalesce snapshots and retain a classifier for an unchanged training-set signature.
   This is a source-review opportunity, not the confirmed beachball cause.
4. **Contacts lookup:** cache normalized identity lookups and use thumbnail data where
   sufficient; invalidate on contact-store changes. Full contact enumeration/image reads
   remain a potential latency and memory cost, not a measured dominant hotspot here.
5. **Canceled metadata work:** query cancellation stops future results, but an already
   running bounded parse still finishes. Add cooperative per-item cancellation and a
   shared concurrency limit if rapid-selection stress tests show worker accumulation.

The captures cover the whole process during specific Mail/Safari scenarios, not every
application extractor, permission state, huge mailbox, inference run or long-duration
soak. Regression tests use synthetic data. Further benchmarking should measure UI
latency and retrieval recall separately, including cold/warm caches and unavailable Mail.

## Final verification limitation

The later filing-location changes passed source tests, but their final app launch was
blocked by macOS with a malware warning. The bundle is no longer present in `dist`.
The cause could not be established because security-log access was denied. The samples
above precede that final build and must not be presented as runtime verification of it.

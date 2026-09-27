# Local Slack context

Shelf has a dedicated extractor for `com.tinyspeck.slackmacgap`. It uses macOS
Accessibility, not AppleScript, a Slack API token, a browser debugging port, private
databases or session credentials. It does not require Full Disk Access. Accessibility
access is requested only through the explicit button in the Slack context pane.

## Coverage

| Surface | Captured hints | Limits |
| --- | --- | --- |
| Channel | Workspace/channel names and IDs, document URL, explicitly labeled topic, observed messages | Title/header labels vary with Slack version and language |
| DM/group DM | Conversation ID, title-derived participant display names, observed messages | Names are not verified Slack user IDs or Contacts identities |
| Thread | Thread region, observed replies, `thread_ts` when present in the document URL | Does not guess thread identity from the last message |
| Search | Search view, exposed search-field query, result message/channel identities | No background search or full-history retrieval |
| Messages | Timestamp strings, permalinks, text excerpts, preceding author labels, explicit focus/selection | Missing repeated author labels stay unknown; multiple targets are ambiguous |
| Links/files | HTTP(S) links, Slack file IDs, names and URLs | No downloads or file-body inspection; attachment query tokens are discarded |
| Activity, Files, Later, Canvas, Huddles | Recognized view/title and exposed links/files | Not a dedicated activity/canvas document/audio parser |
| Drafts | View identity only | Draft/composer content is excluded |

Message identity comes from timestamp permalink anchors, not arbitrary links quoted
inside messages. Conversation identity comes from the focused document URL, never
from a sidebar item. Slack host boundaries and timestamp/ID formats are validated.
Only an explicitly focused message descendant or selected message container produces
`targetMessageID`; a focused conversation, newest message, reaction state or open
thread is not treated as message selection. Unknown fields remain optional.

## Integration and actions

`AppHint.slackContext` keeps observed facts separate from generic URL/contact hints.
The snapshot has a deterministic content signature so unchanged polls do not rebuild
the UI. Slack hints do not run Contacts matching, Mail filing, or model inference.
Messages are untrusted evidence, never executable instructions.

The context pane shows observed messages with expandable text, attachment links,
thread markers, references, target state and partial/accessibility diagnostics.
Actions open the captured conversation/message/reference or copy context/message
links. No posting, reacting, deleting, automatic clipboard inspection or composer
editing is implemented. Copy Context includes names and links, not message bodies.
Open/copy actions bind to the captured identity rather than rereading a changing UI.

## Cost and privacy

- Slack reads run on a separate actor, never synchronously on the UI actor.
- ContextMonitor admits at most one read, including a canceled read still finishing.
- App changes invalidate the generation; old results cannot overwrite the new app.
- The existing two-second foreground poll requests updates; a 1.5-second single-entry
  in-memory cache coalesces nearby requests. No Slack snapshots are persisted or logged.
- A read has a cooperative 800 ms traversal deadline, 500 visited-node limit, depth
  24, at most 80 children per node, and a 40,000-character snapshot budget.
- AX messaging uses an 80 ms timeout. A call already in progress may exceed the
  traversal deadline; this is not a hard real-time guarantee.
- Lists/scroll areas prefer `AXVisibleChildren` where supported. Otherwise the bounded
  loaded accessibility subtree is used, which may include offscreen rendered content.
- Output is capped at 30 messages, 4,000 characters per message, and 20 links/files.
- Editable text areas, ordinary text fields, password fields, composer subtrees and
  sidebars are excluded before reading their values/children. Only search fields can
  contribute editable query text. Draft windows are not traversed.

## Verification and limits

The earlier live inspection of Slack 4.52.162 exposed the channel document URL,
timestamp permalink anchors, author buttons, message text, attachments and links.
Synthetic regression fixtures model that structure and cover channels, DMs, threads,
search, ambiguity, duplicate messages, hostile text/URLs, privacy, caps and cancellation.
No private workspace messages are included in fixtures.

The native reader and SwiftUI view compile, but end-to-end extraction/rendering in the
Shelf app remains unverified because macOS blocked the preceding Shelf build. No
launch/security bypass is attempted. Slack UI changes/localization, unexposed AX
content, long messages, unavailable focus and virtualized history can reduce coverage;
the UI reports partial/unavailable context rather than fabricating a message target.

API enrichment (verified user identities, complete thread history, channel metadata)
and an explicit Slack message shortcut remain separate future integrations requiring
appropriate Slack authorization. There is no token discovery or implicit API access.

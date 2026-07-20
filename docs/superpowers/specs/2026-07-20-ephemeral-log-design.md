# Ephemeral Connection Log — Design

**Date:** 2026-07-20
**Status:** Approved, ready for planning

## Goal

Give the iOS/macOS app a **live connection log** — like WireGuard's log view — but
**ephemeral by design**: kept only in memory for the current session, never written
to disk, and cleared when the tunnel stops or the app is dismissed. It answers "why
won't it connect / which transport handshaked / did it fall back?" without leaving a
persistent trail.

## Privacy stance

- **In-memory only.** No file, no `UserDefaults`, no `os_log` persistence. The
  buffer lives in the packet-tunnel extension's process and dies with it.
- **Bounded.** A fixed-size ring buffer (default 1000 lines) — old lines are evicted,
  so memory is capped and the window is naturally short.
- **Off switch.** A user setting `loggingEnabled` (default on). When off, the
  extension appends nothing — not even in memory.
- **Explicit export only.** Copy/Share is user-initiated; the app never sends logs
  anywhere on its own.

This is consistent with the project's privacy-by-design stance (see
`stealthwg-architecture`): logs are a debugging convenience, not a record.

## Architecture

```
wireguard-go / StealthWG events
        │  (adapter log closure + a log() helper in the provider)
        ▼
  LogRingBuffer  (in the extension, pure logic, capacity + monotonic seq)
        │  IPC: sendProviderMessage("logs:<cursor>") → JSON {lines, cursor}
        ▼
  TunnelManager.logLines  (@Published)  ──►  LogView (shared SwiftUI)
```

Reuses the existing extension↔app IPC channel already used for live stats
(`handleAppMessage` / `sendProviderMessage`). Logs are polled on a **separate**
timer that runs only while the Log view is visible, so nothing is fetched when the
user isn't looking.

## Components

### `Shared/LogEntry.swift` (new)
Model shared by app + extension:
```swift
struct LogEntry: Equatable, Identifiable {
    let seq: Int          // monotonic, assigned by the buffer
    let date: Date
    let message: String
    var id: Int { seq }
}
```

### `Shared/LogRingBuffer.swift` (new, pure — unit-tested)
A fixed-capacity ring buffer with a monotonically increasing sequence number.
```swift
final class LogRingBuffer {
    init(capacity: Int = 1000)
    func append(_ message: String, at date: Date)   // assigns next seq, evicts oldest
    func entries(since seq: Int) -> [LogEntry]       // entries with .seq > seq (for the cursor)
    func latestCursor() -> Int                        // max seq seen (0 if empty)
    func clear()
    var count: Int { get }
}
```
Thread-safety via an internal lock (the adapter's log closure and `handleAppMessage`
run on different queues). The seq/capacity/`since` logic is pure and Date-independent,
so it is covered by `scripts/test-parser.sh`.

### Extension — `Tunnel/PacketTunnelProvider.swift`
- Owns a `LogRingBuffer` (created in `startTunnel`).
- Reads `loggingEnabled` (Bool) from `providerConfiguration` (default true). When
  false, the buffer is never fed.
- A private `log(_ message: String)` helper replaces the current bare `NSLog` calls
  (transport selection, fallback events, errors): it `NSLog`s **and** appends to the
  buffer (when logging is enabled). The `WireGuardAdapter` log closure routes its
  messages through the same helper, so wireguard-go's own lines are captured too.
- `handleAppMessage` gains log commands alongside the existing `"stats"`:
  - `"logs:<since>"` → JSON `{ "lines": [ {"seq":N,"ts":<epochSeconds>,"msg":"…"} ], "cursor": <maxSeq> }`, only entries with `seq > since`.
  - `"logs:clear"` → `buffer.clear()`, returns `{}`.
  The existing `"stats"` path is unchanged.

### App — `App/TunnelManager.swift`
- `@Published private(set) var logLines: [LogEntry] = []` and a `logCursor` (Int).
- `loggingEnabled: Bool` persisted in `UserDefaults` (default true); written into
  `providerConfiguration` on save (like `transport`/`sni`).
- `startLogPolling(id:)` / `stopLogPolling()` — a dedicated `Timer` (1.5 s) that
  sends `"logs:<logCursor>"`, appends returned lines to `logLines` (capped to the
  last 1000 in the app too), advances `logCursor`.
- `clearLogs(id:)` — sends `"logs:clear"`, empties `logLines`, resets cursor.

### App — `Shared/LogView.swift` (new, shared SwiftUI)
- A scrolling, monospace list of `logLines` (chronological, newest pinned to bottom /
  auto-scroll), each row `HH:mm:ss  message`.
- Toolbar: **Copy** (joins lines to clipboard via `Clipboard.copy`), **Clear**.
- Empty/off states: "No log entries yet." / "Logging is off — enable it in Settings."
- `.onAppear` starts log polling, `.onDisappear` stops it.

### Entry points
- **iOS:** a "Log" row/button in `ProfileDetailView` (VPN options area) and/or a
  toolbar item on `ConnectionView`, pushing `LogView` via `NavigationLink`.
- **macOS:** a "Log" item in the management window / menu opening `LogView`.
- **Settings:** a `loggingEnabled` toggle (a small Settings/Advanced section shared
  by both platforms, or reuse an existing settings surface).

## Data flow

1. Tunnel starts → provider creates `LogRingBuffer`, reads `loggingEnabled`.
2. wireguard-go/StealthWG emit lines → `log()` → buffer (if enabled).
3. User opens Log view → app polls `"logs:<cursor>"` every 1.5 s → new lines appended.
4. User taps Copy/Clear as needed. Tunnel stop / app exit → buffer gone.

## Error handling

- IPC send throws / nil response → ignored, retried next tick (same as stats).
- Logging off → buffer empty → view shows the off state; poll still returns `{}`.
- Buffer overflow → oldest lines silently evicted (by design); cursor keeps advancing
  so the app never re-requests evicted lines.

## Testing

- **Unit (pure):** `LogRingBuffer` — append assigns increasing seq; capacity evicts
  oldest; `entries(since:)` returns only newer; `clear` resets; `latestCursor`
  tracks max. Added to `scripts/test-parser.sh` (compiled with the other Shared
  sources).
- **Builds:** unsigned iOS + macOS device builds green (`LogView`, IPC changes,
  provider changes link and compile).

## Out of scope (YAGNI)

- Persistent logs / export to Files / remote upload.
- Log-level selector, search/filter, syntax highlighting.
- Per-line severity styling beyond plain text (can be added later if needed).
- Capturing logs while the Log view is closed for later viewing — we intentionally
  only poll while visible; the buffer still fills in the extension regardless, so
  opening the view shows recent history up to capacity.

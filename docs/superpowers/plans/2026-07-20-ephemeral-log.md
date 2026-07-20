# Ephemeral Connection Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-memory, session-only connection log for the iOS/macOS app — captured in the packet-tunnel extension, streamed to the app over the existing IPC channel, shown in a shared `LogView`, and gone when the tunnel stops.

**Architecture:** A pure `LogRingBuffer` (capacity + monotonic seq) in the extension is fed by wireguard-go's log closure and a StealthWG `log()` helper. The app polls new lines (`logs:<cursor>`) on a dedicated timer while the Log view is visible and renders them. Nothing touches disk.

**Tech Stack:** Swift, SwiftUI, NetworkExtension IPC (`sendProviderMessage`/`handleAppMessage`), `scripts/test-parser.sh` (assert-based pure-logic tests).

## Global Constraints

- **Ephemeral only:** in-memory ring buffer, no disk/UserDefaults/os_log persistence; dies with the extension process.
- **Bounded:** default capacity 1000 lines; oldest evicted.
- **Off switch:** `loggingEnabled` (default true) from `providerConfiguration`; when false the buffer is never fed.
- **Cross-platform:** shared code in `Shared/`; platform helpers via `App/Platform.swift` (`Clipboard`, `inlineNavTitle`, `noAutocap`).
- **English code comments.** Pure logic is covered by `scripts/test-parser.sh`; device builds (iOS + macOS) must stay green.

## File Structure

- `Shared/LogEntry.swift` — the log line model (app + extension).
- `Shared/LogRingBuffer.swift` — pure, thread-safe ring buffer (unit-tested).
- `Shared/LogView.swift` — shared SwiftUI log screen.
- `Tunnel/PacketTunnelProvider.swift` — buffer ownership, `log()` helper, IPC `logs:*` commands.
- `App/TunnelManager.swift` — log polling, `clearLogs`, `loggingEnabled`.
- `App/Views/ProfileDetailView.swift` — entry point (a "Diagnostics" row → `LogView`).
- `Tests/StealthProfileTests.swift` + `scripts/test-parser.sh` — ring-buffer unit tests.

---

### Task 1: `LogEntry` + `LogRingBuffer` (pure, tested)

**Files:**
- Create: `Shared/LogEntry.swift`, `Shared/LogRingBuffer.swift`
- Modify: `Tests/StealthProfileTests.swift`, `scripts/test-parser.sh`

**Interfaces:**
- Produces: `struct LogEntry { let seq: Int; let date: Date; let message: String }` and `final class LogRingBuffer { init(capacity:); func append(_:at:); func entries(since:) -> [LogEntry]; func latestCursor() -> Int; func clear(); var count: Int }` — consumed by the extension (Task 2) and app (Task 3).

- [ ] **Step 1: Write `Shared/LogEntry.swift`**

```swift
import Foundation

/// One line of the ephemeral connection log. `seq` is a monotonically increasing
/// id assigned by LogRingBuffer, also used as the IPC polling cursor.
struct LogEntry: Equatable, Identifiable {
    let seq: Int
    let date: Date
    let message: String
    var id: Int { seq }
}
```

- [ ] **Step 2: Write the failing tests** — append to `Tests/StealthProfileTests.swift` inside `main()` (before the final `print`):

```swift
        // LogRingBuffer: monotonic seq, capacity eviction, since-cursor, clear.
        let d0 = Date(timeIntervalSince1970: 0)
        let rb = LogRingBuffer(capacity: 3)
        check(rb.latestCursor() == 0, "empty buffer cursor is 0")
        rb.append("a", at: d0); rb.append("b", at: d0); rb.append("c", at: d0)
        check(rb.count == 3, "buffer holds 3")
        check(rb.latestCursor() == 3, "cursor tracks max seq")
        check(rb.entries(since: 0).map(\.message) == ["a", "b", "c"], "since 0 returns all")
        check(rb.entries(since: 2).map(\.message) == ["c"], "since 2 returns only newer")
        check(rb.entries(since: 3).isEmpty, "since latest returns none")
        rb.append("d", at: d0)   // evicts "a" (capacity 3)
        check(rb.count == 3, "capacity caps count")
        check(rb.entries(since: 0).map(\.message) == ["b", "c", "d"], "oldest evicted")
        check(rb.entries(since: 3).map(\.message) == ["d"], "cursor survives eviction")
        check(rb.entries(since: 0).map(\.seq) == [2, 3, 4], "seq keeps increasing after eviction")
        rb.clear()
        check(rb.count == 0, "clear empties buffer")
        check(rb.latestCursor() == 4, "clear keeps the cursor monotonic")
        rb.append("e", at: d0)
        check(rb.entries(since: 4).map(\.message) == ["e"], "append after clear continues seq")
```

- [ ] **Step 3: Wire the new sources into `scripts/test-parser.sh`** — add the two files to the `swiftc` list (order doesn't matter; before the test file):

```sh
    "$ROOT/Shared/ProfileDraft.swift" \
    "$ROOT/Shared/LogEntry.swift" \
    "$ROOT/Shared/LogRingBuffer.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash scripts/test-parser.sh`
Expected: FAIL — `Cannot find 'LogRingBuffer' in scope`.

- [ ] **Step 5: Implement `Shared/LogRingBuffer.swift`**

```swift
import Foundation

/// A fixed-capacity, thread-safe ring buffer of log lines. Each append assigns the
/// next sequence number; `entries(since:)` returns everything newer than a cursor,
/// so the app can poll incrementally. Purely in memory — never persisted.
final class LogRingBuffer {
    private let capacity: Int
    private var entriesStore: [LogEntry] = []
    private var nextSeq = 1
    private let lock = NSLock()

    init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
    }

    /// Appends a line, assigning it the next sequence number and evicting the
    /// oldest entry when over capacity.
    func append(_ message: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entriesStore.append(LogEntry(seq: nextSeq, date: date, message: message))
        nextSeq += 1
        if entriesStore.count > capacity {
            entriesStore.removeFirst(entriesStore.count - capacity)
        }
    }

    /// Entries with `seq` strictly greater than the given cursor, oldest first.
    func entries(since seq: Int) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entriesStore.filter { $0.seq > seq }
    }

    /// The highest sequence number assigned so far (0 if nothing appended). Stays
    /// monotonic across eviction and clear so cursors never re-fetch old lines.
    func latestCursor() -> Int {
        lock.lock(); defer { lock.unlock() }
        return nextSeq - 1
    }

    /// Drops all buffered lines but keeps the sequence counter monotonic.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entriesStore.removeAll()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entriesStore.count
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 7: Commit**

```bash
git add Shared/LogEntry.swift Shared/LogRingBuffer.swift Tests/StealthProfileTests.swift scripts/test-parser.sh
git commit -m "Add LogEntry + LogRingBuffer: pure in-memory ring buffer for the ephemeral log"
```

---

### Task 2: Extension — capture logs + IPC `logs:*` commands

**Files:**
- Modify: `Tunnel/PacketTunnelProvider.swift`

**Interfaces:**
- Consumes: `LogRingBuffer`, `LogEntry` (Task 1).
- Produces: IPC replies to `"logs:<since>"` (`{lines:[{seq,ts,msg}], cursor}`) and `"logs:clear"` (`{}`), consumed by `TunnelManager` (Task 3).

- [ ] **Step 1: Add the buffer, the logging flag, and a `log()` helper.** Replace the class's stored properties intro and the adapter closure so all logging routes through the buffer. In `PacketTunnelProvider`:

```swift
    private let logBuffer = LogRingBuffer(capacity: 1000)
    private var loggingEnabled = true

    private lazy var adapter = WireGuardAdapter(with: self) { [weak self] _, message in
        self?.log(message)
    }

    /// NSLogs and, when logging is enabled, appends to the ephemeral buffer.
    private func log(_ message: String) {
        NSLog("[StealthWG] %@", message)
        if loggingEnabled { logBuffer.append(message) }
    }
```

- [ ] **Step 2: Read `loggingEnabled` in `startTunnel`** — add after `sni` is read (near the other `providerConfiguration` reads):

```swift
        loggingEnabled = (providerConfiguration["loggingEnabled"] as? Bool) ?? true
```

- [ ] **Step 3: Route existing `NSLog` events through `log()`.** Replace each `NSLog("[StealthWG] …", …)` in the fallback/transport paths with a `log(String(format: …))` call so they land in the buffer, e.g.:

```swift
        log(String(format: "no handshake, trying endpoint %d (%@ via %@)", i, target.hostPort, target.transport))
```
```swift
        log(String(format: "handshake on endpoint %d (%@)", self.currentIndex, self.endpoints[self.currentIndex]))
```
```swift
        log("all endpoints exhausted; staying on last")
```
```swift
        log(String(format: "transport restart failed: %@", String(describing: error)))
```

- [ ] **Step 4: Handle the log commands in `handleAppMessage`.** Branch on the request string; keep the existing stats path as the default:

```swift
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let command = String(data: messageData, encoding: .utf8) ?? ""

        if command == "logs:clear" {
            logBuffer.clear()
            completionHandler?(try? JSONSerialization.data(withJSONObject: [String: Any]()))
            return
        }
        if command.hasPrefix("logs:") {
            let since = Int(command.dropFirst("logs:".count)) ?? 0
            let lines = logBuffer.entries(since: since).map { entry -> [String: Any] in
                ["seq": entry.seq, "ts": entry.date.timeIntervalSince1970, "msg": entry.message]
            }
            let payload: [String: Any] = ["lines": lines, "cursor": logBuffer.latestCursor()]
            completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
            return
        }

        // Default: live stats (unchanged).
        adapter.getRuntimeConfiguration { [weak self] runtime in
            let payload: [String: Any] = [
                "runtime": runtime ?? "",
                "activeEndpoint": self?.currentActiveEndpoint() as Any,
                "isFallback": (self?.currentIndex ?? 0) > 0
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
        }
    }
```

- [ ] **Step 5: Build the iOS app to verify the extension compiles**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Tunnel/PacketTunnelProvider.swift
git commit -m "Extension: capture logs into a ring buffer and serve logs:<cursor>/logs:clear over IPC"
```

---

### Task 3: `TunnelManager` — log polling, clear, loggingEnabled

**Files:**
- Modify: `App/TunnelManager.swift`

**Interfaces:**
- Consumes: `LogEntry` (Task 1), IPC `logs:*` (Task 2).
- Produces: `@Published var logLines: [LogEntry]`, `startLogPolling()`, `stopLogPolling()`, `clearLogs()`, `var loggingEnabled: Bool` — consumed by `LogView` (Task 4).

- [ ] **Step 1: Add state.** Add published log state and a dedicated timer next to the stats fields (around line 32–40):

```swift
    @Published private(set) var logLines: [LogEntry] = []
    private var logTimer: Timer?
    private var logCursor = 0

    /// Persisted app setting: when off, the extension keeps no log buffer. Read at
    /// tunnel start via providerConfiguration.
    var loggingEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "loggingEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "loggingEnabled") }
    }
```

- [ ] **Step 2: Write `loggingEnabled` into `providerConfiguration`** in `save(profile:name:into:id:)`, next to the `transport`/`sni` writes:

```swift
        pc["loggingEnabled"] = loggingEnabled
```

- [ ] **Step 3: Add polling + clear.** Add these methods (near `pollStats`):

```swift
    /// Starts polling the connected tunnel's log buffer (call when the Log view
    /// appears). No-op if nothing is connected.
    func startLogPolling() {
        stopLogPolling()
        guard connectedID != nil else { return }
        logTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollLogs()
        }
        pollLogs()
    }

    func stopLogPolling() {
        logTimer?.invalidate()
        logTimer = nil
    }

    private func pollLogs() {
        guard
            let id = connectedID,
            let session = managers[id]?.connection as? NETunnelProviderSession
        else { return }
        do {
            try session.sendProviderMessage(Data("logs:\(logCursor)".utf8)) { [weak self] response in
                guard
                    let response,
                    let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                    let raw = obj["lines"] as? [[String: Any]]
                else { return }
                let newLines = raw.compactMap { d -> LogEntry? in
                    guard let seq = d["seq"] as? Int, let msg = d["msg"] as? String else { return nil }
                    let ts = d["ts"] as? Double ?? 0
                    return LogEntry(seq: seq, date: Date(timeIntervalSince1970: ts), message: msg)
                }
                let cursor = obj["cursor"] as? Int ?? self?.logCursor ?? 0
                Task { @MainActor in self?.appendLogLines(newLines, cursor: cursor) }
            }
        } catch {
            // Transient; retry next tick.
        }
    }

    @MainActor
    private func appendLogLines(_ newLines: [LogEntry], cursor: Int) {
        guard !newLines.isEmpty else { return }
        logLines.append(contentsOf: newLines)
        if logLines.count > 1000 { logLines.removeFirst(logLines.count - 1000) }
        logCursor = max(logCursor, cursor)
    }

    /// Clears the extension buffer and the local copy.
    func clearLogs() {
        if let id = connectedID, let session = managers[id]?.connection as? NETunnelProviderSession {
            try? session.sendProviderMessage(Data("logs:clear".utf8)) { _ in }
        }
        logLines.removeAll()
        logCursor = 0
    }
```

- [ ] **Step 4: Reset the local log on disconnect.** In the disconnect/teardown path where `stats = nil` is set (around line 257), also drop log state:

```swift
            stats = nil
            stopLogPolling()
            logLines.removeAll()
            logCursor = 0
```

- [ ] **Step 5: Build the iOS app**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add App/TunnelManager.swift
git commit -m "TunnelManager: poll the extension log buffer, expose logLines/clearLogs/loggingEnabled"
```

---

### Task 4: `LogView` (shared) + entry point

**Files:**
- Create: `Shared/LogView.swift`
- Modify: `App/Views/ProfileDetailView.swift`

**Interfaces:**
- Consumes: `TunnelManager.logLines`, `startLogPolling`, `stopLogPolling`, `clearLogs`, `loggingEnabled` (Task 3); `Clipboard`, `inlineNavTitle` (`App/Platform.swift`).

- [ ] **Step 1: Write `Shared/LogView.swift`**

```swift
import SwiftUI

/// The ephemeral connection log. Polls the connected tunnel while visible and
/// renders the in-memory lines. Nothing here is persisted.
struct LogView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Group {
            if !tunnelManager.loggingEnabled {
                emptyState("Logging is off", "Enable logging below to capture connection events. Nothing is written to disk.")
            } else if tunnelManager.connectedID == nil {
                emptyState("Not connected", "Connect a tunnel to see live log events.")
            } else if tunnelManager.logLines.isEmpty {
                emptyState("No log entries yet", "Events appear here as the tunnel connects.")
            } else {
                logList
            }
        }
        .safeAreaInset(edge: .bottom) { loggingToggle }
        .navigationTitle("Log")
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Clipboard.copy(exportText) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(tunnelManager.logLines.isEmpty)
                    Button(role: .destructive) { tunnelManager.clearLogs() } label: { Label("Clear", systemImage: "trash") }
                        .disabled(tunnelManager.logLines.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { tunnelManager.startLogPolling() }
        .onDisappear { tunnelManager.stopLogPolling() }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(tunnelManager.logLines) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.date))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                        }
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .id(entry.seq)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: tunnelManager.logLines.count) { _ in
                if let last = tunnelManager.logLines.last { withAnimation { proxy.scrollTo(last.seq, anchor: .bottom) } }
            }
        }
    }

    private var loggingToggle: some View {
        Toggle("Capture logs (this session only)", isOn: Binding(
            get: { tunnelManager.loggingEnabled },
            set: { tunnelManager.loggingEnabled = $0 }))
            .font(.footnote)
            .padding()
            .background(.thinMaterial)
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var exportText: String {
        tunnelManager.logLines
            .map { "\(Self.timeFormatter.string(from: $0.date))  \($0.message)" }
            .joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Add the entry point** in `App/Views/ProfileDetailView.swift`. Add a Diagnostics section with a `NavigationLink` to `LogView` (place it after the "VPN options" section, inside the same `Form`/`List`):

```swift
                Section("Diagnostics") {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("Connection log", systemImage: "text.alignleft")
                    }
                }
```

- [ ] **Step 3: Build the iOS app**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Build the macOS app**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG-mac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-mac CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Shared/LogView.swift App/Views/ProfileDetailView.swift
git commit -m "Add LogView (shared) + a Diagnostics entry point in ProfileDetailView"
```

---

### Task 5: Full build + test sweep

**Files:** none (verification only).

- [ ] **Step 1: Parser/unit tests**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 2: iOS device build**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: macOS device build**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG-mac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-mac CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

---

## Self-Review

- **Spec coverage:** LogRingBuffer + LogEntry (T1), extension capture + IPC (T2), TunnelManager polling/clear/toggle (T3), LogView + entry point (T4), builds (T5). Privacy stance (in-memory, bounded, off switch) enforced in T1/T2/T3. ✓
- **Placeholder scan:** every step has concrete code/commands; no TBD/TODO. ✓
- **Type consistency:** `LogEntry{seq,date,message}` and `LogRingBuffer.{append,entries(since:),latestCursor,clear,count}` are defined in T1 and used verbatim in T2/T3; IPC keys (`lines`,`seq`,`ts`,`msg`,`cursor`) match between the extension reply (T2) and the app parse (T3); `logs:<cursor>`/`logs:clear` commands match on both sides; `loggingEnabled` read from `providerConfiguration` (T2) is written there (T3). ✓
- **Cross-platform:** `LogView` is in `Shared/`, uses only `Clipboard`/`inlineNavTitle` platform shims; entry point is in the shared `ProfileDetailView`, so both iOS and macOS get it. ✓

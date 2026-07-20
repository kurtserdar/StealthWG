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

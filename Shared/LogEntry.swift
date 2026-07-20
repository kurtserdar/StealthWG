import Foundation

/// One line of the ephemeral connection log. `seq` is a monotonically increasing
/// id assigned by LogRingBuffer, also used as the IPC polling cursor.
struct LogEntry: Equatable, Identifiable {
    let seq: Int
    let date: Date
    let message: String
    var id: Int { seq }
}

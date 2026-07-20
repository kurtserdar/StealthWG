import Foundation

enum OnDemandAction: Equatable { case connect, ignore, disconnect }
enum OnDemandInterface: Equatable { case any, wifi, cellular }

/// A transport-agnostic description of one on-demand rule (adapted to
/// NEOnDemandRule in TunnelManager). Pure so the ordering logic is testable.
struct OnDemandRuleSpec: Equatable {
    let action: OnDemandAction
    let interface: OnDemandInterface
    let ssids: [String]   // empty = no SSID constraint
}

/// Builds the ordered rule specs: Ignore on trusted Wi-Fi SSIDs, optionally Ignore
/// on cellular, then Connect everywhere. Blank SSIDs are dropped; SSIDs de-duped.
func onDemandRuleSpecs(trustedSSIDs: [String], trustCellular: Bool) -> [OnDemandRuleSpec] {
    var seen = Set<String>()
    let clean = trustedSSIDs
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }

    var specs: [OnDemandRuleSpec] = []
    if !clean.isEmpty {
        specs.append(OnDemandRuleSpec(action: .ignore, interface: .wifi, ssids: clean))
    }
    if trustCellular {
        specs.append(OnDemandRuleSpec(action: .ignore, interface: .cellular, ssids: []))
    }
    specs.append(OnDemandRuleSpec(action: .connect, interface: .any, ssids: []))
    return specs
}

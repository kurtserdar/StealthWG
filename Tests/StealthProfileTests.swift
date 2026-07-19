import Foundation

// Standalone assert-based tests for StealthProfile. The packet tunnel extension
// only builds for a device (the wireguard-go bridge has no simulator target), so
// an XCTest bundle can't host this pure-logic parser. scripts/test-parser.sh
// compiles this together with Shared/StealthProfile.swift and runs it.
@main
enum StealthProfileTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("ok: \(message)")
        } else {
            print("FAIL: \(message)")
            failures += 1
        }
    }

    static func main() {
        let full = """
        [Interface]
        PrivateKey = aaaa
        Address = 10.0.0.2/32

        [Peer]
        PublicKey = bbbb
        Endpoint = 1.2.3.4:51819
        AllowedIPs = 0.0.0.0/0

        [Stealth]
        MaskKey = c3RlYWx0aHdn
        """
        let p = try! StealthProfile.parse(full)
        check(p.maskKey == "c3RlYWx0aHdn", "extracts MaskKey")
        check(!p.wgQuickConfig.contains("[Stealth]"), "strips [Stealth] header")
        check(!p.wgQuickConfig.contains("MaskKey"), "strips MaskKey line")
        check(p.wgQuickConfig.contains("[Interface]"), "keeps [Interface]")
        check(p.wgQuickConfig.contains("[Peer]"), "keeps [Peer]")
        check(p.wgQuickConfig.contains("Endpoint = 1.2.3.4:51819"), "keeps Endpoint")

        let plain = """
        [Interface]
        PrivateKey = aaaa

        [Peer]
        PublicKey = bbbb
        Endpoint = 1.2.3.4:51820
        """
        let pp = try! StealthProfile.parse(plain)
        check(pp.maskKey == nil, "nil maskKey when no [Stealth]")
        check(pp.wgQuickConfig.contains("[Peer]"), "plain keeps [Peer]")

        let midStealth = """
        [Interface]
        PrivateKey = aaaa

        [Stealth]
        MaskKey = zzzz

        [Peer]
        PublicKey = bbbb
        """
        let pm = try! StealthProfile.parse(midStealth)
        check(pm.maskKey == "zzzz", "mid: extracts MaskKey")
        check(pm.wgQuickConfig.contains("[Peer]"), "mid: keeps trailing [Peer]")
        check(!pm.wgQuickConfig.contains("zzzz"), "mid: drops mask key value")

        do {
            _ = try StealthProfile.parse("   \n  ")
            check(false, "empty should throw")
        } catch StealthProfile.ParseError.emptyConfiguration {
            check(true, "empty throws emptyConfiguration")
        } catch {
            check(false, "empty threw wrong error: \(error)")
        }

        // serialize(): reconstructs raw text with a [Stealth] section when masked.
        let s = StealthProfile(wgQuickConfig: "[Interface]\nPrivateKey = aaaa", maskKey: "kkkk").serialize()
        check(s.contains("[Interface]"), "serialize keeps wg config")
        check(s.contains("[Stealth]"), "serialize adds [Stealth] when masked")
        check(s.contains("MaskKey = kkkk"), "serialize writes MaskKey")

        let plainS = StealthProfile(wgQuickConfig: "[Interface]\nPrivateKey = aaaa", maskKey: nil).serialize()
        check(!plainS.contains("[Stealth]"), "serialize omits [Stealth] when plain")

        // Round-trip: parse(serialize(x)) == x for both masked and plain.
        let rt = try! StealthProfile.parse(p.serialize())
        check(rt == p, "round-trips masked profile")
        let rtPlain = try! StealthProfile.parse(pp.serialize())
        check(rtPlain == pp, "round-trips plain profile")

        // endpoints: primary from [Peer] Endpoint plus [Stealth] Endpoints, ordered/deduped.
        let multi = """
        [Interface]
        PrivateKey = aaaa

        [Peer]
        PublicKey = bbbb
        Endpoint = gw.example.com:51819
        AllowedIPs = 0.0.0.0/0

        [Stealth]
        MaskKey = kkkk
        Endpoints = gw.example.com:51819, gw.example.com:443
        """
        let pe = try! StealthProfile.parse(multi)
        check(pe.endpoints == ["gw.example.com:51819", "gw.example.com:443"], "parses ordered deduped endpoints")

        let single = try! StealthProfile.parse(full)
        check(single.endpoints == ["1.2.3.4:51819"], "single endpoint from [Peer] only")

        // serialize emits [Stealth] Endpoints when there is more than one; round-trips.
        check(pe.serialize().contains("Endpoints = gw.example.com:51819, gw.example.com:443"), "serialize writes Endpoints")
        let peRT = try! StealthProfile.parse(pe.serialize())
        check(peRT.endpoints == pe.endpoints, "endpoints round-trip")
        check(!single.serialize().contains("Endpoints ="), "no Endpoints line for a single endpoint")

        // FallbackPlan transitions.
        let plan = FallbackPlan(endpointCount: 2, perEndpointTimeout: 12)
        check(plan.decide(index: 0, elapsed: 3, handshaked: true) == .connected, "handshake -> connected")
        check(plan.decide(index: 0, elapsed: 3, handshaked: false) == .keepWaiting, "within timeout -> keepWaiting")
        check(plan.decide(index: 0, elapsed: 13, handshaked: false) == .tryNext(index: 1), "timeout -> tryNext")
        check(plan.decide(index: 1, elapsed: 13, handshaked: false) == .exhausted, "last timeout -> exhausted")

        // lastHandshakeSeconds parsing.
        check(lastHandshakeSeconds(fromRuntimeConfig: "private_key=x\nlast_handshake_time_sec=1699999999\n") == 1699999999, "parses handshake secs")
        check(lastHandshakeSeconds(fromRuntimeConfig: "last_handshake_time_sec=0\n") == 0, "zero handshake secs")
        check(lastHandshakeSeconds(fromRuntimeConfig: "no handshake here") == 0, "absent -> 0")

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

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

        // Transport/SNI: default is mask; quic + SNI parse and round-trip.
        check(single.transport == "mask", "default transport is mask")
        check(single.sni == nil, "default sni is nil")
        check(!single.serialize().contains("Transport"), "no Transport line for the default")
        let quicRaw = """
        [Interface]
        PrivateKey = aaaa

        [Peer]
        PublicKey = bbbb
        Endpoint = gw.example.com:443
        AllowedIPs = 0.0.0.0/0

        [Stealth]
        MaskKey = kkkk
        Transport = quic
        SNI = www.cloudflare.com
        """
        let pq = try! StealthProfile.parse(quicRaw)
        check(pq.transport == "quic", "parses Transport = quic")
        check(pq.sni == "www.cloudflare.com", "parses SNI")
        check(pq.serialize().contains("Transport = quic"), "serialize writes Transport")
        check(pq.serialize().contains("SNI = www.cloudflare.com"), "serialize writes SNI")
        let pqRT = try! StealthProfile.parse(pq.serialize())
        check(pqRT == pq, "round-trips quic profile with SNI")

        // A pure-QUIC profile (no mask key) still gets a [Stealth] section.
        let pureQuic = StealthProfile(
            wgQuickConfig: "[Interface]\nPrivateKey = aaaa",
            maskKey: nil, transport: "quic", sni: "example.org"
        )
        check(pureQuic.serialize().contains("[Stealth]"), "quic-only writes [Stealth]")
        check(try! StealthProfile.parse(pureQuic.serialize()) == pureQuic, "quic-only round-trips")

        // parseEndpointTarget: scheme overrides transport; bare inherits default.
        check(parseEndpointTarget("gw:443", defaultTransport: "quic") == EndpointTarget(hostPort: "gw:443", transport: "quic"), "bare inherits default transport")
        check(parseEndpointTarget("quic://gw:443", defaultTransport: "mask") == EndpointTarget(hostPort: "gw:443", transport: "quic"), "quic:// scheme overrides")
        check(parseEndpointTarget("mask://gw:51819", defaultTransport: "quic") == EndpointTarget(hostPort: "gw:51819", transport: "mask"), "mask:// scheme overrides")
        check(parseEndpointTarget("  QUIC://gw:443 ", defaultTransport: "mask") == EndpointTarget(hostPort: "gw:443", transport: "quic"), "scheme is case-insensitive and trimmed")

        // ProfileDraft carries transport/SNI through build() and from().
        var qd = ProfileDraft.defaults()
        qd.privateKey = "+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko="
        qd.serverPublicKey = "SRV"; qd.endpoint = "gw:443"; qd.maskKey = "MK"
        qd.transport = "quic"; qd.sni = "www.cloudflare.com"
        let qbuilt = qd.build()
        check(qbuilt.contains("Transport = quic"), "draft build writes Transport")
        check(qbuilt.contains("SNI = www.cloudflare.com"), "draft build writes SNI")
        let qback = ProfileDraft.from(try! StealthProfile.parse(qbuilt))
        check(qback.transport == "quic", "draft from: transport")
        check(qback.sni == "www.cloudflare.com", "draft from: sni")
        check(ProfileDraft.defaults().build().contains("Transport =") == false, "default draft omits Transport")

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

        // ProfileDraft key derivation matches wg pubkey (known vector).
        var d = ProfileDraft.defaults()
        d.privateKey = "+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko="
        check(d.derivedPublicKey == "NF8+fWQ3lf9yrvod689ZMK2CP6H1JnYK3lER0ka4M2A=", "draft derives wg public key")
        check(ProfileDraft.defaults().derivedPublicKey == nil, "empty private -> nil public")
        check(ProfileDraft.randomBase64Key().count == 44, "random key is 44-char base64")
        var g = ProfileDraft.defaults(); g.generateKeypair()
        check(g.derivedPublicKey != nil, "generated keypair has a valid public key")

        // build() assembles and round-trips through StealthProfile.parse.
        var bd = ProfileDraft.defaults()
        bd.privateKey = "+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko="
        bd.serverPublicKey = "SRVPUB"
        bd.endpoint = "gw.example.com:51819"
        bd.maskKey = "MASKKEY"
        bd.fallbackEndpoints = ["gw.example.com:443"]
        let bt = bd.build()
        let bp = try! StealthProfile.parse(bt)
        check(bp.maskKey == "MASKKEY", "build round-trips mask key")
        check(bp.endpoints == ["gw.example.com:51819", "gw.example.com:443"], "build round-trips endpoints")
        check(bt.contains("PersistentKeepalive = 25"), "build includes keepalive default")
        check(!bt.contains("PresharedKey"), "build omits empty preshared key")

        // ProfileDraft.from reverses build() for our shape.
        var srcDraft = ProfileDraft.defaults()
        srcDraft.privateKey = "+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko="
        srcDraft.serverPublicKey = "SRV"; srcDraft.endpoint = "gw.example.com:51819"; srcDraft.maskKey = "MK"
        srcDraft.fallbackEndpoints = ["gw.example.com:443"]; srcDraft.keepalive = "25"; srcDraft.dns = "1.1.1.1"
        let backDraft = ProfileDraft.from(try! StealthProfile.parse(srcDraft.build()))
        check(backDraft.privateKey == srcDraft.privateKey, "from: private key")
        check(backDraft.serverPublicKey == "SRV", "from: server pubkey")
        check(backDraft.endpoint == "gw.example.com:51819", "from: endpoint")
        check(backDraft.fallbackEndpoints == ["gw.example.com:443"], "from: fallbacks")
        check(backDraft.maskKey == "MK", "from: mask key")
        check(backDraft.dns == "1.1.1.1", "from: dns")
        check(defaultProfileName(for: try! StealthProfile.parse(srcDraft.build())) == "gw.example.com", "default name = endpoint host")

        // parseRuntimeStats: sums rx/tx across peers, reuses handshake parse.
        let uapi = """
        private_key=abc
        public_key=def
        rx_bytes=1500
        tx_bytes=800
        last_handshake_time_sec=1699999999
        """
        let rs = parseRuntimeStats(uapi)
        check(rs.rxBytes == 1500, "rx parsed")
        check(rs.txBytes == 800, "tx parsed")
        check(rs.lastHandshakeSeconds == 1699999999, "handshake parsed")
        check(parseRuntimeStats("no counters").rxBytes == 0, "missing rx -> 0")

        // ProfileSummary.from: pulls display fields from wgQuickConfig + endpoints/mask.
        let summ = ProfileSummary.from(pe)   // pe: masked, 2 endpoints
        check(summ.maskingOn == true, "summary masking on")
        check(summ.endpoints == ["gw.example.com:51819", "gw.example.com:443"], "summary endpoints")
        check(summ.peerPublicKey == "bbbb", "summary peer pubkey")
        check(summ.transport == "mask", "summary default transport mask")
        let summ2 = ProfileSummary.from(single)   // single: full profile with Address/Endpoint
        check(summ2.address == "10.0.0.2/32", "summary address parsed")
        check(summ2.maskingOn == true, "summary2 masking on")
        let summQ = ProfileSummary.from(pq)   // pq: quic profile with SNI
        check(summQ.transport == "quic", "summary quic transport")
        check(summQ.sni == "www.cloudflare.com", "summary quic sni")

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

        // Connection diagnostics: targets, host/port split, live-status upgrade.
        let diagRaw = """
        [Interface]
        PrivateKey = aaaa

        [Peer]
        PublicKey = bbbb
        Endpoint = gw.example.com:51819
        AllowedIPs = 0.0.0.0/0

        [Stealth]
        MaskKey = kkkk
        Endpoints = gw.example.com:51819, quic://gw.example.com:443
        """
        let diagProfile = try! StealthProfile.parse(diagRaw)
        let targets = diagnosticTargets(for: diagProfile)
        check(targets.map(\.hostPort) == ["gw.example.com:51819", "gw.example.com:443"], "targets from endpoints")
        check(targets[0].transport == "mask" && targets[1].transport == "quic", "target transports (default + scheme)")
        check(targets[1].host == "gw.example.com" && targets[1].port == 443, "host/port split on last colon")

        let seeded = targets.map { DiagnosticResult(target: $0, status: .needsTunnel) }
        let live = applyLiveStatus(seeded, activeEndpoint: "gw.example.com:51819", handshakeRecent: true)
        check(live[0].status == .reachableViaTunnel, "active mask endpoint upgraded via live tunnel")
        check(live[1].status == .needsTunnel, "non-active endpoint untouched")
        let noLive = applyLiveStatus(seeded, activeEndpoint: "gw.example.com:51819", handshakeRecent: false)
        check(noLive[0].status == .needsTunnel, "no upgrade without a recent handshake")
        let quicSeed = [DiagnosticResult(target: targets[1], status: .reachableQUIC(rttMillis: 42))]
        check(applyLiveStatus(quicSeed, activeEndpoint: "gw.example.com:443", handshakeRecent: true)[0].status == .reachableQUIC(rttMillis: 42), "QUIC result untouched by live status")

        check(DiagnosticStatus.reachableQUIC(rttMillis: 12).label == "Reachable · 12 ms", "quic label with rtt")
        check(DiagnosticStatus.needsTunnel.symbol == "info.circle", "needsTunnel symbol")
        check(diagnosticsSummary(live).contains("MASK  gw.example.com:51819  —  Reachable (live tunnel)"), "summary line format")

        // On-demand rule specs: trusted Wi-Fi Ignore + optional cellular + Connect.
        check(onDemandRuleSpecs(trustedSSIDs: [], trustCellular: false)
              == [OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "empty -> connect everywhere")
        check(onDemandRuleSpecs(trustedSSIDs: ["Home"], trustCellular: false)
              == [OnDemandRuleSpec(action: .ignore, interface: .wifi, ssids: ["Home"]),
                  OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "ssids -> ignore wifi then connect")
        check(onDemandRuleSpecs(trustedSSIDs: ["Home", "Work"], trustCellular: true)
              == [OnDemandRuleSpec(action: .ignore, interface: .wifi, ssids: ["Home", "Work"]),
                  OnDemandRuleSpec(action: .ignore, interface: .cellular, ssids: []),
                  OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "ssids + cellular -> three rules in order")
        check(onDemandRuleSpecs(trustedSSIDs: [], trustCellular: true)
              == [OnDemandRuleSpec(action: .ignore, interface: .cellular, ssids: []),
                  OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "cellular only -> ignore cellular then connect")
        check(onDemandRuleSpecs(trustedSSIDs: [" Home ", "", "Home"], trustCellular: false)[0].ssids == ["Home"],
              "blank dropped and ssids de-duplicated/trimmed")

        // WidgetSnapshot: labels/accents per state + Codable round-trip.
        check(WidgetSnapshot.empty.state == .exposed, "empty snapshot is exposed")
        check(WidgetSnapshot(state: .masked).statusLabel == "Masked" && WidgetSnapshot(state: .masked).accentName == "teal", "masked -> teal")
        check(WidgetSnapshot(state: .masking).statusLabel == "Masking…" && WidgetSnapshot(state: .masking).accentName == "amber", "masking -> amber")
        check(WidgetSnapshot(state: .exposed).accentName == "coral", "exposed -> coral")
        let snap = WidgetSnapshot(state: .masked, profileName: "Home", transport: "quic", endpoint: "gw:443", rxRate: 1200, txRate: 340, connectedSince: nil, lastHandshakeSeconds: 8)
        let round = try! JSONDecoder().decode(WidgetSnapshot.self, from: try! JSONEncoder().encode(snap))
        check(round == snap, "snapshot Codable round-trips")

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

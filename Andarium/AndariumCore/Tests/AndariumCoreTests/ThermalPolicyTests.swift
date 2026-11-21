// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore

/// What the guest is told from iOS's thermal state: nothing for nominal and
/// fair, Android's severe at serious (its frame rate cap) and critical at
/// critical. A reported state rises at once, falls 120 s after it ended, and
/// restarts the wait when it comes back. The policy is pure, so every test
/// gives it a clock of its own.
struct ThermalPolicyTests {
    private func at(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }

    /// A policy the tests can call inside `#expect`.
    private final class Watch {
        private var policy = ThermalPolicy()
        var severity: AndroidThermalSeverity { policy.severity }
        var nextExpiry: UInt64? { policy.nextExpiry }
        @discardableResult func observe(_ state: HostThermalState, at now: UInt64) -> Bool {
            policy.observe(state, at: now)
        }
        @discardableResult func advance(to now: UInt64) -> Bool { policy.advance(to: now) }
        func claimAnnouncement() -> Bool { policy.claimAnnouncement() }
    }

    // MARK: The mapping

    @Test func eachHostStateHasItsAndroidSeverity() {
        #expect(HostThermalState.nominal.severity == .none)
        #expect(HostThermalState.fair.severity == .none)
        #expect(HostThermalState.serious.severity == .severe)
        #expect(HostThermalState.critical.severity == .critical)
        #expect(ProcessInfoMapping.all == [.nominal, .fair, .serious, .critical])
    }

    @Test func seriousAndCriticalCapTheFrameRateAndNothingBelowThemDoes() {
        #expect(ThermalPolicy.capSeverity == .severe)
        #expect(HostThermalState.serious.severity >= ThermalPolicy.capSeverity)
        #expect(HostThermalState.critical.severity >= ThermalPolicy.capSeverity)
        for state in [HostThermalState.nominal, .fair] {
            #expect(state.severity < ThermalPolicy.capSeverity, "\(state) caps the frame rate")
        }
    }

    @Test func theHostSaysNoneSevereOrCriticalAndNothingElse() {
        let told = Set(HostThermalState.allCases.map(\.severity))
        #expect(told == [.none, .severe, .critical], "light and moderate are never sent")
    }

    private enum ProcessInfoMapping {
        static var all: [HostThermalState] {
            [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical].map { HostThermalState($0) }
        }
    }

    @Test func aSessionStartsAtNone() {
        let policy = Watch()
        #expect(policy.severity == .none)
        #expect(policy.nextExpiry == nil)
        #expect(!policy.observe(.nominal, at: at(1)))
        #expect(policy.severity == .none)
    }

    // MARK: Rising and falling

    @Test func fairChangesNothingAndHoldsNothing() {
        let policy = Watch()
        #expect(!policy.observe(.fair, at: at(10)))
        #expect(!policy.observe(.nominal, at: at(11)))
        #expect(!policy.observe(.fair, at: at(12)))
        #expect(policy.severity == .none)
        #expect(policy.nextExpiry == nil, "a state that is not reported left a wait behind")
        #expect(!policy.advance(to: at(1000)))
    }

    @Test func aRiseIsReportedAtOnceAtEveryReportedStep() {
        let policy = Watch()
        #expect(!policy.observe(.fair, at: at(10)))
        #expect(policy.observe(.serious, at: at(11)))
        #expect(policy.severity == .severe)
        #expect(policy.observe(.critical, at: at(12)))
        #expect(policy.severity == .critical)
        #expect(!policy.observe(.critical, at: at(13)))
    }

    @Test func aStateThatBeginsSeriousOrCriticalIsCappedFromItsFirstReading() {
        let serious = Watch()
        #expect(serious.observe(.serious, at: at(0)))
        #expect(serious.severity == .severe)
        #expect(serious.claimAnnouncement())
        let critical = Watch()
        #expect(critical.observe(.critical, at: at(0)))
        #expect(critical.severity == .critical)
    }

    @Test func aStateThatBeginsFairIsNotCappedUntilSerious() {
        let policy = Watch()
        #expect(!policy.observe(.fair, at: at(0)))
        #expect(policy.severity == .none)
        #expect(!policy.claimAnnouncement())
        #expect(policy.observe(.serious, at: at(30)))
        #expect(policy.severity == .severe)
        #expect(policy.claimAnnouncement())
    }

    @Test func theSeverityFallsOneHundredTwentySecondsAfterSeriousEnded() {
        let policy = Watch()
        policy.observe(.serious, at: at(10))
        policy.observe(.nominal, at: at(100))
        #expect(policy.severity == .severe, "the fall was not held")
        #expect(policy.nextExpiry == at(220))
        #expect(!policy.advance(to: at(219.999)))
        #expect(policy.severity == .severe)
        #expect(policy.advance(to: at(220)))
        #expect(policy.severity == .none)
        #expect(policy.nextExpiry == nil)
    }

    @Test func aFallFromSeriousToFairWaitsAsWellAndEndsAtNone() {
        let policy = Watch()
        policy.observe(.serious, at: at(10))
        policy.observe(.fair, at: at(100))
        #expect(policy.severity == .severe)
        policy.advance(to: at(219))
        #expect(policy.severity == .severe)
        #expect(policy.advance(to: at(220)))
        #expect(policy.severity == .none, "fair is not reported")
        #expect(policy.nextExpiry == nil)
    }

    @Test func theSeverityFallsOneHundredTwentySecondsAfterCriticalEnded() {
        let policy = Watch()
        policy.observe(.critical, at: at(10))
        policy.observe(.nominal, at: at(100))
        #expect(policy.severity == .critical, "the fall was not held")
        #expect(policy.nextExpiry == at(220))
        #expect(!policy.advance(to: at(219.999)))
        #expect(policy.advance(to: at(220)))
        #expect(policy.severity == .none)
    }

    @Test func aFallFromCriticalToSeriousHoldsCriticalAndThenStaysAtSevere() {
        let policy = Watch()
        policy.observe(.serious, at: at(0))
        policy.observe(.critical, at: at(30))
        #expect(policy.observe(.serious, at: at(60)) == false, "the fall to serious was reported at once")
        #expect(policy.severity == .critical)
        #expect(policy.nextExpiry == at(180))
        #expect(!policy.advance(to: at(179.999)))
        #expect(policy.severity == .critical)
        #expect(policy.advance(to: at(180)))
        #expect(policy.severity == .severe, "serious is still current")
        #expect(policy.nextExpiry == nil)
        #expect(!policy.advance(to: at(10_000)))
    }

    @Test func aStepwiseFallHoldsEachReportedStateForItsOwnWait() {
        let policy = Watch()
        policy.observe(.critical, at: at(0))
        policy.observe(.serious, at: at(100))
        policy.observe(.fair, at: at(150))
        // Critical ended at 100, serious at 150.
        #expect(policy.severity == .critical)
        #expect(policy.advance(to: at(220)))
        #expect(policy.severity == .severe, "the serious that ended at 150 still counts")
        policy.advance(to: at(269.9))
        #expect(policy.severity == .severe)
        #expect(policy.advance(to: at(270)))
        #expect(policy.severity == .none)
        #expect(policy.nextExpiry == nil)
    }

    @Test func seriousCriticalSeriousWithinTheHoldIsCriticalUntilItsWaitEndsAndThenSevere() {
        let policy = Watch()
        #expect(policy.observe(.serious, at: at(0)))
        #expect(policy.observe(.critical, at: at(30)))
        #expect(!policy.observe(.serious, at: at(60)))
        // Critical ended at 60: the wait ends at 180.
        policy.advance(to: at(179))
        #expect(policy.severity == .critical)
        #expect(policy.advance(to: at(180)))
        #expect(policy.severity == .severe)
    }

    @Test func criticalSeriousCriticalWithinTheHoldIsOneSteadyCap() {
        let policy = Watch()
        #expect(policy.observe(.critical, at: at(0)))
        // Critical ended at 30: the wait would end at 150.
        #expect(!policy.observe(.serious, at: at(30)))
        #expect(policy.severity == .critical)
        #expect(policy.nextExpiry == at(150))
        // It comes back at 100, before the wait ends: the wait is void. The
        // serious that ended at 100 is behind critical and expires with no effect.
        #expect(!policy.observe(.critical, at: at(100)))
        #expect(policy.nextExpiry == at(220))
        #expect(!policy.advance(to: at(150)), "the first wait still ran")
        #expect(policy.severity == .critical)
        #expect(!policy.advance(to: at(220)))
        #expect(policy.severity == .critical)
        #expect(policy.nextExpiry == nil)
        // It ends again at 230: the fall is 120 s after that, to serious.
        #expect(!policy.observe(.serious, at: at(230)))
        #expect(policy.nextExpiry == at(350))
        #expect(!policy.advance(to: at(349.999)))
        #expect(policy.severity == .critical)
        #expect(policy.advance(to: at(350)))
        #expect(policy.severity == .severe)
    }

    @Test func seriousThatEndedBehindCriticalLeavesNoSevereTail() {
        let policy = Watch()
        #expect(policy.observe(.serious, at: at(0)))
        // Serious ended at 30, when critical began: its wait ends at 150.
        #expect(policy.observe(.critical, at: at(30)))
        #expect(!policy.observe(.nominal, at: at(60)))
        #expect(policy.severity == .critical)
        #expect(policy.nextExpiry == at(150))
        // Serious's wait ends first, behind critical's, with no effect.
        #expect(!policy.advance(to: at(150)))
        #expect(policy.severity == .critical)
        #expect(policy.nextExpiry == at(180))
        // Critical's wait ends at 180, and nothing hot is left in the last
        // 120 s: the fall is straight to none.
        #expect(policy.advance(to: at(180)))
        #expect(policy.severity == .none)
        #expect(policy.nextExpiry == nil)
    }

    @Test func aFlickerAroundSeriousIsOneSteadyCap() {
        let policy = Watch()
        #expect(policy.observe(.serious, at: at(0)))
        var changes = 0
        for step in 1...20 {
            let state: HostThermalState = step % 2 == 1 ? .fair : .serious
            if policy.observe(state, at: at(Double(step) * 40)) { changes += 1 }
        }
        #expect(changes == 0, "the severity moved while the state flickered")
        #expect(policy.severity == .severe)
    }

    @Test func aFlickerAroundCriticalNeverLowersTheSeverityBelowCriticalUntilItEnds() {
        let policy = Watch()
        policy.observe(.critical, at: at(0))
        var changes = 0
        for step in 1...20 {
            let state: HostThermalState = step % 2 == 1 ? .serious : .critical
            if policy.observe(state, at: at(Double(step) * 40)) { changes += 1 }
        }
        #expect(changes == 0, "the severity moved while the state flickered")
        #expect(policy.severity == .critical)
    }

    @Test func aStateThatComesBackRestartsTheWait() {
        let policy = Watch()
        policy.observe(.serious, at: at(0))
        policy.observe(.nominal, at: at(50))
        // The first wait would end at 170.
        policy.observe(.serious, at: at(100))
        #expect(policy.severity == .severe)
        policy.observe(.nominal, at: at(130))
        policy.advance(to: at(170))
        #expect(policy.severity == .severe, "the first wait still ran")
        policy.advance(to: at(249.9))
        #expect(policy.severity == .severe)
        #expect(policy.advance(to: at(250)))
        #expect(policy.severity == .none)
    }

    @Test func aReadingAfterALongGapFindsTheExpiryAlreadyPassed() {
        let policy = Watch()
        policy.observe(.serious, at: at(0))
        policy.observe(.nominal, at: at(10))
        // The application was away longer than the wait.
        #expect(policy.observe(.nominal, at: at(1000)))
        #expect(policy.severity == .none)
    }

    @Test func aRepeatedReadingChangesNothing() {
        let policy = Watch()
        policy.observe(.serious, at: at(0))
        for second in stride(from: 1.0, to: 60.0, by: 7) {
            #expect(!policy.observe(.serious, at: at(second)))
        }
        #expect(policy.nextExpiry == nil)
    }

    // MARK: Against a definition

    /// The severity by its definition, from the whole history: the hottest
    /// state in effect at any moment of the last 120 s.
    private func reference(history: [(start: Double, state: HostThermalState)], now: Double) -> AndroidThermalSeverity {
        var hottest = HostThermalState.nominal
        for (index, entry) in history.enumerated() {
            let end = index + 1 < history.count ? history[index + 1].start : Double.infinity
            // In effect during [start, end); the window is (now - 120, now].
            if entry.start <= now, end > now - 120, entry.state > hottest { hottest = entry.state }
        }
        return hottest.severity
    }

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    @Test func randomWalksAgreeWithTheDefinitionAndSayOnlyNoneSevereOrCritical() {
        var expiriesChecked = 0
        for seed in UInt64(1)...40 {
            var random = Generator(state: seed)
            let policy = Watch()
            var history: [(start: Double, state: HostThermalState)] = [(0, .nominal)]
            var clock = 0.0
            for _ in 0..<60 {
                clock += Double(random.next() % 90) + 1
                let state = HostThermalState.allCases[Int(random.next() % 4)]
                // Look at every expiry that passed before this reading.
                while let expiry = policy.nextExpiry, Double(expiry) / 1e9 <= clock {
                    let moment = Double(expiry) / 1e9
                    policy.advance(to: expiry)
                    expiriesChecked += 1
                    #expect(policy.severity == reference(history: history, now: moment), "seed \(seed) at expiry \(moment)")
                }
                if history.last?.state != state { history.append((clock, state)) }
                policy.observe(state, at: at(clock))
                #expect(policy.severity == reference(history: history, now: clock), "seed \(seed) at \(clock)")
                #expect([.none, .severe, .critical].contains(policy.severity), "seed \(seed) at \(clock)")
                if policy.nextExpiry != nil { #expect(policy.severity >= .severe, "a wait outlived the cap") }
            }
        }
        #expect(expiriesChecked > 100, "the walks never reached an expiry")
    }

    // MARK: The announcement

    @Test func theCapIsAnnouncedOnceAtTheFirstSerious() {
        let policy = Watch()
        policy.observe(.fair, at: at(0))
        #expect(!policy.claimAnnouncement(), "announced at fair")
        #expect(!policy.claimAnnouncement(), "a refusal consumed the announcement")
        policy.observe(.serious, at: at(10))
        #expect(policy.claimAnnouncement())
        #expect(!policy.claimAnnouncement())
        policy.observe(.critical, at: at(20))
        #expect(!policy.claimAnnouncement(), "critical announced a second cap")
    }

    @Test func theCapIsNotAnnouncedAgainAfterCoolingAndHeatingAgain() {
        let policy = Watch()
        policy.observe(.serious, at: at(0))
        #expect(policy.claimAnnouncement())
        policy.observe(.nominal, at: at(30))
        policy.advance(to: at(150))
        #expect(policy.severity == .none)
        policy.observe(.serious, at: at(200))
        #expect(!policy.claimAnnouncement())
        policy.observe(.critical, at: at(210))
        policy.observe(.fair, at: at(400))
        policy.observe(.critical, at: at(600))
        #expect(!policy.claimAnnouncement())
    }

    @Test func aSessionThatNeverReachesSeriousAnnouncesNothing() {
        let policy = Watch()
        for (second, state) in [(0.0, HostThermalState.fair), (30, .nominal), (500, .fair), (600, .nominal)] {
            policy.observe(state, at: at(second))
            #expect(!policy.claimAnnouncement())
        }
        policy.advance(to: at(1000))
        #expect(!policy.claimAnnouncement())
    }

    @Test func aJumpStraightToCriticalIsTheFirstCap() {
        let policy = Watch()
        policy.observe(.critical, at: at(5))
        #expect(policy.claimAnnouncement())
    }

    @Test func aLaterAnnouncementWaitsForTheCallThatCanMakeItWhileTheCapHolds() {
        let policy = Watch()
        policy.observe(.serious, at: at(0))
        // The caller could not announce yet and the state cooled: the cap
        // still counts for 120 s, so it is still to be announced.
        policy.observe(.nominal, at: at(20))
        #expect(policy.claimAnnouncement())
    }

    @Test func aCapThatHasFallenIsNotAnnouncedLate() {
        let policy = Watch()
        policy.observe(.serious, at: at(0))
        policy.observe(.nominal, at: at(20))
        policy.advance(to: at(140))
        #expect(policy.severity == .none)
        #expect(!policy.claimAnnouncement())
    }
}

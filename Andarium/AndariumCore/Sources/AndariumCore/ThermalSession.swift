// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Tells the guest's thermal HAL how hot the device is, and says when Android
/// starts to lower the frame rate for it.
///
/// The application reads iOS's thermal state and gives each reading to
/// `observe`. A run (a normal start, from its first moment until it ends) has
/// a `ThermalPolicy` of its own, which turns the readings into the severity
/// Android is told, and a `ThermalStream`, which carries it to the HAL: the
/// stream connects at once and tries again every second, because the HAL
/// starts early in boot. Once Android has booted, five attempts in a row that
/// fail end the attempts for that boot, silently: an older image has no HAL,
/// and then nothing lowers the frame rate and nothing is announced. A
/// connection that was made and is lost is tried again the same way.
///
/// The cap is announced once in a run (`ThermalPolicy.claimAnnouncement`), at
/// the first moment the severity is at the cap or above and the HAL is
/// connected: that is when Android's frame rate drops. A guest that restarts
/// itself reconnects without a new announcement. The severity falls on a
/// timer when a hotter state stops counting; the clock and the timer are
/// the caller's to give, so a test moves the one by hand and fires the other.
///
/// Every call returns at once. The work is in order on one queue, and the
/// policy and the stream are only touched there.
public final class ThermalSession: @unchecked Sendable {
    /// Attempts that fail in a row, after Android has booted, before the
    /// session stops trying for that boot.
    public static let attemptsAfterBoot = 5

    private let opener: any GuestStreamOpener
    private let retryDelay: DispatchTimeInterval
    private let clock: @Sendable () -> UInt64
    private let schedule: @Sendable (_ nanoseconds: UInt64, _ work: @escaping @Sendable () -> Void) -> Void
    private let capStarted: @Sendable () -> Void
    private let queue = DispatchQueue(label: "andarium-thermal-session")

    // Touched only on `queue`.
    private var booted = false
    private var inRun = false
    private var observed = HostThermalState.nominal
    private var policy = ThermalPolicy()
    private var stream: ThermalStream?
    private var streamEpoch: UInt64 = 0
    private var connected = false
    private var failedAttempts = 0
    private var gaveUp = false
    private var timerEpoch: UInt64 = 0

    /// `capStarted` is called on the session's queue, once per run, when the
    /// frame rate cap starts.
    public init(
        opener: any GuestStreamOpener, retryDelay: DispatchTimeInterval = .seconds(1),
        clock: @escaping @Sendable () -> UInt64 = ThermalSession.uptimeNanoseconds,
        schedule: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void = ThermalSession.dispatchAfter,
        capStarted: @escaping @Sendable () -> Void
    ) {
        self.opener = opener
        self.retryDelay = retryDelay
        self.clock = clock
        self.schedule = schedule
        self.capStarted = capStarted
    }

    deinit { stream?.stop() }

    public static let uptimeNanoseconds: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    /// Runs `work` after `nanoseconds` on `DispatchTime`'s clock.
    public static let dispatchAfter: @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void = { nanoseconds, work in
        let delay = DispatchTimeInterval.nanoseconds(Int(min(nanoseconds, UInt64(Int.max))))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// What is wanted now. `running` is a normal run of the guest (not
    /// Recovery, which has no HAL); `booted` that Android has reported boot
    /// completed in it.
    public func update(running: Bool, booted: Bool) {
        queue.async { [self] in
            let bootedNow = booted && !self.booted
            self.booted = booted
            if bootedNow { failedAttempts = 0 }
            if running {
                if !inRun { beginRun() }
                if stream == nil && !gaveUp { openStream() }
            } else if inRun {
                endRun()
            }
        }
    }

    /// iOS's thermal state as it is now: on a change, and on every return to
    /// the foreground, where the notification may have been missed.
    public func observe(_ state: HostThermalState) {
        queue.async { [self] in
            observed = state
            guard inRun else { return }
            apply(policy.observe(state, at: clock()))
        }
    }

    /// The guest restarted itself: what was connected to is gone, and the
    /// next boot begins the attempts again. The run, its policy and the
    /// announcement stay.
    public func restart() {
        queue.async { [self] in
            closeStream()
            gaveUp = false
            failedAttempts = 0
        }
    }

    /// Returns when everything asked of the session so far has been done.
    public func settle() {
        queue.sync {}
    }

    /// The severity Android is told in this run; none outside a run.
    public var severity: AndroidThermalSeverity { queue.sync { inRun ? policy.severity : .none } }

    /// Whether the guest's HAL is connected.
    public var isConnected: Bool { queue.sync { connected } }

    /// Whether the session stopped trying for this boot.
    public var hasGivenUp: Bool { queue.sync { gaveUp } }

    // MARK: A run

    private func beginRun() {
        inRun = true
        policy = ThermalPolicy()
        failedAttempts = 0
        gaveUp = false
        // A reading from before the run is the state the run begins in.
        policy.observe(observed, at: clock())
        scheduleExpiry()
    }

    private func endRun() {
        inRun = false
        timerEpoch &+= 1
        closeStream()
        policy = ThermalPolicy()
    }

    private func openStream() {
        streamEpoch &+= 1
        let current = streamEpoch
        let stream = ThermalStream(opener: opener, retryDelay: retryDelay) { [weak self] event in
            self?.queue.async { [weak self] in
                guard let self, streamEpoch == current else { return }
                handle(event)
            }
        }
        stream.send(policy.severity)
        self.stream = stream
        stream.start()
    }

    private func closeStream() {
        streamEpoch &+= 1
        stream?.stop()
        stream = nil
        connected = false
    }

    private func handle(_ event: ThermalStream.Event) {
        switch event {
        case .connected:
            connected = true
            failedAttempts = 0
            announceIfDue()
        case .attemptFailed:
            guard booted else { return }
            failedAttempts += 1
            if failedAttempts >= Self.attemptsAfterBoot {
                gaveUp = true
                closeStream()
            }
        case .lost:
            connected = false
        }
    }

    // MARK: The policy

    private func tickNow() {
        guard inRun else { return }
        apply(policy.advance(to: clock()))
    }

    private func apply(_ changed: Bool) {
        if changed { stream?.send(policy.severity) }
        scheduleExpiry()
        announceIfDue()
    }

    private func announceIfDue() {
        guard connected, policy.claimAnnouncement() else { return }
        capStarted()
    }

    /// Looks again when a state that ended stops counting.
    private func scheduleExpiry() {
        timerEpoch &+= 1
        guard let expiry = policy.nextExpiry else { return }
        let now = clock()
        let delay = expiry > now ? expiry - now : 0
        let epoch = timerEpoch
        schedule(delay) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, timerEpoch == epoch else { return }
                tickNow()
            }
        }
    }
}

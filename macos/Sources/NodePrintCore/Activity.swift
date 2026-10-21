import Foundation
import os

/// Where the idle rule and the update timer read the time, so tests can move it by hand.
public protocol UpdateClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

extension ContinuousClock: UpdateClock {
    public func sleep(until deadline: Instant) async throws {
        try await sleep(until: deadline, tolerance: nil)
    }
}

/// `POST /print` requests in flight and when the last one ended, which decide whether the app may update itself.
public final class Activity: Sendable {
    private struct State {
        var inFlight = 0
        var lastEnded: ContinuousClock.Instant?
    }

    private static let quietPeriod = Duration.seconds(5 * 60)

    private let clock: any UpdateClock
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(clock: any UpdateClock = ContinuousClock()) {
        self.clock = clock
    }

    func jobArrived() {
        state.withLock { $0.inFlight += 1 }
    }

    func jobEnded() {
        let now = clock.now
        state.withLock {
            $0.inFlight -= 1
            $0.lastEnded = now
        }
    }

    /// No job in flight and the last one ended at least 5 minutes ago; no job since start counts as idle.
    public var isIdle: Bool {
        let now = clock.now
        return state.withLock { state in
            state.inFlight == 0 && (state.lastEnded.map { $0.duration(to: now) >= Self.quietPeriod } ?? true)
        }
    }
}

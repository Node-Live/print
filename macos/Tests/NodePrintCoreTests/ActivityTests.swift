import Foundation
import os
import Testing
@testable import NodePrintCore

/// Moves only when told; `sleep` jumps to its deadline.
final class ManualClock: UpdateClock {
    private let current = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    var now: ContinuousClock.Instant {
        current.withLock { $0 }
    }

    func advance(by duration: Duration) {
        current.withLock { $0 += duration }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        current.withLock { $0 = max($0, deadline) }
    }
}

@Suite struct IdleRule {
    @Test func isIdleWhenNoJobRanSinceStart() {
        #expect(Activity(clock: ManualClock()).isIdle)
    }

    @Test func isBusyWhileAJobIsInFlight() {
        let clock = ManualClock()
        let activity = Activity(clock: clock)
        activity.jobArrived()
        clock.advance(by: .seconds(60 * 60))
        #expect(!activity.isIdle)
    }

    @Test(arguments: [(minutes: 4, idle: false), (minutes: 5, idle: true)])
    func waitsFiveMinutesAfterTheLastJobEnded(minutes: Int, idle: Bool) {
        let clock = ManualClock()
        let activity = Activity(clock: clock)
        activity.jobArrived()
        activity.jobEnded()
        clock.advance(by: .seconds(minutes * 60))
        #expect(activity.isIdle == idle)
    }

    @Test func countsAPrintRequestFromItsHeadUntilItsResponse() async throws {
        let clock = ManualClock()
        let activity = Activity(clock: clock)
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id), activity: activity)
        let pdf = samplePDF()
        let head = "POST /print?channel=label HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(pdf.count)\r\nExpect: 100-continue\r\n\r\n"
        let idleWhileTheBodyIsOnItsWay = OSAllocatedUnfairLock(initialState: true)
        let reply = try await harness.exchange(Data(head.utf8), rest: pdf) {
            clock.advance(by: .seconds(10 * 60))
            idleWhileTheBodyIsOnItsWay.withLock { $0 = activity.isIdle }
        }
        #expect(reply.status == 200)
        #expect(!idleWhileTheBodyIsOnItsWay.withLock { $0 })
        #expect(!activity.isIdle)
        clock.advance(by: .seconds(5 * 60))
        #expect(activity.isIdle)
    }
}

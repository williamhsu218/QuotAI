import Foundation
import Testing
@testable import QuotAICore

@Test("Changing a sleeping long interval schedules the next refresh immediately on the new interval")
@MainActor func refreshReschedulesSleepingTimer() async throws {
    var interval = 900.0, ticks = 0
    let scheduler = QuotaRefreshScheduler(interval: { interval }, tick: { ticks += 1 })
    scheduler.start()
    try await Task.sleep(for: .milliseconds(20))
    interval = 0.02
    scheduler.reschedule()
    try await Task.sleep(for: .milliseconds(100))
    #expect(ticks > 0)
    scheduler.stop()
    let stoppedAt = ticks
    try await Task.sleep(for: .milliseconds(60))
    #expect(ticks == stoppedAt)
}

@Test("Lengthening the interval cancels the old tick, repeated starts do not duplicate timers, disabled timers stay stopped")
@MainActor func refreshTimerLifecycle() async throws {
    var interval = 0.1, ticks = 0
    let scheduler = QuotaRefreshScheduler(interval: { interval }, tick: { ticks += 1 })
    scheduler.reschedule()
    #expect(!scheduler.isRunning)
    scheduler.start(); scheduler.start()
    try await Task.sleep(for: .milliseconds(20))
    interval = 900
    scheduler.reschedule()
    try await Task.sleep(for: .milliseconds(160))
    #expect(ticks == 0)
    scheduler.stop()
    #expect(!scheduler.isRunning)
}

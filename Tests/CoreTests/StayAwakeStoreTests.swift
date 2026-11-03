import Foundation
import Testing

@testable import QuotAICore

@MainActor
@Suite("Stay Awake store")
struct StayAwakeStoreTests {
    @Test("A finite session persists its expiry and stopping clears it")
    func finiteSession() throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let store = StayAwakeStore(defaults: defaults.defaults)
        store.selectDuration(.fiveMinutes)
        #expect(!store.isActive)

        let started = Date()
        store.setEnabled(true)
        let expiry = try #require(store.expiresAt)
        #expect(store.isActive)
        #expect(abs(expiry.timeIntervalSince(started) - 300) < 5)
        #expect(defaults.defaults.bool(forKey: DefaultsKey.stayAwakeEnabled))
        #expect(defaults.defaults.object(forKey: DefaultsKey.stayAwakeExpiration) as? Date == expiry)

        store.stop()
        #expect(!store.isActive && store.expiresAt == nil)
        #expect(!defaults.defaults.bool(forKey: DefaultsKey.stayAwakeEnabled))
        #expect(defaults.defaults.object(forKey: DefaultsKey.stayAwakeExpiration) == nil)
    }

    @Test("Changing the mode keeps the expiry; changing the duration restarts it")
    func modeAndDurationChanges() throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let store = StayAwakeStore(defaults: defaults.defaults)
        store.selectDuration(.oneHour)
        store.setEnabled(true)
        defer { store.stop() }
        let expiry = try #require(store.expiresAt)

        store.selectMode(.keepDisplayAwake)
        #expect(store.isActive && store.expiresAt == expiry)
        #expect(defaults.defaults.string(forKey: DefaultsKey.stayAwakeMode) == StayAwakeMode.keepDisplayAwake.rawValue)

        store.selectDuration(.twoHours)
        let restarted = try #require(store.expiresAt)
        #expect(restarted.timeIntervalSince(expiry) > 3_000)
    }

    @Test("An indefinite session is restored at launch")
    func restoresIndefiniteSession() throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        defaults.defaults.set(true, forKey: DefaultsKey.stayAwakeEnabled)
        defaults.defaults.set(StayAwakeDuration.indefinitely.rawValue, forKey: DefaultsKey.stayAwakeDuration)

        let store = StayAwakeStore(defaults: defaults.defaults)
        store.start()
        defer { store.stop() }

        #expect(store.isActive && store.expiresAt == nil)
        #expect(store.selectedDuration == .indefinitely)
    }

    @Test("An expired session is not restored at launch")
    func expiredSessionIsNotRestored() throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        defaults.defaults.set(true, forKey: DefaultsKey.stayAwakeEnabled)
        defaults.defaults.set(StayAwakeDuration.oneHour.rawValue, forKey: DefaultsKey.stayAwakeDuration)
        defaults.defaults.set(Date().addingTimeInterval(-60), forKey: DefaultsKey.stayAwakeExpiration)

        let store = StayAwakeStore(defaults: defaults.defaults)
        store.start()

        #expect(!store.isActive)
        #expect(!defaults.defaults.bool(forKey: DefaultsKey.stayAwakeEnabled))
    }

    @Test("A restored session ends itself at its expiry")
    func sessionExpires() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        defaults.defaults.set(true, forKey: DefaultsKey.stayAwakeEnabled)
        defaults.defaults.set(StayAwakeDuration.fiveMinutes.rawValue, forKey: DefaultsKey.stayAwakeDuration)
        defaults.defaults.set(Date().addingTimeInterval(0.3), forKey: DefaultsKey.stayAwakeExpiration)

        let store = StayAwakeStore(defaults: defaults.defaults)
        store.start()
        #expect(store.isActive)

        try await waitUntil("the session expires") { !store.isActive }
        #expect(store.expiresAt == nil)
        #expect(!defaults.defaults.bool(forKey: DefaultsKey.stayAwakeEnabled))
    }
}

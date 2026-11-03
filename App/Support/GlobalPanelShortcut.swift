import AppKit
import Carbon
import Observation

/// Carbon's registered hot-key API avoids an event tap or accessibility access.
@MainActor @Observable
final class GlobalPanelShortcut {
    private(set) var registered = false
    private(set) var conflict = false
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    func configure(enabled: Bool) {
        guard enabled != registered else { return }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        registered = false
        conflict = false
        guard enabled else { return }
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == OSType(0x51554f54), identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalPanelShortcut>.fromOpaque(context).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &specification, context, &eventHandler)
        guard handlerStatus == noErr else {
            conflict = true
            return
        }
        let identifier = EventHotKeyID(signature: OSType(0x51554f54), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Q), UInt32(controlKey | optionKey), identifier,
            GetApplicationEventTarget(), 0, &hotKey)
        registered = status == noErr
        conflict = !registered
        if !registered, let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

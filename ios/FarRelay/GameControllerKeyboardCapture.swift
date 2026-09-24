import Foundation
import GameController

/// Lifecycle owner for the public GameController keyboard API. It is additive
/// to UIKit: it listens only for F1–F12, and CaptureView deduplicates any
/// transition also delivered by UIKit or UIKeyCommand.
@MainActor
final class GameControllerKeyboardCapture {
    private weak var owner: CaptureView?
    private var notificationTokens: [NSObjectProtocol] = []
    private weak var installedKeyboard: GCKeyboard?
    private var functionKeyState = GameControllerFunctionKeyState()

    init(owner: CaptureView) {
        self.owner = owner
    }

    func start() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // NotificationCenter's closure is not actor-isolated. Read
                // the coalesced keyboard after hopping to MainActor instead
                // of transferring its non-Sendable notification object.
                Task { @MainActor in self?.installCurrentKeyboard() }
            },
            center.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleDisconnect() }
            }
        ]
        if let keyboard = GCKeyboard.coalesced {
            install(keyboard)
        } else {
            // Some iOS hardware-keyboard combinations never surface through
            // GCKeyboard even though UIKit continues to deliver raw presses.
            // Report that explicitly so a device diagnostic can distinguish a
            // missing fallback source from an F-key mapping/transport failure.
            owner?.gameControllerKeyboardUnavailable()
        }
    }

    private func installCurrentKeyboard() {
        if let keyboard = GCKeyboard.coalesced {
            install(keyboard)
        } else {
            owner?.gameControllerKeyboardUnavailable()
        }
    }

    func stop() {
        installedKeyboard?.keyboardInput?.keyChangedHandler = nil
        installedKeyboard = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        releaseActiveFunctionKeys(reportDisconnect: false)
    }

    private func install(_ keyboard: GCKeyboard) {
        guard installedKeyboard !== keyboard else { return }
        installedKeyboard?.keyboardInput?.keyChangedHandler = nil
        installedKeyboard = keyboard
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] input, _, keyCode, pressed in
            let virtualKey = GameControllerFunctionKeyMapping.virtualKey(for: keyCode)
            let modifiers = GameControllerFunctionKeyMapping.modifiers(from: input)
            let rawCode = Int(keyCode.rawValue)
            Task { @MainActor in
                self?.receive(
                    rawCode: rawCode,
                    virtualKey: virtualKey,
                    pressed: pressed,
                    modifiers: modifiers
                )
            }
        }
        owner?.gameControllerKeyboardConnected()
    }

    private func receive(
        rawCode: Int,
        virtualKey: UInt16?,
        pressed: Bool,
        modifiers: [UInt16]
    ) {
        owner?.observeGameControllerKeyboardEvent(
            rawCode: rawCode,
            virtualKey: virtualKey,
            pressed: pressed,
            modifiers: modifiers
        )
        guard let virtualKey else { return }
        functionKeyState.receive(virtualKey: virtualKey, pressed: pressed)
        owner?.receiveGameControllerFunctionKey(
            vk: virtualKey,
            pressed: pressed,
            modifiers: modifiers
        )
    }

    private func handleDisconnect() {
        installedKeyboard?.keyboardInput?.keyChangedHandler = nil
        installedKeyboard = nil
        releaseActiveFunctionKeys(reportDisconnect: true)
    }

    private func releaseActiveFunctionKeys(reportDisconnect: Bool) {
        let keys = functionKeyState.releaseAllOnDisconnect()
        if reportDisconnect {
            owner?.gameControllerKeyboardDisconnected(releasing: keys)
        } else if !keys.isEmpty {
            owner?.gameControllerKeyboardDisconnected(releasing: keys)
        }
    }
}

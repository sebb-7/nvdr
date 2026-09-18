import Foundation
import Observation

/// App-side endpoint of the provider handoff. It intentionally keeps speech
/// in memory only; UI and diagnostics consume metadata rather than content.
@MainActor
@Observable
final class RemoteSpeechInbox {
    private(set) var pendingEvents: [RemoteSpeechEvent] = []
    private(set) var receivedEventCount = 0
    private(set) var lastSequence: UInt64?
    private(set) var lastReceivedAt: Date?
    private(set) var ssmlReceived = false

    @ObservationIgnored private let ipc: RemoteSpeechIPC?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored var onEvents: (@MainActor ([RemoteSpeechEvent]) -> Void)?

    init(ipc: RemoteSpeechIPC? = RemoteSpeechIPC()) {
        self.ipc = ipc
    }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: RemoteSpeechIPC.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drain()
            }
        }
        drain()
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
        pendingEvents.removeAll()
    }

    /// Future local proxy sessions consume this FIFO in order. Bounding it
    /// prevents a disconnected controller from retaining sensitive stale text.
    func takePendingEvents() -> [RemoteSpeechEvent] {
        let events = pendingEvents
        pendingEvents.removeAll()
        return events
    }

    private func drain() {
        guard let ipc else { return }
        let events = ipc.drain()
        guard !events.isEmpty else { return }
        pendingEvents.append(contentsOf: events)
        if pendingEvents.count > RemoteSpeechIPC.maximumQueuedEvents {
            pendingEvents.removeFirst(pendingEvents.count - RemoteSpeechIPC.maximumQueuedEvents)
        }
        receivedEventCount += events.count
        lastSequence = events.last?.sequence
        lastReceivedAt = Date()
        ssmlReceived = ssmlReceived || events.contains { $0.ssml != nil }
        onEvents?(events)
    }
}

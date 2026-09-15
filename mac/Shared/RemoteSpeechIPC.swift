import Foundation

/// A bounded, same-user app-group handoff for the speech provider extension.
///
/// The extension is prohibited from networking by Apple's provider contract.
/// This store is therefore only a short-lived local handoff to FarRelay.app:
/// it never listens on a socket, never polls, and removes each item when the
/// app drains it. The distributed notification contains no speech content; it
/// merely wakes the containing app to drain its group-protected queue.
struct RemoteSpeechIPC {
    static let appGroupIdentifier = "group.com.sebb7.farrelay"
    static let notificationName = Notification.Name("com.sebb7.farrelay.remoteSpeechAvailable")
    static let maximumQueuedEvents = 64

    private let queueURL: URL

    init?(fileManager: FileManager = .default) {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return nil
        }
        self.init(queueURL: container.appending(path: "remote-speech-events.json"))
    }

    init(queueURL: URL) {
        self.queueURL = queueURL
    }

    /// Adds an event to the end of a small FIFO. When overloaded, the oldest
    /// output is removed: stale screen-reader feedback is less useful than the
    /// current context. The caller must only expose counts/metadata in logs.
    @discardableResult
    func append(_ event: RemoteSpeechEvent) -> Bool {
        var writeError: NSError?
        var wrote = false
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: queueURL, options: .forMerging, error: &writeError) { url in
            var events = Self.readEvents(from: url)
            events.append(event)
            if events.count > Self.maximumQueuedEvents {
                events.removeFirst(events.count - Self.maximumQueuedEvents)
            }
            wrote = Self.write(events, to: url)
        }
        guard writeError == nil, wrote else { return false }
        DistributedNotificationCenter.default().post(
            name: Self.notificationName,
            object: nil,
            userInfo: nil
        )
        return true
    }

    /// Atomically removes and returns queued output. No periodic polling is
    /// used; FarRelay.app calls this at launch and upon the notification above.
    func drain() -> [RemoteSpeechEvent] {
        var readError: NSError?
        var events: [RemoteSpeechEvent] = []
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: queueURL, options: .forMerging, error: &readError) { url in
            events = Self.readEvents(from: url)
            _ = Self.write([], to: url)
        }
        return readError == nil ? events : []
    }

    private static func readEvents(from url: URL) -> [RemoteSpeechEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RemoteSpeechEvent].self, from: data)) ?? []
    }

    private static func write(_ events: [RemoteSpeechEvent], to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(events) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}

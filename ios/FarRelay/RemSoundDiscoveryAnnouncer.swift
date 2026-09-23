import Foundation
import Network

/// Best-effort compatibility presence for the desktop RemSound peer list.
///
/// RemSound LAN broadcasts do not need to reach iOS for this to work. FarRelay
/// already knows the saved Windows peer address, so it sends the standard JSON
/// announcement directly to that peer on UDP 47821. Current RemSound records
/// the datagram's source address and automatically adds it to its own unicast
/// discovery targets, making the exchange bidirectional on LAN and Tailscale.
/// Discovery failure never tears down audio or FarRelay control.
@MainActor
final class RemSoundDiscoveryAnnouncer {
    private let queue = DispatchQueue(label: "com.sebb7.farrelay.remsound.discovery")
    private let instanceID = UUID()
    private var connection: NWConnection?
    private var announceTask: Task<Void, Never>?
    private var payload: Data?
    private var lastConfiguration: (host: String, audioPort: UInt16)?

    func start(peerHost: String, audioPort: UInt16) {
        stop(clearConfiguration: false)

        let host = peerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              let discoveryPort = NWEndpoint.Port(rawValue: RemSoundDiscovery.defaultPort)
        else { return }

        let announcement = RemSoundDiscoveryAnnouncement(
            instanceID: instanceID,
            name: "FarRelay iOS",
            audioPort: Int(audioPort),
            canSend: false,
            canReceive: true
        )
        guard let encoded = try? announcement.encoded() else { return }

        lastConfiguration = (host, audioPort)
        payload = encoded
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: discoveryPort,
            using: .udp
        )
        self.connection = connection
        connection.start(queue: queue)
        sendAnnouncement()

        announceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: RemSoundDiscovery.announcementInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.sendAnnouncement()
            }
        }
    }

    func reconnect() {
        guard let lastConfiguration else { return }
        start(peerHost: lastConfiguration.host, audioPort: lastConfiguration.audioPort)
    }

    func stop() {
        stop(clearConfiguration: true)
    }

    private func stop(clearConfiguration: Bool) {
        announceTask?.cancel()
        announceTask = nil
        connection?.cancel()
        connection = nil
        payload = nil
        if clearConfiguration { lastConfiguration = nil }
    }

    private func sendAnnouncement() {
        guard let connection, let payload else { return }
        connection.send(content: payload, completion: .contentProcessed { _ in
            // Discovery is convenience. The audio UDP listener remains the
            // source of truth and must stay independent of discovery errors.
        })
    }
}

import Foundation
import Network

struct RemSoundDiscoveryDiagnostics: Equatable, Sendable {
    var isActive = false
    var target: String?
    var announcementsAttempted = 0
    var announcementsCompleted = 0
    var announcementFailures = 0
    var lastError: String?
}

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
    private(set) var diagnostics = RemSoundDiscoveryDiagnostics()
    var onDiagnosticsChanged: ((RemSoundDiscoveryDiagnostics) -> Void)?

    func start(peerHost: String, audioPort: UInt16) {
        stop(clearConfiguration: false)

        let host = peerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              let discoveryPort = NWEndpoint.Port(rawValue: RemSoundDiscovery.defaultPort)
        else {
            diagnostics.lastError = "A Windows RemSound address is required for discovery."
            publishDiagnostics()
            return
        }

        let announcement = RemSoundDiscoveryAnnouncement(
            instanceID: instanceID,
            name: "FarRelay iOS",
            audioPort: Int(audioPort),
            canSend: false,
            canReceive: true
        )
        guard let encoded = try? announcement.encoded() else {
            diagnostics.lastError = "FarRelay could not encode the RemSound discovery announcement."
            publishDiagnostics()
            return
        }

        lastConfiguration = (host, audioPort)
        payload = encoded
        diagnostics = RemSoundDiscoveryDiagnostics(
            isActive: true,
            target: "\(host):\(RemSoundDiscovery.defaultPort)"
        )
        publishDiagnostics()

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
        diagnostics.isActive = false
        publishDiagnostics()
        if clearConfiguration { lastConfiguration = nil }
    }

    private func sendAnnouncement() {
        guard let connection, let payload else { return }
        diagnostics.announcementsAttempted += 1
        publishDiagnostics()
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.diagnostics.announcementFailures += 1
                    self.diagnostics.lastError = "Discovery send failed: \(error.localizedDescription)"
                } else {
                    // UDP completion means the local network stack accepted the
                    // datagram; it is not an acknowledgement from Windows.
                    self.diagnostics.announcementsCompleted += 1
                }
                self.publishDiagnostics()
            }
        })
    }

    private func publishDiagnostics() {
        onDiagnosticsChanged?(diagnostics)
    }
}

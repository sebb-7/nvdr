import Foundation
import Observation

/// The host-recovery command adapter. It opens the independent authenticated
/// SSH + farrelay-host path and never relies on the NVDA relay or active target.
@Observable @MainActor
final class HostRecoverySession: HostRecoveryIntentControlling {
    private(set) var recoveryProfile: HostProfile?
    private var credentials: HostProfileCredentials?

    var recoveryConnectionState: HostTarget.ConnectionState {
        guard let recoveryProfile else { return .disconnected }
        return recoveryProfile.platform == .windows
            ? .ready
            : .unavailable("Accessibility recovery is not implemented for this platform.")
    }

    var supportsAccessibilityRecovery: Bool { recoveryProfile?.platform == .windows }

    func configure(profile: HostProfile, credentials: HostProfileCredentials?) {
        recoveryProfile = profile
        self.credentials = credentials
    }

    func status() async throws -> NvdaRecoveryStatus {
        guard let profile = recoveryProfile, profile.platform == .windows else {
            throw HostClientError.hostError(code: "unsupported_platform", message: "Accessibility recovery is not available on this platform.")
        }
        return try await withClient(for: profile) { client in
            try await client.nvdaRecoveryStatus()
        }
    }

    func restartAccessibility() async -> RemoteIntentResult {
        guard let profile = recoveryProfile, profile.platform == .windows else { return .unsupported }
        do {
            let result: NvdaRestartResult = try await withClient(for: profile) { client in
                try await client.restartNvda()
            }
            return result.taskStarted ? .performed : .failed("The accessibility restart request was not accepted.")
        } catch let error as HostClientError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func hostCommand(for profile: HostProfile) throws -> String {
        let command = profile.farRelayHostCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw HostClientError.hostError(
                code: "invalid_host_command",
                message: "The FarRelay Host command is empty."
            )
        }
        guard command.rangeOfCharacter(from: .newlines) == nil, !command.contains("\0") else {
            throw HostClientError.hostError(
                code: "invalid_host_command",
                message: "The FarRelay Host command contains invalid control characters."
            )
        }
        return command
    }

    private func withClient<Result: Sendable>(
        for profile: HostProfile,
        operation: @escaping @Sendable (FarRelayHostClient) async throws -> Result
    ) async throws -> Result {
        guard let credentials else {
            throw HostClientError.hostError(code: "credentials_unavailable", message: "Credentials for this host are unavailable.")
        }
        let command = try Self.hostCommand(for: profile)
        let session = SSHSession(configuration: profile.sshSessionConfiguration(credentials: credentials))
        do {
            try await session.connect()
            let result = try await FarRelayHostConnection.withClient(
                session: session,
                command: command,
                operation: operation
            )
            try await session.close()
            return result
        } catch {
            try? await session.close()
            throw error
        }
    }
}

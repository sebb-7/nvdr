import Foundation

enum UserFacingIssueSeverity: Equatable, Sendable {
    case error
}

enum UserFacingIssueRetry: Equatable, Sendable {
    case terminal(UUID)
    case nvda
}

/// A user-visible, VoiceOver-readable issue for a final failed action.
///
/// This is presentation-layer state, not an SSH or NVDA transport object.
struct UserFacingIssue: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let diagnosticText: String
    let severity: UserFacingIssueSeverity
    let retry: UserFacingIssueRetry?

    init(
        id: UUID = UUID(),
        title: String,
        message: String,
        diagnosticText: String,
        severity: UserFacingIssueSeverity = .error,
        retry: UserFacingIssueRetry? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.diagnosticText = diagnosticText
        self.severity = severity
        self.retry = retry
    }
}

enum RemoteLaunchDiagnostics {
    static func looksLikeMissingExecutable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.localizedStandardContains("command not found")
            || lower.localizedStandardContains("no such file")
            || lower.localizedStandardContains("not an executable")
    }

    static func executableName(from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else {
            return trimmed
        }
        return String(first)
    }

    static func nvdaMissingCommandIssue(
        computerName: String,
        command: String,
        diagnosticText: String
    ) -> UserFacingIssue {
        let executable = executableName(from: command)
        return UserFacingIssue(
            title: "Unable to connect to \(computerName)",
            message: "The NVDA bridge command \"\(executable)\" could not be started on \(computerName).",
            diagnosticText: redact(diagnosticText),
            retry: .nvda
        )
    }

    static func nvdaFailureIssue(
        computerName: String,
        reason: String,
        diagnosticText: String,
        command: String = "farrelay"
    ) -> UserFacingIssue {
        if looksLikeMissingExecutable(reason) || looksLikeMissingExecutable(diagnosticText) {
            return nvdaMissingCommandIssue(
                computerName: computerName,
                command: command,
                diagnosticText: diagnosticText
            )
        }
        return UserFacingIssue(
            title: "Unable to connect to \(computerName)",
            message: "NVDA Remote could not be started. \(sanitizedReason(reason))",
            diagnosticText: redact(diagnosticText),
            retry: .nvda
        )
    }

    static func hostProtocolMissingCommandIssue(
        computerName: String,
        diagnosticText: String,
        sessionID: UUID
    ) -> UserFacingIssue {
        UserFacingIssue(
            title: "Unable to connect to \(computerName)",
            message: "farrelay-host could not be started on \(computerName).",
            diagnosticText: redact(diagnosticText),
            retry: .terminal(sessionID)
        )
    }

    static func terminalFailureIssue(
        computerName: String,
        reason: String,
        diagnosticText: String,
        sessionID: UUID
    ) -> UserFacingIssue {
        if looksLikeHostProtocolFailure(reason) || looksLikeHostProtocolFailure(diagnosticText) {
            return hostProtocolMissingCommandIssue(
                computerName: computerName,
                diagnosticText: diagnosticText,
                sessionID: sessionID
            )
        }
        let message: String
        if looksLikeAuthenticationFailure(reason) {
            message = "SSH authentication failed. Check this computer's saved key or password."
        } else if looksLikeMissingExecutable(reason) || looksLikeMissingExecutable(diagnosticText) {
            message = "The remote shell could not be started on \(computerName)."
        } else {
            message = sanitizedReason(reason)
        }
        return UserFacingIssue(
            title: "Unable to connect to \(computerName)",
            message: message,
            diagnosticText: redact(diagnosticText),
            retry: .terminal(sessionID)
        )
    }

    static func looksLikeAuthenticationFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.localizedStandardContains("auth")
            || lower.localizedStandardContains("password")
            || lower.localizedStandardContains("publickey")
    }

    static func looksLikeHostProtocolFailure(_ text: String) -> Bool {
        text.localizedStandardContains("farrelay-host") && looksLikeMissingExecutable(text)
    }

    static func sanitizedReason(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || looksLikeOpaqueCode(trimmed) || looksLikeGenericErrorCode(trimmed) {
            return "The connection failed. Check this computer's address, network, and credentials."
        }
        return redact(trimmed)
    }

    static func redact(_ text: String) -> String {
        var redacted = redactFlag(text, flag: "--channel")
        redacted = redactFlag(redacted, flag: "--password")
        let secretMarkers = ["BEGIN OPENSSH PRIVATE KEY", "BEGIN RSA PRIVATE KEY", "BEGIN PRIVATE KEY"]
        for marker in secretMarkers where redacted.localizedStandardContains(marker) {
            return "Private key material omitted."
        }
        return redacted
    }

    static func diagnosticText(
        computerName: String,
        address: String,
        port: Int,
        username: String,
        reason: String,
        logLines: [String] = []
    ) -> String {
        var lines = [
            "Computer: \(computerName)",
            "Address: \(username)@\(address):\(port)",
            "Reason: \(redact(reason))",
        ]
        let redactedLog = logLines.suffix(20).map(redact)
        if !redactedLog.isEmpty {
            lines.append("Log:")
            lines.append(contentsOf: redactedLog)
        }
        return lines.joined(separator: "\n")
    }

    private static func looksLikeOpaqueCode(_ text: String) -> Bool {
        let stripped = text.replacing("-", with: "")
        return !stripped.isEmpty && stripped.allSatisfy(\.isNumber)
    }

    private static func looksLikeGenericErrorCode(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.hasPrefix("error") else { return false }
        let rest = String(text.drop(while: { !$0.isNumber && $0 != "-" }))
        return looksLikeOpaqueCode(rest)
    }

    private static func redactFlag(_ text: String, flag: String) -> String {
        guard let range = text.range(of: flag) else { return text }
        let afterFlag = text[range.upperBound...].drop(while: \.isWhitespace)
        guard let valueEnd = afterFlag.firstIndex(where: \.isWhitespace) else {
            return String(text[..<range.lowerBound]) + "\(flag) •••"
        }
        return String(text[..<range.lowerBound]) + "\(flag) •••" + String(text[valueEnd...])
    }
}

enum HostProfileDeletionPolicy {
    static func confirmationMessage(computerName: String, activeTerminalCount: Int) -> String {
        if activeTerminalCount == 0 {
            return "This removes \(computerName) from Home."
        }
        let noun = activeTerminalCount == 1 ? "terminal" : "terminals"
        return "\(activeTerminalCount) active \(noun) will remain open, but this computer will be removed from Home."
    }
}

import Foundation

/// Transport-neutral output produced by the target screen reader.
///
/// This deliberately keeps AVFoundation objects and the extension process out
/// of the eventual SSH/local-proxy protocol. Content stays ephemeral: callers
/// must not log either `ssml` or `plainText`.
enum RemoteSpeechEventKind: String, Codable, Equatable, Sendable {
    case utterance
    case cancel
    case pause
    case resume
}

struct RemoteSpeechEvent: Codable, Equatable, Sendable, Identifiable {
    static let maximumPayloadBytes = 32 * 1024

    let generation: UUID
    let sequence: UInt64
    let kind: RemoteSpeechEventKind
    let ssml: String?
    let plainText: String?
    let language: String?
    let timestamp: Date

    var id: String { "\(generation.uuidString)-\(sequence)" }

    init?(
        generation: UUID,
        sequence: UInt64,
        kind: RemoteSpeechEventKind,
        ssml: String? = nil,
        plainText: String? = nil,
        language: String? = nil,
        timestamp: Date = .now
    ) {
        guard Self.payloadBytes(ssml: ssml, plainText: plainText) <= Self.maximumPayloadBytes else {
            return nil
        }
        guard kind != .utterance || ssml != nil || plainText != nil else {
            return nil
        }
        guard kind == .utterance || (ssml == nil && plainText == nil && language == nil) else {
            return nil
        }
        self.generation = generation
        self.sequence = sequence
        self.kind = kind
        self.ssml = ssml
        self.plainText = plainText
        self.language = language
        self.timestamp = timestamp
    }

    private static func payloadBytes(ssml: String?, plainText: String?) -> Int {
        (ssml?.utf8.count ?? 0) + (plainText?.utf8.count ?? 0)
    }
}

/// Monotonically creates per-extension speech events. A fresh extension
/// process receives a fresh generation, so stale events are distinguishable by
/// the containing app and, later, by remote controllers.
struct RemoteSpeechEventSequencer {
    private let generation = UUID()
    private var nextSequence: UInt64 = 0

    mutating func utterance(ssml: String, plainText: String? = nil) -> RemoteSpeechEvent? {
        nextSequence &+= 1
        if let event = RemoteSpeechEvent(
            generation: generation,
            sequence: nextSequence,
            kind: .utterance,
            ssml: ssml,
            plainText: plainText
        ) {
            return event
        }
        return RemoteSpeechEvent(
            generation: generation,
            sequence: nextSequence,
            kind: .utterance,
            ssml: ssml
        )
    }

    mutating func cancellation() -> RemoteSpeechEvent? {
        nextSequence &+= 1
        return RemoteSpeechEvent(generation: generation, sequence: nextSequence, kind: .cancel)
    }
}

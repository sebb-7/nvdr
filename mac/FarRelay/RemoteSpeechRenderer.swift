import AVFoundation
import Foundation

/// Pure session safety policy for controller-side speech. It rejects old
/// generations and sequence replays before AVFoundation sees any utterance.
struct RemoteSpeechPlaybackGate {
    enum Action: Equatable {
        case enqueue(RemoteSpeechEvent)
        case cancel
        case interruptAndEnqueue(RemoteSpeechEvent)
        case ignored
    }

    static let maximumQueuedUtterances = 8

    private var generation: UUID?
    private var lastSequence: UInt64 = 0
    private var queuedUtterances = 0

    mutating func begin(generation: UUID) {
        self.generation = generation
        lastSequence = 0
        queuedUtterances = 0
    }

    mutating func end() {
        generation = nil
        lastSequence = 0
        queuedUtterances = 0
    }

    mutating func receive(_ event: RemoteSpeechEvent) -> Action {
        guard generation == event.generation, event.sequence > lastSequence else {
            return .ignored
        }
        lastSequence = event.sequence
        switch event.kind {
        case .cancel:
            queuedUtterances = 0
            return .cancel
        case .pause, .resume:
            // AVSpeechSynthesizer has no reliable cross-platform mapping for
            // target VoiceOver pause/resume. Preserve the protocol event but
            // do not pretend to reproduce it until physically validated.
            return .ignored
        case .utterance:
            if queuedUtterances >= Self.maximumQueuedUtterances {
                queuedUtterances = 1
                return .interruptAndEnqueue(event)
            }
            queuedUtterances += 1
            return .enqueue(event)
        }
    }
}

/// Local rendering endpoint for semantic remote speech. It never chooses the
/// FarRelay provider voice, which makes controller synthesis unable to recurse
/// into a local target's provider extension.
actor RemoteSpeechRenderer {
    private let synthesizer = AVSpeechSynthesizer()
    private var gate = RemoteSpeechPlaybackGate()

    func begin(generation: UUID) {
        synthesizer.stopSpeaking(at: .immediate)
        gate.begin(generation: generation)
    }

    func end() {
        synthesizer.stopSpeaking(at: .immediate)
        gate.end()
    }

    func receive(_ event: RemoteSpeechEvent) {
        switch gate.receive(event) {
        case .ignored:
            return
        case .cancel:
            synthesizer.stopSpeaking(at: .immediate)
        case .interruptAndEnqueue(let event):
            synthesizer.stopSpeaking(at: .immediate)
            speak(event)
        case .enqueue(let event):
            speak(event)
        }
    }

    private func speak(_ event: RemoteSpeechEvent) {
        let utterance: AVSpeechUtterance?
        if let ssml = event.ssml, let ssmlUtterance = AVSpeechUtterance(ssmlRepresentation: ssml) {
            utterance = ssmlUtterance
        } else if let plainText = event.plainText, !plainText.isEmpty {
            let plainUtterance = AVSpeechUtterance(string: plainText)
            plainUtterance.voice = Self.nonProviderVoice(language: event.language)
            utterance = plainUtterance
        } else {
            utterance = nil
        }
        if let utterance {
            synthesizer.speak(utterance)
        }
    }

    private static func nonProviderVoice(language: String?) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.identifier != "com.sebb7.farrelay.remote-voice"
        }
        if let language, let matchingVoice = voices.first(where: { $0.language == language }) {
            return matchingVoice
        }
        return voices.first(where: { $0.language == AVSpeechSynthesisVoice.currentLanguageCode() })
            ?? voices.first
    }
}

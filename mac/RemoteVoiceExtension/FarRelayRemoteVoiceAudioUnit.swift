import AudioToolbox
import AVFAudio
import Darwin
import Foundation

/// A public Speech Synthesis Provider spike.
///
/// Selecting this voice deliberately makes the target silent while the
/// extension sends VoiceOver's final SSML request to FarRelay.app through the
/// app group. The controller, not the target, renders that output. This class
/// performs no network I/O; Apple explicitly forbids it in speech providers.
final class FarRelayRemoteVoiceAudioUnit: AVSpeechSynthesisProviderAudioUnit {
    private static let voiceIdentifier = "com.sebb7.farrelay.remote-voice"
    private var sequencer = RemoteSpeechEventSequencer()
    private var hasActiveRequest = false

    override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            [
                AVSpeechSynthesisProviderVoice(
                    name: "FarRelay Remote Voice",
                    identifier: Self.voiceIdentifier,
                    primaryLanguages: ["en-US"],
                    supportedLanguages: ["en-US"]
                ),
            ]
        }
        set {}
    }

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { actionFlags, _, _, _, outputData, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            actionFlags.pointee.insert(.offlineUnitRenderAction_Complete)
            return noErr
        }
    }

    override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        hasActiveRequest = true
        // Apple exposes the final SSML representation, but not a separate
        // plain-text/language field. Preserve only what the public API gives.
        let ssml = speechRequest.ssmlRepresentation
        let plainText = RemoteSpeechPlainTextExtractor.extract(from: ssml)
        // Construct through the sequencer so every provider process has one
        // stable generation. Retain derived text only when it still fits the
        // bounded handoff; SSML remains the authoritative representation.
        if let event = sequencer.utterance(ssml: ssml, plainText: plainText) {
            _ = RemoteSpeechIPC()?.append(event)
        }
    }

    override func cancelSpeechRequest() {
        guard hasActiveRequest else { return }
        hasActiveRequest = false
        if let event = sequencer.cancellation() {
            _ = RemoteSpeechIPC()?.append(event)
        }
    }
}

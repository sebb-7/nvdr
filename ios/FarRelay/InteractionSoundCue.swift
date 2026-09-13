import AudioToolbox
import Foundation

/// Short, locally generated, non-speech earcons.
///
/// Playback uses AudioServices UI sounds so FarRelay never takes over the
/// shared audio session, ducks VoiceOver, or interrupts `SpeechOutput`.
/// Cues respect the Silent switch. They are not spoken words and do not
/// load network or third-party audio.
enum InteractionSoundCue {
    @MainActor
    private static var registeredIDs: [InteractionFeedbackKind: SystemSoundID] = [:]

    @MainActor
    static func play(_ kind: InteractionFeedbackKind) {
        AudioServicesPlaySystemSound(soundID(for: kind))
    }

    @MainActor
    private static func soundID(for kind: InteractionFeedbackKind) -> SystemSoundID {
        let canonical = canonicalKind(kind)
        if let existing = registeredIDs[canonical] {
            return existing
        }
        let spec = tone(for: canonical)
        guard let url = writeWAV(frequency: spec.frequency, duration: spec.duration) else {
            return 0
        }
        var soundID: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == kAudioServicesNoError else {
            return 0
        }
        var isUISound: UInt32 = 1
        AudioServicesSetProperty(
            kAudioServicesPropertyIsUISound,
            UInt32(MemoryLayout.size(ofValue: soundID)),
            &soundID,
            UInt32(MemoryLayout.size(ofValue: isUISound)),
            &isUISound
        )
        registeredIDs[canonical] = soundID
        return soundID
    }

    private static func canonicalKind(_ kind: InteractionFeedbackKind) -> InteractionFeedbackKind {
        switch kind {
        case .copied:
            .success
        case .warning:
            .selectionAccepted
        default:
            kind
        }
    }

    private static func tone(for kind: InteractionFeedbackKind) -> (frequency: Double, duration: Double) {
        switch kind {
        case .selectionAccepted, .warning:
            (880, 0.04)
        case .success, .copied:
            (1_174, 0.07)
        case .error:
            (277, 0.10)
        }
    }

    private static func writeWAV(frequency: Double, duration: Double) -> URL? {
        let sampleRate = 8_000
        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        var samples = [Int16](repeating: 0, count: sampleCount)
        let fade = min(40, sampleCount / 4)
        for index in 0..<sampleCount {
            let envelope: Double
            if index < fade {
                envelope = Double(index) / Double(max(fade, 1))
            } else if index > sampleCount - fade {
                envelope = Double(sampleCount - index) / Double(max(fade, 1))
            } else {
                envelope = 1
            }
            let sample = sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate))
            samples[index] = Int16((sample * envelope * 0.28 * Double(Int16.max)).rounded())
        }

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        let dataSize = sampleCount * 2
        let fileSize = 36 + dataSize
        data.append(contentsOf: UInt32(fileSize).littleEndianBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        data.append(contentsOf: UInt32(sampleRate * 2).littleEndianBytes)
        data.append(contentsOf: UInt16(2).littleEndianBytes)
        data.append(contentsOf: UInt16(16).littleEndianBytes)
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: UInt32(dataSize).littleEndianBytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "farrelay-cue-\(Int(frequency))-\(Int(duration * 1000)).wav")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: littleEndian), UInt8(truncatingIfNeeded: littleEndian >> 8)]
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [
            UInt8(truncatingIfNeeded: littleEndian),
            UInt8(truncatingIfNeeded: littleEndian >> 8),
            UInt8(truncatingIfNeeded: littleEndian >> 16),
            UInt8(truncatingIfNeeded: littleEndian >> 24),
        ]
    }
}

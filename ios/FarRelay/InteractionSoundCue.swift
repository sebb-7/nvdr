import AudioToolbox
import Foundation

/// Bundled app cues use UI sounds and never reconfigure the shared audio
/// session. Runtime synthesis is reserved for actual NVDA `tone` events.
@MainActor
enum InteractionSoundCue {
    private static var bundledIDs: [String: SystemSoundID] = [:]
    private static var toneIDs: [RemoteNVDATone: SystemSoundID] = [:]

    static func play(_ intent: InteractionSoundIntent) { playBundled(filename: intent.filename) }

    /// Plays one of FarRelay's bundled WAV resources. Preference UI and
    /// app-owned semantic feedback use this path; remote NVDA waves remain a
    /// separate protocol-driven path below.
    static func playBundled(filename: String) {
        guard AppSoundCatalog.contains(filename: filename),
              let url = SoundResourceResolver.bundledURL(for: filename) else { return }
        play(url: url, key: filename.lowercased(), cache: &bundledIDs)
    }

    static func playRemoteWave(filename: String) {
        guard let url = SoundResourceResolver.bundledURL(for: filename) else { return }
        play(url: url, key: url.lastPathComponent.lowercased(), cache: &bundledIDs)
    }

    static func playRemoteTone(_ tone: RemoteNVDATone) {
        if let identifier = toneIDs[tone] { AudioServicesPlaySystemSound(identifier); return }
        guard let url = RemoteNVDAToneWAV.url(for: tone) else { return }
        play(url: url, key: tone, cache: &toneIDs)
    }

    private static func play<Key: Hashable>(url: URL, key: Key, cache: inout [Key: SystemSoundID]) {
        if let identifier = cache[key] { AudioServicesPlaySystemSound(identifier); return }
        var identifier: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &identifier) == kAudioServicesNoError else { return }
        var isUISound: UInt32 = 1
        AudioServicesSetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout.size(ofValue: identifier)), &identifier, UInt32(MemoryLayout.size(ofValue: isUISound)), &isUISound)
        cache[key] = identifier
        AudioServicesPlaySystemSound(identifier)
    }
}

private enum RemoteNVDAToneWAV {
    static func url(for tone: RemoteNVDATone) -> URL? {
        let sampleRate = 8_000
        let count = min(40_000, max(1, sampleRate * tone.durationMilliseconds / 1_000))
        let leftLevel = Double(tone.leftLevel) / 100
        let rightLevel = Double(tone.rightLevel) / 100
        var data = Data("RIFF".utf8)
        let dataSize = count * 4
        data.append(UInt32(36 + dataSize).littleEndianData)
        data.append(Data("WAVEfmt ".utf8))
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(2).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(sampleRate * 4).littleEndianData)
        data.append(UInt16(4).littleEndianData)
        data.append(UInt16(16).littleEndianData)
        data.append(Data("data".utf8))
        data.append(UInt32(dataSize).littleEndianData)
        let fade = min(40, count / 4)
        for index in 0..<count {
            let envelope = index < fade ? Double(index) / Double(max(fade, 1)) : (index > count - fade ? Double(count - index) / Double(max(fade, 1)) : 1)
            let sample = sin(2 * .pi * Double(tone.frequency) * Double(index) / Double(sampleRate))
            data.append(Int16((sample * envelope * leftLevel * 0.28 * Double(Int16.max)).rounded()).littleEndianData)
            data.append(Int16((sample * envelope * rightLevel * 0.28 * Double(Int16.max)).rounded()).littleEndianData)
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "farrelay-nvda-tone-\(tone.frequency)-\(tone.durationMilliseconds)-\(tone.leftLevel)-\(tone.rightLevel).wav")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data { withUnsafeBytes(of: self.littleEndian) { Data($0) } }
}

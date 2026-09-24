import Copus
import Foundation

/// Keeps wire-codec details out of the network receiver. Every successful
/// result is the renderer's 48 kHz interleaved stereo Float PCM contract.
final class RemSoundAudioDecoder {
    private let format: RemSoundFormat
    private let opus: RemSoundOpusDecoder?

    init?(format: RemSoundFormat) {
        self.format = format
        switch format.codec {
        case .pcm:
            opus = nil
        case .opus:
            guard let decoder = RemSoundOpusDecoder(format: format) else { return nil }
            opus = decoder
        }
    }

    func decode(_ plaintext: Data, fec: Bool = false) -> AudioPCMFrame? {
        switch format.codec {
        case .pcm:
            return RemSoundPCM24Decoder.decode(plaintext, format: format)
        case .opus:
            return opus?.decode(plaintext, fec: fec)
        }
    }

    func concealLostOpusFrame() -> AudioPCMFrame? {
        opus?.conceal()
    }
}

private enum RemSoundPCM24Decoder {
    static func decode(_ data: Data, format: RemSoundFormat) -> AudioPCMFrame? {
        guard data.count.isMultiple(of: 3) else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(data.count / 3)
        var index = data.startIndex
        while index < data.endIndex {
            let low = Int32(data[index])
            let middle = Int32(data[index + 1]) << 8
            let high = Int32(Int8(bitPattern: data[index + 2])) << 16
            samples.append(Float(low | middle | high) / 8_388_608)
            index += 3
        }
        return AudioPCMFrame(samples: samples, sampleRate: Double(format.sampleRate), channels: format.channels)
    }
}

/// Thin ownership wrapper around one libopus decoder. `Copus` is used rather
/// than a platform converter because RemSound needs `decode_fec` and null-data
/// packet-loss concealment, neither exposed by `AudioConverter`.
private final class RemSoundOpusDecoder {
    private let sampleRate: Int
    private let channels: Int
    private let frameSize: Int
    private var decoder: OpaquePointer?
    private var shortScratch: [Int16]

    init?(format: RemSoundFormat) {
        sampleRate = format.sampleRate
        channels = format.channels
        frameSize = format.frameSamplesPerChannel
        shortScratch = [Int16](repeating: 0, count: frameSize * channels)
        var error: Int32 = 0
        decoder = opus_decoder_create(Int32(sampleRate), Int32(channels), &error)
        guard decoder != nil, error == OPUS_OK else { return nil }
    }

    deinit {
        if let decoder { opus_decoder_destroy(decoder) }
    }

    func decode(_ packet: Data, fec: Bool) -> AudioPCMFrame? {
        guard !packet.isEmpty, let decoded = decode(packet: packet, fec: fec), decoded > 0 else { return nil }
        return makeFrame(samplesPerChannel: decoded)
    }

    func conceal() -> AudioPCMFrame? {
        guard let decoder else { return nil }
        let decoded = shortScratch.withUnsafeMutableBufferPointer { output in
            opus_decode(decoder, nil, 0, output.baseAddress!, Int32(frameSize), 0)
        }
        guard decoded > 0 else { return nil }
        return makeFrame(samplesPerChannel: Int(decoded))
    }

    private func decode(packet: Data, fec: Bool) -> Int? {
        guard let decoder else { return nil }
        let decoded = packet.withUnsafeBytes { bytes in
            shortScratch.withUnsafeMutableBufferPointer { output in
                opus_decode(
                    decoder,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    Int32(packet.count),
                    output.baseAddress!,
                    Int32(frameSize),
                    fec ? 1 : 0
                )
            }
        }
        return decoded > 0 ? Int(decoded) : nil
    }

    private func makeFrame(samplesPerChannel: Int) -> AudioPCMFrame {
        let total = samplesPerChannel * channels
        let samples = shortScratch.prefix(total).map { Float($0) / 32_768 }
        return AudioPCMFrame(samples: samples, sampleRate: Double(sampleRate), channels: channels)
    }
}

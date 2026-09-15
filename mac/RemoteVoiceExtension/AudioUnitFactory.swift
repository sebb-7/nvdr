import AudioToolbox
import AVFAudio
import Foundation

final class AudioUnitFactory: NSObject, AUAudioUnitFactory {
    func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try FarRelayRemoteVoiceAudioUnit(componentDescription: componentDescription, options: [])
    }
}

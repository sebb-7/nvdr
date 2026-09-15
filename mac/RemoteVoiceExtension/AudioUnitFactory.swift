import AudioToolbox
import AVFAudio
import Foundation

final class AudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try FarRelayRemoteVoiceAudioUnit(componentDescription: componentDescription, options: [])
    }

    /// The Audio Unit is instantiated by the system through
    /// `AUAudioUnitFactory`; completing a generic extension request keeps the
    /// principal class valid for the app-extension product type as well.
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil)
    }
}

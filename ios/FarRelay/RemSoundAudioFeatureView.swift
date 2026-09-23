import SwiftUI

/// Minimal, accessible Phase 1 control surface. It intentionally has no
/// dependency on BridgeClient: audio can fail, stop, or restart while remote
/// control remains entirely available.
struct RemSoundAudioFeatureView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AudioReceiverModel.self) private var audioReceiver
    let profile: HostProfile
    @State private var password = ""

    var body: some View {
        Form {
            Section("Windows RemSound peer") {
                Text(senderDescription)
                Text("This is the Windows PC address, not the iPhone address. Start audio to announce FarRelay iOS directly to that RemSound app. Then select FarRelay iOS in RemSound's discovered peers and send PCM audio to it on UDP port \(port).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("RemSound does not use an interactive pairing request for this direct connection. Windows heartbeat proves reachability; the shared password is validated when its audio Format packet supplies the password fingerprint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Audio status") {
                Text(audioReceiver.compactStatusLabel)
                    .accessibilityLabel("RemSound status")
                    .accessibilityValue(audioReceiver.compactStatusLabel)
                if let error = audioReceiver.snapshot.statistics.lastError {
                    Text(error).foregroundStyle(.secondary)
                }
                Button(actionTitle, systemImage: actionSymbol) {
                    switch audioReceiver.snapshot.state {
                    case .idle, .stopped, .failed:
                        audioReceiver.start(host: host, port: port, password: password)
                    case .connecting, .authenticating, .waitingForAudio, .buffering, .playing, .reconnecting:
                        audioReceiver.stop()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Reconnect audio", systemImage: "arrow.clockwise") {
                    audioReceiver.reconnect()
                }
                .disabled(!canReconnect)
            }
            Section("Playback") {
                Toggle("Mute RemSound audio", isOn: Binding(
                    get: { audioReceiver.snapshot.muted },
                    set: { audioReceiver.setMuted($0) }
                ))
                Slider(
                    value: Binding(
                        get: { Double(audioReceiver.snapshot.volume) },
                        set: { audioReceiver.setVolume(Float($0)) }
                    ),
                    in: 0...1
                ) {
                    Text("Playback volume")
                }
                .accessibilityValue("\(Int(audioReceiver.snapshot.volume * 100)) percent")
                Text("Playback-only audio. FarRelay never captures the microphone in Phase 1.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Audio diagnostics") {
                Text("Discovery: \(audioReceiver.discoveryDiagnostics.isActive ? "active" : "inactive"), attempts \(audioReceiver.discoveryDiagnostics.announcementsAttempted), local completions \(audioReceiver.discoveryDiagnostics.announcementsCompleted), received \(audioReceiver.discoveryDiagnostics.announcementsReceived), malformed \(audioReceiver.discoveryDiagnostics.malformedAnnouncements), failures \(audioReceiver.discoveryDiagnostics.announcementFailures)")
                Text("Heartbeat: pings received \(audioReceiver.snapshot.statistics.heartbeatPingsReceived), pongs sent \(audioReceiver.snapshot.statistics.heartbeatPongsSent), pings sent \(audioReceiver.snapshot.statistics.heartbeatPingsSent), pongs received \(audioReceiver.snapshot.statistics.heartbeatPongsReceived), round trip \(audioReceiver.snapshot.statistics.heartbeatRoundTripMilliseconds.map(String.init) ?? \"pending\") ms")
                Text(receiverStatusLine)
                Text("Format packets: \(audioReceiver.snapshot.statistics.formatPacketsReceived), compatible: \(audioReceiver.snapshot.statistics.compatibleFormatPacketsAccepted), unsupported: \(audioReceiver.snapshot.statistics.unsupportedFormatPackets)")
                Text("Encrypted audio packets: \(audioReceiver.snapshot.statistics.encryptedAudioPacketsReceived), malformed: \(audioReceiver.snapshot.statistics.malformedPackets), unsupported: \(audioReceiver.snapshot.statistics.unsupportedPackets), address checks: \(audioReceiver.snapshot.statistics.addrChecksReceived)")
                Text("Dropped: \(audioReceiver.snapshot.statistics.packetsDropped), lost: \(audioReceiver.snapshot.statistics.packetsLost), reordered: \(audioReceiver.snapshot.statistics.packetsReordered)")
                Text("Authentication successes: \(audioReceiver.snapshot.statistics.authenticationSuccesses), failures: \(audioReceiver.snapshot.statistics.authenticationFailures), encrypted-frame failures: \(audioReceiver.snapshot.statistics.encryptedAudioAuthenticationFailures), buffer frames: \(audioReceiver.snapshot.statistics.bufferDepthFrames), underruns: \(audioReceiver.snapshot.statistics.underruns)")
                if let sampleRate = audioReceiver.snapshot.sampleRate,
                   let channels = audioReceiver.snapshot.channelCount {
                    Text("Format: \(sampleRate) Hz, \(channels) channels, PCM")
                }
                Button("Copy RemSound diagnostic report", systemImage: "doc.on.doc") {
                    AppClipboard.copy(audioReceiver.diagnosticReport(profile: profile))
                }
                Text("Diagnostics exclude passwords, derived keys, fingerprints, packet plaintext, and audio content. A completed UDP discovery send confirms only that iOS accepted the datagram locally; Windows heartbeat pings are the stronger proof that the PC can reach this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("RemSound Audio")
        .task {
            password = settings.credentials(for: profile)?.remSoundPassword ?? ""
        }
    }

    private var capability: RemSoundReceiverCapability {
        profile.remSoundReceiver?.normalized() ?? RemSoundReceiverCapability(senderHost: profile.address)
    }

    private var host: String { capability.senderHost }
    private var port: UInt16 { capability.senderPort }
    private var senderDescription: String { "Windows peer: \(host), audio port \(port)" }
    private var receiverStatusLine: String {
        let listening = audioReceiver.snapshot.isListening ? "yes" : "no"
        return "Receiver listening: \(listening), audio UDP packets received: \(audioReceiver.snapshot.statistics.packetsReceived)"
    }
    private var canReconnect: Bool {
        switch audioReceiver.snapshot.state {
        case .idle, .stopped: false
        default: true
        }
    }

    private var actionTitle: String {
        switch audioReceiver.snapshot.state {
        case .idle, .stopped, .failed: "Start audio"
        case .connecting, .authenticating, .waitingForAudio, .buffering, .playing, .reconnecting: "Stop audio"
        }
    }

    private var actionSymbol: String {
        switch audioReceiver.snapshot.state {
        case .idle, .stopped, .failed: "play.fill"
        case .connecting, .authenticating, .waitingForAudio, .buffering, .playing, .reconnecting: "stop.fill"
        }
    }
}

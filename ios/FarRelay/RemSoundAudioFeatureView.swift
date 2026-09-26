import SwiftUI

/// Minimal, accessible Phase 1 control surface. It intentionally has no
/// dependency on BridgeClient: audio can fail, stop, or restart while remote
/// control remains entirely available.
struct RemSoundAudioFeatureView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AudioReceiverModel.self) private var audioReceiver
    @Environment(RemSoundOrchestrationSession.self) private var orchestration
    let profile: HostProfile
    @State private var password = ""

    var body: some View {
        Form {
            Section("Windows RemSound peer") {
                Text(senderDescription)
                Text("This is the Windows PC address, not the iPhone address. Start audio to announce FarRelay iOS directly to that RemSound app. Then select FarRelay iOS in RemSound's discovered peers and send PCM or Opus audio to it on UDP port \(port).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("RemSound does not use an interactive pairing request for this direct connection. Windows heartbeat proves reachability; the shared password is validated when its audio Format packet supplies the password fingerprint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Audio status") {
                Text(orchestration.statusLabel)
                    .accessibilityLabel("Remote audio orchestration status")
                    .accessibilityValue(orchestration.statusLabel)
                Text(audioReceiver.compactStatusLabel)
                    .accessibilityLabel("RemSound status")
                    .accessibilityValue(audioReceiver.compactStatusLabel)
                if let error = audioReceiver.snapshot.statistics.lastError {
                    Text(error).foregroundStyle(.secondary)
                }
                Button(actionTitle, systemImage: actionSymbol) {
                    if shouldStartAudio {
                        guard let credentials = settings.credentials(for: profile) else { return }
                        Task {
                            await orchestration.start(
                                profile: profile,
                                credentials: credentials,
                                targetLatencyMilliseconds: settings.remSoundTargetLatencyMilliseconds,
                                autoTuneLatencyEnabled: settings.remSoundAutoTuneLatencyEnabled
                            )
                        }
                    } else {
                        orchestration.stopAudio()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Reconnect audio", systemImage: "arrow.clockwise") {
                    if orchestration.activeProfileID == profile.id {
                        orchestration.reconnectAudio()
                    } else {
                        audioReceiver.reconnect()
                    }
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

                Stepper(
                    "Playback delay: \(settings.remSoundTargetLatencyMilliseconds) milliseconds",
                    value: Binding(
                        get: { settings.remSoundTargetLatencyMilliseconds },
                        set: { milliseconds in
                            settings.remSoundTargetLatencyMilliseconds = milliseconds
                            settings.save()
                            audioReceiver.setTargetLatencyMilliseconds(milliseconds)
                        }
                    ),
                    in: 20...500,
                    step: 10
                )

                Toggle("Adjust playback delay automatically", isOn: Binding(
                    get: { settings.remSoundAutoTuneLatencyEnabled },
                    set: { enabled in
                        settings.remSoundAutoTuneLatencyEnabled = enabled
                        settings.save()
                        audioReceiver.setAutoTuneLatencyEnabled(enabled)
                    }
                ))

                Text(settings.remSoundAutoTuneLatencyEnabled
                     ? "FarRelay starts from your selected delay and adapts to measured packet and render gaps. Turn this off for a stable fixed buffer."
                     : "Fixed-delay mode is the default. 80 milliseconds matches the official RemSound receiver's stable default and avoids silently shrinking toward an underrun-prone buffer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Playback-only audio. FarRelay never captures the microphone in Phase 1.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Audio diagnostics") {
                Text("Discovery: \(audioReceiver.discoveryDiagnostics.isActive ? "active" : "inactive"), attempts \(audioReceiver.discoveryDiagnostics.announcementsAttempted), local completions \(audioReceiver.discoveryDiagnostics.announcementsCompleted), received \(audioReceiver.discoveryDiagnostics.announcementsReceived), malformed \(audioReceiver.discoveryDiagnostics.malformedAnnouncements), failures \(audioReceiver.discoveryDiagnostics.announcementFailures)")
                Text("Heartbeat: pings received \(audioReceiver.snapshot.statistics.heartbeatPingsReceived), pongs sent \(audioReceiver.snapshot.statistics.heartbeatPongsSent), pings sent \(audioReceiver.snapshot.statistics.heartbeatPingsSent), pongs received \(audioReceiver.snapshot.statistics.heartbeatPongsReceived), round trip \(audioReceiver.snapshot.statistics.heartbeatRoundTripMilliseconds.map(String.init) ?? "pending") ms")
                Text(receiverStatusLine)
                Text("Format packets: \(audioReceiver.snapshot.statistics.formatPacketsReceived), compatible: \(audioReceiver.snapshot.statistics.compatibleFormatPacketsAccepted), unsupported: \(audioReceiver.snapshot.statistics.unsupportedFormatPackets)")
                Text("Encrypted audio packets: \(audioReceiver.snapshot.statistics.encryptedAudioPacketsReceived), malformed: \(audioReceiver.snapshot.statistics.malformedPackets), unsupported: \(audioReceiver.snapshot.statistics.unsupportedPackets), address checks: \(audioReceiver.snapshot.statistics.addrChecksReceived)")
                Text("Dropped: \(audioReceiver.snapshot.statistics.packetsDropped), lost: \(audioReceiver.snapshot.statistics.packetsLost), reordered: \(audioReceiver.snapshot.statistics.packetsReordered), duplicates: \(audioReceiver.snapshot.statistics.packetsDuplicated)")
                Text("Duplicate peer paths suppressed: \(audioReceiver.snapshot.statistics.duplicatePathsSuppressed), path handovers: \(audioReceiver.snapshot.statistics.pathHandovers)")
                Text("Authentication successes: \(audioReceiver.snapshot.statistics.authenticationSuccesses), failures: \(audioReceiver.snapshot.statistics.authenticationFailures), encrypted-frame failures: \(audioReceiver.snapshot.statistics.encryptedAudioAuthenticationFailures), buffer frames: \(audioReceiver.snapshot.statistics.bufferDepthFrames), underruns: \(audioReceiver.snapshot.statistics.underruns)")
                if let sampleRate = audioReceiver.snapshot.sampleRate,
                   let channels = audioReceiver.snapshot.channelCount {
                    Text("Format: \(sampleRate) Hz, \(channels) channels, \(audioReceiver.snapshot.codec == .opus ? "Opus" : "PCM")")
                }
                Button("Copy RemSound diagnostic report", systemImage: "doc.on.doc") {
                    AppClipboard.copy(audioReceiver.diagnosticReport(profile: profile))
                }
                Button("Start receiver only (debug)", systemImage: "wrench.and.screwdriver") {
                    audioReceiver.start(
                        host: host,
                        port: port,
                        password: password,
                        targetLatencyMilliseconds: settings.remSoundTargetLatencyMilliseconds,
                        autoTuneLatencyEnabled: settings.remSoundAutoTuneLatencyEnabled
                    )
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

    private var shouldStartAudio: Bool {
        if orchestration.activeProfileID == profile.id {
            switch orchestration.state {
            case .idle, .stopped, .failed, .unavailable:
                return true
            case .requestingSession, .startingSender, .connectingReceiver, .buffering, .playing, .reconnecting, .degraded:
                return false
            }
        }
        switch audioReceiver.snapshot.state {
        case .idle, .stopped, .failed:
            return true
        case .connecting, .authenticating, .waitingForAudio, .buffering, .playing, .reconnecting:
            return false
        }
    }

    private var actionTitle: String { shouldStartAudio ? "Start audio" : "Stop audio" }
    private var actionSymbol: String { shouldStartAudio ? "play.fill" : "stop.fill" }
}

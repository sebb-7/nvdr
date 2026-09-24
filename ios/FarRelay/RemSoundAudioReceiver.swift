import CryptoKit
import Foundation
import Network

/// RemSound UDP receiver for the current PCM and Opus transport contracts.
/// Its mutable state is actor-isolated and it owns no SSH, NVDA, controller,
/// keyboard, or RemoteIntent references.
actor RemSoundAudioReceiver: AudioReceiver {
    private static let maximumConcealedFramesPerGap = 8
    private static let maximumDatagramBytes = 2_048
    private static let maximumInboundConnections = 4
    private static let maximumPendingFrameDeliveries = 16
    private static let minimumAdaptiveLatencyMilliseconds = 20
    private static let maximumAdaptiveLatencyMilliseconds = 200
    private static let pathHandoverSilence: TimeInterval = 1
    private static let senderLivenessTimeout: TimeInterval = 5
    private static let initialTrafficTimeout: TimeInterval = 8
    private static let telemetryPublishIntervalNanoseconds: UInt64 = 250_000_000
    private let networkQueue = DispatchQueue(label: "com.sebb7.farrelay.remsound")
    private var listener: NWListener?
    private var inboundConnections: [UUID: NWConnection] = [:]
    private var endpoint: AudioReceiverEndpoint?
    private var key: SymmetricKey?
    private var expectedFingerprint: Data?
    private var activeStreamID: UInt16?
    private var activeFormat: RemSoundFormat?
    private var expectedSequence: UInt32?
    private var heartbeatSequence: UInt32 = 0
    private var heartbeatScheduler = RemSoundHeartbeatScheduler()
    private var selectedPeerConnectionID: UUID?
    private var selectedPeerConnectionSelectedAt: Date?
    private var selectedPeerLastAudioActivity: Date?
    private var configuredTargetLatencyMilliseconds = 80
    private var autoTuneLatencyEnabled = false
    private var assembler = RemSoundPCMFrameAssembler()
    /// Read by AVAudioEngine's source callback while this actor writes decoded PCM.
    nonisolated let playout = RemSoundPlayoutBuffer()
    private var audioDecoder: RemSoundAudioDecoder?
    private var startupBufferFrameTarget = 960
    private var playbackFailureMessage: String?
    private var lastTelemetryPublishNanoseconds: UInt64 = 0
    private var listenerReadyAt: Date?
    private var lastSenderActivity: Date?
    private var generation = 0
    private var senderWatchdog: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var playoutTuneTask: Task<Void, Never>?
    private var playoutSamples: [RemSoundLatencyAutoTune.Sample] = []
    private var arrivalPeakMilliseconds = 0
    private var lastDecodedArrival: Date?
    private var lastTuneBlockingUnderruns = 0
    private var tuneTicks = 0
    private var receiverSnapshot = AudioReceiverSnapshot()
    private var snapshotContinuations: [UUID: AsyncStream<AudioReceiverSnapshot>.Continuation] = [:]
    private var frameContinuations: [UUID: AsyncStream<AudioPCMFrame>.Continuation] = [:]

    func start(configuration: AudioReceiverConfiguration) async {
        configuredTargetLatencyMilliseconds = configuration.targetLatencyMilliseconds
        autoTuneLatencyEnabled = configuration.autoTuneLatencyEnabled
        guard !configuration.host.isEmpty, !configuration.password.isEmpty else {
            begin(
                endpoint: AudioReceiverEndpoint(host: configuration.host, port: configuration.port),
                key: nil,
                expectedFingerprint: nil,
                validationError: "Enter a sender address and shared password."
            )
            return
        }
        begin(
            endpoint: AudioReceiverEndpoint(host: configuration.host, port: configuration.port),
            key: RemSoundCrypto.key(password: configuration.password),
            expectedFingerprint: RemSoundCrypto.fingerprint(password: configuration.password),
            validationError: nil
        )
    }

    func stop() async {
        generation &+= 1
        stopNetwork()
        resetPipeline()
        endpoint = nil
        receiverSnapshot.state = .stopped
        publish()
    }

    func reconnect() async {
        guard let endpoint, let key, let expectedFingerprint else {
            receiverSnapshot.state = .idle
            publish()
            return
        }
        let reconnectCount = receiverSnapshot.statistics.reconnects + 1
        receiverSnapshot.state = .reconnecting
        publish()
        begin(endpoint: endpoint, key: key, expectedFingerprint: expectedFingerprint, validationError: nil)
        receiverSnapshot.statistics.reconnects = reconnectCount
        publish()
    }

    func setMuted(_ muted: Bool) async {
        receiverSnapshot.muted = muted
        publish()
    }

    func setVolume(_ volume: Float) async {
        receiverSnapshot.volume = min(max(volume, 0), 1)
        publish()
    }

    func setTargetLatencyMilliseconds(_ milliseconds: Int) async {
        configuredTargetLatencyMilliseconds = min(max(milliseconds, 20), 500)
        let frames = targetFrames(for: activeFormat)
        startupBufferFrameTarget = frames
        playout.setTargetFrames(frames)
        receiverSnapshot.statistics.initialJitterTargetFrames = frames
        receiverSnapshot.statistics.jitterTargetFrames = frames
        receiverSnapshot.statistics.lastAutoTuneDecision = autoTuneLatencyEnabled
            ? "user target \(configuredTargetLatencyMilliseconds) ms; auto-tune enabled"
            : "fixed \(configuredTargetLatencyMilliseconds) ms"
        publish()
    }

    func setAutoTuneLatencyEnabled(_ enabled: Bool) async {
        autoTuneLatencyEnabled = enabled
        receiverSnapshot.statistics.autoTuneEnabled = enabled
        playoutSamples.removeAll(keepingCapacity: true)
        arrivalPeakMilliseconds = 0
        lastTuneBlockingUnderruns = receiverSnapshot.statistics.producerStarvationUnderruns
        tuneTicks = 0
        if !enabled {
            let frames = targetFrames(for: activeFormat)
            startupBufferFrameTarget = frames
            playout.setTargetFrames(frames)
            receiverSnapshot.statistics.jitterTargetFrames = frames
            receiverSnapshot.statistics.lastAutoTuneDecision = "fixed \(configuredTargetLatencyMilliseconds) ms"
        } else {
            receiverSnapshot.statistics.lastAutoTuneDecision = "auto-tune enabled"
        }
        publish()
    }

    /// Playback is deliberately an independent downstream consumer. A route or
    /// engine failure changes only audio state and never tears down any control
    /// session or input owner.
    func playbackFailed(_ message: String = "Audio playback is unavailable. Reconnect audio to try again.") {
        guard playbackFailureMessage == nil else { return }
        playbackFailureMessage = message
        fail(message)
    }

    func playbackDropped(frameCount: Int) {
        receiverSnapshot.statistics.bufferDroppedFrames += frameCount
        publishTelemetryIfDue()
    }

    /// Called by the renderer only when its scheduled AVAudio buffers drain
    /// while this receiver still believes a stream is playing. The next decoded
    /// frames must meet the startup target again before reporting Playing.
    func playbackUnderrun() {
        guard receiverSnapshot.state == .playing, playbackFailureMessage == nil else { return }
        receiverSnapshot.state = .buffering
        publishTelemetryIfDue()
    }

    /// Exposed for deterministic tests as well as the bounded watchdog. It
    /// makes a disappearing sender an audio-local failure rather than leaving a
    /// misleading playing state indefinitely. Before the first compatible
    /// Format packet, it also turns an otherwise permanent "Authenticating"
    /// state into a useful diagnostic when no RemSound traffic reaches iOS.
    func checkSenderLiveness(now: Date = .now) {
        guard receiverSnapshot.state == .authenticating
                || receiverSnapshot.state == .waitingForAudio
                || receiverSnapshot.state == .buffering
                || receiverSnapshot.state == .playing
        else { return }

        if receiverSnapshot.state == .authenticating,
           lastSenderActivity == nil,
           let listenerReadyAt,
           now.timeIntervalSince(listenerReadyAt) > Self.initialTrafficTimeout {
            if receiverSnapshot.statistics.heartbeatPingsReceived == 0,
               receiverSnapshot.statistics.packetsReceived == 0 {
                fail("No RemSound traffic reached this device. Check that FarRelay iOS is selected in Windows RemSound, Local Network access is allowed, and UDP 47830 is reachable.")
                return
            }
            if receiverSnapshot.statistics.heartbeatPingsReceived == 0 {
                fail("RemSound traffic reached this device, but no compatible heartbeat or audio format was received.")
                return
            }
            // Heartbeats prove Windows can reach us. Remaining in authenticating
            // here means Windows is online but has not begun an audio stream yet.
            return
        }

        guard let lastSenderActivity,
              now.timeIntervalSince(lastSenderActivity) > Self.senderLivenessTimeout
        else { return }
        fail("The audio sender stopped or became unreachable. Reconnect audio to try again.")
    }

    func snapshot() async -> AudioReceiverSnapshot { receiverSnapshot }

    func updates() async -> AsyncStream<AudioReceiverSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(receiverSnapshot)
            snapshotContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    func pcmFrames() -> AsyncStream<AudioPCMFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(Self.maximumPendingFrameDeliveries)) { continuation in
            frameContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFrameContinuation(id) }
            }
        }
    }

    /// Deterministic test seam. Production datagrams and fixtures travel through
    /// this same parser, without any controller or UI reference. Tests that need
    /// to inspect a generated Heartbeat Pong use ingestAndPrepareReply instead.
    func ingest(_ datagram: Data) {
        _ = ingestAndPrepareReply(datagram)
    }

    /// Parses one datagram and returns an audio-local protocol reply when the
    /// current RemSound contract requires one. Heartbeat Pings and relay
    /// AddrCheck challenges are the only reply-producing packet types.
    /// Returning the bytes keeps socket mechanics out of protocol tests.
    func ingestAndPrepareReply(_ datagram: Data) -> Data? {
        receiverSnapshot.statistics.packetsReceived += 1
        guard datagram.count <= Self.maximumDatagramBytes,
              let header = RemSoundPacketHeader.parse(datagram)
        else {
            dropPacket(malformed: true)
            return nil
        }
        let payload = Data(datagram.dropFirst(RemSoundPacketHeader.size))
        switch header.type {
        case .format:
            receiverSnapshot.statistics.formatPacketsReceived += 1
            ingestFormat(payload, streamID: header.streamID)
            return nil
        case .audio:
            receiverSnapshot.statistics.encryptedAudioPacketsReceived += 1
            ingestAudio(payload, streamID: header.streamID, sequence: header.sequence)
            return nil
        case .heartbeat:
            guard let heartbeat = RemSoundHeartbeat.parse(payload) else {
                dropPacket(malformed: true)
                return nil
            }
            switch heartbeat.kind {
            case .ping:
                receiverSnapshot.statistics.heartbeatPingsReceived += 1
                if receiverSnapshot.state == .connecting || receiverSnapshot.state == .authenticating {
                    receiverSnapshot.state = .waitingForAudio
                }
                heartbeatSequence &+= 1
                let reply = RemSoundHeartbeat.pongResponse(to: datagram, sequence: heartbeatSequence)
                if reply == nil { dropPacket(malformed: true) } else { publish() }
                return reply
            case .pong:
                receiverSnapshot.statistics.heartbeatPongsReceived += 1
                if let roundTrip = heartbeatScheduler.roundTripMilliseconds(
                    forPong: datagram,
                    now: monotonicMilliseconds
                ) {
                    receiverSnapshot.statistics.heartbeatRoundTripMilliseconds = roundTrip
                }
                publish()
                return nil
            }
        case .addressCheck:
            // Current relay contract: prove this source address receives packets
            // by echoing the exact challenge on the canonical audio transport.
            receiverSnapshot.statistics.addrChecksReceived += 1
            publish()
            return datagram
        case .control:
            receiverSnapshot.statistics.controlPacketsReceived += 1
            receiverSnapshot.statistics.unsupportedPackets += 1
            publish()
            return nil
        case .keepAlive:
            receiverSnapshot.statistics.keepAlivePacketsReceived += 1
            receiverSnapshot.statistics.unsupportedPackets += 1
            publish()
            return nil
        }
    }

    private func begin(
        endpoint: AudioReceiverEndpoint,
        key: SymmetricKey?,
        expectedFingerprint: Data?,
        validationError: String?
    ) {
        let muted = receiverSnapshot.muted
        let volume = receiverSnapshot.volume
        generation &+= 1
        let activeGeneration = generation
        stopNetwork()
        resetPipeline()
        self.endpoint = endpoint
        guard validationError == nil, let key, let expectedFingerprint else {
            fail(validationError ?? "Unable to prepare audio authentication.")
            return
        }
        self.key = key
        self.expectedFingerprint = expectedFingerprint
        receiverSnapshot = AudioReceiverSnapshot(
            state: .connecting,
            muted: muted,
            volume: volume,
            peer: "\(endpoint.host):\(endpoint.port)"
        )
        let configuredFrames = targetFrames(for: nil)
        receiverSnapshot.statistics.initialJitterTargetFrames = configuredFrames
        receiverSnapshot.statistics.jitterTargetFrames = configuredFrames
        receiverSnapshot.statistics.autoTuneEnabled = autoTuneLatencyEnabled
        receiverSnapshot.statistics.lastAutoTuneDecision = autoTuneLatencyEnabled
            ? "waiting for measurements"
            : "fixed \(configuredTargetLatencyMilliseconds) ms"
        publish()

        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            fail("The audio port is invalid.")
            return
        }

        do {
            let listener = try NWListener(using: .udp, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state, generation: activeGeneration) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection, generation: activeGeneration) }
            }
            self.listener = listener
            listener.start(queue: networkQueue)
            startSenderWatchdog(generation: activeGeneration)
            startHeartbeatScheduler(generation: activeGeneration)
            startPlayoutTuner(generation: activeGeneration)
        } catch {
            fail("Unable to bind the audio UDP socket.")
        }
    }

    private func handleListenerState(_ state: NWListener.State, generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            listenerReadyAt = .now
            receiverSnapshot.isListening = true
            if receiverSnapshot.state == .connecting || receiverSnapshot.state == .reconnecting {
                receiverSnapshot.state = .authenticating
            }
            publish()
        case .failed:
            receiverSnapshot.isListening = false
            fail("The audio UDP listener failed.")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, generation: Int) {
        guard generation == self.generation else {
            connection.cancel()
            return
        }
        guard inboundConnections.count < Self.maximumInboundConnections else {
            connection.cancel()
            dropPacket()
            return
        }
        let id = UUID()
        inboundConnections[id] = connection
        if isConfiguredPeer(connection), selectedPeerConnectionID == nil {
            selectedPeerConnectionID = id
            selectedPeerConnectionSelectedAt = .now
            selectedPeerLastAudioActivity = nil
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { await self?.removeConnection(id, generation: generation) }
        }
        connection.start(queue: networkQueue)
        receiveNext(on: id, generation: generation)
    }

    private func receiveNext(on id: UUID, generation: Int) {
        guard generation == self.generation else { return }
        guard let connection = inboundConnections[id] else { return }
        connection.receiveMessage { [weak self] content, _, _, error in
            Task {
                guard let self else { return }
                guard await self.isCurrentGeneration(generation) else { return }
                if let content {
                    let reply = await self.ingestNetworkDatagram(content, from: id)
                    if let reply {
                        await self.sendProtocolReply(reply, on: id, generation: generation)
                    }
                }
                if error == nil { await self.receiveNext(on: id, generation: generation) }
                else { await self.removeConnection(id, generation: generation) }
            }
        }
    }

    private func sendProtocolReply(_ reply: Data, on id: UUID, generation: Int) {
        guard generation == self.generation,
              let connection = inboundConnections[id]
        else { return }
        if RemSoundPacketHeader.parse(reply)?.type == .addressCheck {
            receiverSnapshot.statistics.addrCheckRepliesSent += 1
        } else {
            receiverSnapshot.statistics.heartbeatPongsSent += 1
        }
        publish()
        connection.send(content: reply, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.recordHeartbeatReplyFailure(error, generation: generation) }
        })
    }

    private func recordHeartbeatReplyFailure(_ error: NWError, generation: Int) {
        guard generation == self.generation else { return }
        receiverSnapshot.statistics.heartbeatReplyFailures += 1
        receiverSnapshot.statistics.lastError = "Heartbeat reply failed: \(error.localizedDescription)"
        publish()
    }

    /// Format and Audio are accepted only from the configured selected Windows
    /// peer. Heartbeat and AddrCheck remain transport-level packets: the former
    /// establishes a path we can use for reciprocal heartbeats and the latter
    /// is a relay address proof that must echo to its source.
    private func ingestNetworkDatagram(_ datagram: Data, from connectionID: UUID) -> Data? {
        if let header = RemSoundPacketHeader.parse(datagram),
           header.type == .format || header.type == .audio {
            guard isConfiguredPeerConnection(connectionID) else {
                receiverSnapshot.statistics.packetsReceived += 1
                dropPacket()
                return nil
            }

            let now = Date()
            if connectionID != selectedPeerConnectionID {
                guard shouldHandover(to: connectionID, now: now) else {
                    receiverSnapshot.statistics.packetsReceived += 1
                    receiverSnapshot.statistics.duplicatePathsSuppressed += 1
                    dropPacket()
                    return nil
                }
                handover(to: connectionID, now: now)
            }

            if header.type == .audio {
                selectedPeerLastAudioActivity = now
            }
        }
        return ingestAndPrepareReply(datagram)
    }

    private func isConfiguredPeerConnection(_ id: UUID) -> Bool {
        guard let connection = inboundConnections[id] else { return false }
        return isConfiguredPeer(connection)
    }

    private func shouldHandover(to candidateID: UUID, now: Date) -> Bool {
        guard candidateID != selectedPeerConnectionID else { return true }
        guard let selectedPeerConnectionID else { return true }
        let currentPathExists = inboundConnections[selectedPeerConnectionID] != nil
        let lastAudioAge = selectedPeerLastAudioActivity.map { now.timeIntervalSince($0) }
        let selectedAge = selectedPeerConnectionSelectedAt.map { now.timeIntervalSince($0) }
        return Self.shouldHandoverPeerPath(
            currentPathExists: currentPathExists,
            lastAudioAge: lastAudioAge,
            selectedAge: selectedAge
        )
    }

    /// Pure equivalent of RemSoundApple's one-live-path rule, adapted to
    /// FarRelay's single selected Windows peer. A second source-port/path may
    /// not steal playback while the current path has delivered audio within
    /// the handover silence window.
    nonisolated static func shouldHandoverPeerPath(
        currentPathExists: Bool,
        lastAudioAge: TimeInterval?,
        selectedAge: TimeInterval?
    ) -> Bool {
        guard currentPathExists else { return true }
        if let lastAudioAge { return lastAudioAge > pathHandoverSilence }
        if let selectedAge { return selectedAge > pathHandoverSilence }
        return false
    }

    private func handover(to connectionID: UUID, now: Date) {
        selectedPeerConnectionID = connectionID
        selectedPeerConnectionSelectedAt = now
        selectedPeerLastAudioActivity = nil
        receiverSnapshot.statistics.pathHandovers += 1
        resetActiveStreamState()
        if playbackFailureMessage == nil {
            receiverSnapshot.state = .waitingForAudio
        }
    }

    /// Network.framework gives an accepted UDP connection for each remote path.
    /// We deliberately retain the one from the configured peer and use *that*
    /// connection for outbound pings, rather than opening an ephemeral UDP
    /// connection with a different source port. The profile already expresses
    /// FarRelay's one-peer selected state.
    private func isConfiguredPeer(_ connection: NWConnection) -> Bool {
        guard let endpoint,
              case .hostPort(let remoteHost, _) = connection.endpoint
        else { return false }
        return remoteHost == NWEndpoint.Host(endpoint.host)
    }

    private var monotonicMilliseconds: Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func startHeartbeatScheduler(generation: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: RemSoundHeartbeatScheduler.cadence)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.sendOutboundHeartbeat(generation: generation)
            }
        }
    }

    private func sendOutboundHeartbeat(generation: Int) {
        guard generation == self.generation,
              let selectedPeerConnectionID,
              let connection = inboundConnections[selectedPeerConnectionID]
        else { return }
        let ping = heartbeatScheduler.makePing(monotonicMilliseconds: monotonicMilliseconds)
        receiverSnapshot.statistics.heartbeatPingsSent += 1
        publish()
        connection.send(content: ping, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.recordHeartbeatReplyFailure(error, generation: generation) }
        })
    }

    private func ingestFormat(_ payload: Data, streamID: UInt16) {
        let format: RemSoundFormat
        switch RemSoundFormat.classify(payload) {
        case .supported(let supported):
            format = supported
        case .unsupported(let rawCodec):
            receiverSnapshot.statistics.unsupportedFormatPackets += 1
            receiverSnapshot.statistics.lastError = "Unsupported RemSound format codec: \(rawCodec)."
            if receiverSnapshot.state == .connecting || receiverSnapshot.state == .authenticating {
                receiverSnapshot.state = .waitingForAudio
            }
            publish()
            return
        case .malformed:
            dropPacket(malformed: true)
            return
        }
        guard let expectedFingerprint, let fingerprint = format.fingerprint else {
            dropPacket(malformed: true)
            return
        }
        guard RemSoundCrypto.fingerprintsMatch(fingerprint, expectedFingerprint) else {
            receiverSnapshot.statistics.authenticationFailures += 1
            receiverSnapshot.statistics.formatAuthenticationFailures += 1
            fail("The sender password does not match.")
            return
        }
        receiverSnapshot.statistics.authenticationSuccesses += 1
        receiverSnapshot.statistics.compatibleFormatPacketsAccepted += 1

        // Windows repeats its Format packet every 250 ms. Only a stream or
        // format identity change retires decoder, FEC, partial PCM and playout
        // state; an ordinary re-announcement must never create a playback gap.
        let isNewStream = activeStreamID != streamID || activeFormat != format
        if isNewStream {
            guard let decoder = RemSoundAudioDecoder(format: format) else {
                playbackFailureMessage = "Unable to prepare the RemSound \(format.codec == .opus ? "Opus" : "PCM") decoder. Reconnect audio to try again."
                fail(playbackFailureMessage ?? "Unable to prepare audio decoder.")
                return
            }
            activeStreamID = streamID
            activeFormat = format
            audioDecoder = decoder
            expectedSequence = nil
            assembler.reset()
            startupBufferFrameTarget = startupBufferTarget(for: format)
            playout.reset(targetFrames: startupBufferFrameTarget)
            receiverSnapshot.statistics.jitterTargetFrames = startupBufferFrameTarget
            receiverSnapshot.statistics.initialJitterTargetFrames = startupBufferFrameTarget
            receiverSnapshot.statistics.autoTuneEnabled = autoTuneLatencyEnabled
            receiverSnapshot.statistics.lastAutoTuneDecision = autoTuneLatencyEnabled
                ? "initial \(format.opusMode?.rawValue ?? "PCM") target"
                : "fixed \(configuredTargetLatencyMilliseconds) ms"
            playoutSamples.removeAll(keepingCapacity: true)
            arrivalPeakMilliseconds = 0
            lastDecodedArrival = nil
            lastTuneBlockingUnderruns = 0
            tuneTicks = 0
        }
        lastSenderActivity = .now
        receiverSnapshot.sampleRate = format.sampleRate
        receiverSnapshot.channelCount = format.channels
        receiverSnapshot.codec = format.codec
        receiverSnapshot.opusMode = format.opusMode
        receiverSnapshot.frameDurationMilliseconds = format.frameDurationMilliseconds
        if let playbackFailureMessage {
            receiverSnapshot.state = .failed(playbackFailureMessage)
        } else {
            receiverSnapshot.state = .buffering
        }
        publish()
    }

    private func ingestAudio(_ payload: Data, streamID: UInt16, sequence: UInt32) {
        guard playbackFailureMessage == nil else { return }
        guard activeStreamID == streamID, let format = activeFormat, let key, let audioDecoder else {
            // A packet from a former stream cannot contaminate its replacement.
            dropPacket()
            return
        }
        guard let sequenceEvent = acceptSequence(sequence) else { return }

        switch format.codec {
        case .pcm:
            guard let part = RemSoundPCMPart.parse(payload) else {
                dropPacket(malformed: true)
                return
            }
            let encryptedFrame: Data
            switch assembler.append(part) {
            case .pending:
                return
            case .rejected:
                dropPacket()
                return
            case .complete(let completed):
                encryptedFrame = completed
            }
            guard let plaintext = RemSoundCrypto.decrypt(encryptedFrame, using: key) else {
                recordEncryptedAudioAuthenticationFailure()
                return
            }
            guard let frame = audioDecoder.decode(plaintext) else {
                dropPacket(malformed: true)
                return
            }
            enqueueDecoded(frame, format: format)

        case .opus:
            guard let plaintext = RemSoundCrypto.decrypt(payload, using: key) else {
                recordEncryptedAudioAuthenticationFailure()
                return
            }
            recoverOpusGap(sequenceEvent, packet: plaintext, decoder: audioDecoder, format: format)
            guard let frame = audioDecoder.decode(plaintext) else {
                receiverSnapshot.statistics.opusDecodeFailures += 1
                receiverSnapshot.statistics.lastError = "Opus decode failed."
                publishTelemetryIfDue()
                return
            }
            receiverSnapshot.statistics.opusPacketsDecoded += 1
            enqueueDecoded(frame, format: format)
        }
    }

    private enum SequenceEvent {
        case first
        case inOrder
        case gap(Int)
    }

    private func acceptSequence(_ sequence: UInt32) -> SequenceEvent? {
        guard let expected = expectedSequence else {
            expectedSequence = sequence &+ 1
            return .first
        }
        if sequence == expected {
            expectedSequence = sequence &+ 1
            return .inOrder
        }
        let forwardGap = sequence &- expected
        if forwardGap < 1_000_000 {
            receiverSnapshot.statistics.packetsLost += Int(forwardGap)
            expectedSequence = sequence &+ 1
            return .gap(Int(forwardGap))
        }
        if sequence == (expected &- 1) {
            receiverSnapshot.statistics.packetsDuplicated += 1
        } else {
            receiverSnapshot.statistics.packetsReordered += 1
            receiverSnapshot.statistics.latePacketsDiscarded += 1
        }
        receiverSnapshot.statistics.packetsDropped += 1
        publish()
        return nil
    }

    private func startupBufferTarget(for format: RemSoundFormat) -> Int {
        targetFrames(for: format)
    }

    private func targetFrames(for format: RemSoundFormat?) -> Int {
        let configured = configuredTargetLatencyMilliseconds * RemSoundPlayoutBuffer.sampleRate / 1_000
        guard let format else { return max(configured, 1) }
        // Mirror the official receiver's codec floor: the playout target must
        // never sit below roughly 1.5 packets, even if the user chooses a tiny delay.
        let codecFloor = (format.frameSamplesPerChannel * 3 + 1) / 2
        return max(configured, codecFloor, 1)
    }

    private func recoverOpusGap(
        _ sequenceEvent: SequenceEvent,
        packet: Data,
        decoder: RemSoundAudioDecoder,
        format: RemSoundFormat
    ) {
        let missingFrames: Int
        switch sequenceEvent {
        case .first, .inOrder:
            return
        case .gap(let count):
            missingFrames = count
        }

        if missingFrames == 1,
           let fec = decoder.decode(packet, fec: true) {
            receiverSnapshot.statistics.opusFECRecoveries += 1
            enqueueDecoded(fec, format: format)
            return
        }

        // libopus PLC is bounded both in work and latency. A long outage is
        // re-synchronized by the next valid packet rather than synthesizing an
        // arbitrarily long run of audio on the network actor.
        let concealed = min(missingFrames, Self.maximumConcealedFramesPerGap)
        for _ in 0..<concealed {
            guard let frame = decoder.concealLostOpusFrame() else {
                receiverSnapshot.statistics.opusDecodeFailures += 1
                break
            }
            receiverSnapshot.statistics.opusPLCFrames += 1
            enqueueDecoded(frame, format: format)
        }
        if missingFrames > concealed {
            receiverSnapshot.statistics.latePacketsDiscarded += missingFrames - concealed
        }
    }

    private func enqueueDecoded(_ frame: AudioPCMFrame, format: RemSoundFormat) {
        guard frame.sampleRate == Double(RemSoundPlayoutBuffer.sampleRate), frame.channels == RemSoundPlayoutBuffer.channels else {
            dropPacket(malformed: true)
            return
        }
        recordDecodedArrival()
        playout.write(frame.samples)
        lastSenderActivity = .now
        syncPlayoutMetrics()
        for continuation in frameContinuations.values {
            if case .dropped(let dropped) = continuation.yield(frame) {
                receiverSnapshot.statistics.bufferDroppedFrames += dropped.samples.count / max(dropped.channels, 1)
            }
        }
        if receiverSnapshot.statistics.bufferDepthFrames >= startupBufferFrameTarget {
            receiverSnapshot.state = .playing
        }
        publishTelemetryIfDue()
    }

    private func recordEncryptedAudioAuthenticationFailure() {
        receiverSnapshot.statistics.authenticationFailures += 1
        receiverSnapshot.statistics.encryptedAudioAuthenticationFailures += 1
        receiverSnapshot.statistics.lastError = "Encrypted audio authentication failed."
        receiverSnapshot.statistics.packetsDropped += 1
        publishTelemetryIfDue()
    }

    private func dropPacket(malformed: Bool = false) {
        receiverSnapshot.statistics.packetsDropped += 1
        if malformed { receiverSnapshot.statistics.malformedPackets += 1 }
        publish()
    }

    private func fail(_ message: String) {
        receiverSnapshot.statistics.lastError = message
        receiverSnapshot.state = .failed(message)
        publish()
    }

    private func resetActiveStreamState() {
        activeStreamID = nil
        activeFormat = nil
        expectedSequence = nil
        assembler.reset()
        let target = targetFrames(for: nil)
        playout.reset(targetFrames: target)
        audioDecoder = nil
        startupBufferFrameTarget = target
        playoutSamples.removeAll(keepingCapacity: true)
        arrivalPeakMilliseconds = 0
        lastDecodedArrival = nil
        lastTuneBlockingUnderruns = receiverSnapshot.statistics.producerStarvationUnderruns
        tuneTicks = 0
        receiverSnapshot.statistics.initialJitterTargetFrames = target
        receiverSnapshot.statistics.jitterTargetFrames = target
        receiverSnapshot.statistics.autoTuneEnabled = autoTuneLatencyEnabled
        receiverSnapshot.statistics.lastAutoTuneDecision = autoTuneLatencyEnabled
            ? "waiting for measurements"
            : "fixed \(configuredTargetLatencyMilliseconds) ms"
    }

    private func resetPipeline() {
        resetActiveStreamState()
        playbackFailureMessage = nil
        lastTelemetryPublishNanoseconds = 0
        listenerReadyAt = nil
        lastSenderActivity = nil
        key = nil
        expectedFingerprint = nil
        heartbeatScheduler = RemSoundHeartbeatScheduler()
        selectedPeerConnectionID = nil
        selectedPeerConnectionSelectedAt = nil
        selectedPeerLastAudioActivity = nil
    }

    private func stopNetwork() {
        senderWatchdog?.cancel()
        senderWatchdog = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        playoutTuneTask?.cancel()
        playoutTuneTask = nil
        listener?.cancel()
        listener = nil
        for connection in inboundConnections.values { connection.cancel() }
        inboundConnections.removeAll()
        selectedPeerConnectionID = nil
        receiverSnapshot.isListening = false
    }

    private func publishTelemetryIfDue() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastTelemetryPublishNanoseconds == 0
                || now - lastTelemetryPublishNanoseconds >= Self.telemetryPublishIntervalNanoseconds
        else { return }
        lastTelemetryPublishNanoseconds = now
        publish()
    }

    private func publish() {
        for continuation in snapshotContinuations.values { continuation.yield(receiverSnapshot) }
    }

    private func removeConnection(_ id: UUID, generation: Int) {
        guard generation == self.generation else { return }
        inboundConnections.removeValue(forKey: id)
        guard selectedPeerConnectionID == id else { return }

        selectedPeerConnectionID = nil
        selectedPeerConnectionSelectedAt = nil
        selectedPeerLastAudioActivity = nil
        resetActiveStreamState()
        if playbackFailureMessage == nil {
            receiverSnapshot.state = .waitingForAudio
        }

        if let replacement = inboundConnections.first(where: { isConfiguredPeer($0.value) })?.key {
            selectedPeerConnectionID = replacement
            selectedPeerConnectionSelectedAt = .now
        }
        publish()
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func removeFrameContinuation(_ id: UUID) {
        frameContinuations.removeValue(forKey: id)
    }

    private func startSenderWatchdog(generation: Int) {
        senderWatchdog?.cancel()
        senderWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.checkSenderLiveness()
                guard await self?.isCurrentGeneration(generation) == true else { return }
            }
        }
    }

    private func startPlayoutTuner(generation: Int) {
        playoutTuneTask?.cancel()
        playoutTuneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.updatePlayoutTelemetryAndTune()
                guard await self?.isCurrentGeneration(generation) == true else { return }
            }
        }
    }

    private func recordDecodedArrival(now: Date = .now) {
        defer { lastDecodedArrival = now }
        guard let lastDecodedArrival else { return }
        let gap = max(0, Int(now.timeIntervalSince(lastDecodedArrival) * 1_000))
        arrivalPeakMilliseconds = max(arrivalPeakMilliseconds, gap)
        receiverSnapshot.statistics.recentPacketArrivalGapMilliseconds = gap
        receiverSnapshot.statistics.peakPacketArrivalGapMilliseconds = max(
            receiverSnapshot.statistics.peakPacketArrivalGapMilliseconds,
            gap
        )
    }

    private func syncPlayoutMetrics(resetPeakRenderGap: Bool = false) {
        let metrics = playout.metrics(resetPeakRenderGap: resetPeakRenderGap)
        receiverSnapshot.statistics.bufferDepthFrames = metrics.bufferedFrames
        receiverSnapshot.statistics.jitterTargetFrames = metrics.targetFrames
        receiverSnapshot.statistics.underruns = metrics.underruns
        receiverSnapshot.statistics.producerStarvationUnderruns = metrics.tuneBlockingUnderruns
        receiverSnapshot.statistics.deviceRenderGulpUnderruns = metrics.deviceGulpUnderruns
        receiverSnapshot.statistics.concealedAudioFrames = metrics.concealedFrames
        receiverSnapshot.statistics.trimEvents = metrics.trimEvents
        receiverSnapshot.statistics.bufferDroppedFrames = max(receiverSnapshot.statistics.bufferDroppedFrames, metrics.droppedFrames)
        receiverSnapshot.statistics.recentRenderCallbackGapMilliseconds = metrics.peakRenderGapMilliseconds
        receiverSnapshot.statistics.peakRenderCallbackGapMilliseconds = max(
            receiverSnapshot.statistics.peakRenderCallbackGapMilliseconds,
            metrics.peakRenderGapMilliseconds
        )
        if receiverSnapshot.state == .playing, !metrics.isArmed {
            receiverSnapshot.state = .buffering
        } else if receiverSnapshot.state == .buffering, metrics.isArmed {
            receiverSnapshot.state = .playing
        }
    }

    private func updatePlayoutTelemetryAndTune() {
        guard let format = activeFormat, playbackFailureMessage == nil else { return }
        syncPlayoutMetrics(resetPeakRenderGap: true)
        receiverSnapshot.statistics.autoTuneEnabled = autoTuneLatencyEnabled
        guard autoTuneLatencyEnabled else {
            receiverSnapshot.statistics.lastAutoTuneDecision = "fixed \(configuredTargetLatencyMilliseconds) ms"
            publishTelemetryIfDue()
            return
        }
        let statistics = receiverSnapshot.statistics
        playoutSamples.append(.init(
            arrivalGapMilliseconds: arrivalPeakMilliseconds,
            renderGapMilliseconds: statistics.recentRenderCallbackGapMilliseconds
        ))
        if playoutSamples.count > 60 { playoutSamples.removeFirst(playoutSamples.count - 60) }
        arrivalPeakMilliseconds = 0
        tuneTicks += 1
        guard tuneTicks.isMultiple(of: 5) else {
            publishTelemetryIfDue()
            return
        }
        let tuneBlockingDelta = max(0, statistics.producerStarvationUnderruns - lastTuneBlockingUnderruns)
        lastTuneBlockingUnderruns = statistics.producerStarvationUnderruns
        let frameMilliseconds = max(1, Int(format.frameDurationMilliseconds.rounded(.up)))
        let currentMilliseconds = max(1, statistics.jitterTargetFrames * 1_000 / RemSoundPlayoutBuffer.sampleRate)
        let decision = RemSoundLatencyAutoTune.decide(
            samples: playoutSamples,
            frameMilliseconds: frameMilliseconds,
            currentTargetMilliseconds: currentMilliseconds,
            minimumTargetMilliseconds: Self.minimumAdaptiveLatencyMilliseconds,
            maximumTargetMilliseconds: Self.maximumAdaptiveLatencyMilliseconds,
            tuneBlockingUnderruns: tuneBlockingDelta
        )
        switch decision {
        case .hold(let reason):
            receiverSnapshot.statistics.lastAutoTuneDecision = reason
        case .retarget(let milliseconds):
            let frames = milliseconds * RemSoundPlayoutBuffer.sampleRate / 1_000
            playout.setTargetFrames(frames)
            startupBufferFrameTarget = frames
            receiverSnapshot.statistics.jitterTargetFrames = frames
            receiverSnapshot.statistics.lastAutoTuneDecision = "target \(milliseconds) ms"
        }
        publishTelemetryIfDue()
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == self.generation
    }

}

private struct AudioReceiverEndpoint: Sendable {
    let host: String
    let port: UInt16
}

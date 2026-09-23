import CryptoKit
import Foundation
import Network

/// RemSound UDP receiver for the deliberately narrow Phase 1 PCM subset.
/// Its mutable state is actor-isolated and it owns no SSH, NVDA, controller,
/// keyboard, or RemoteIntent references.
actor RemSoundAudioReceiver: AudioReceiver {
    private static let startupBufferFrames = 960 // 20 ms at the Phase 1 48 kHz target.
    private static let maximumDatagramBytes = 2_048
    private static let maximumInboundConnections = 4
    private static let maximumPendingFrameDeliveries = 16
    private static let senderLivenessTimeout: TimeInterval = 5
    private static let initialTrafficTimeout: TimeInterval = 8
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
    private var assembler = RemSoundPCMFrameAssembler()
    private var queuedPCM = BoundedPCMQueue()
    private var playbackArmed = false
    private var listenerReadyAt: Date?
    private var lastSenderActivity: Date?
    private var generation = 0
    private var senderWatchdog: Task<Void, Never>?
    private var receiverSnapshot = AudioReceiverSnapshot()
    private var snapshotContinuations: [UUID: AsyncStream<AudioReceiverSnapshot>.Continuation] = [:]
    private var frameContinuations: [UUID: AsyncStream<AudioPCMFrame>.Continuation] = [:]

    func start(configuration: AudioReceiverConfiguration) async {
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

    /// Playback is deliberately an independent downstream consumer. A route or
    /// engine failure changes only audio state and never tears down any control
    /// session or input owner.
    func playbackFailed() {
        fail("Audio playback is unavailable. Reconnect audio to try again.")
    }

    func playbackDropped(frameCount: Int) {
        receiverSnapshot.statistics.bufferDroppedFrames += frameCount
        publish()
    }

    /// Exposed for deterministic tests as well as the bounded watchdog. It
    /// makes a disappearing sender an audio-local failure rather than leaving a
    /// misleading playing state indefinitely. Before the first compatible
    /// Format packet, it also turns an otherwise permanent "Authenticating"
    /// state into a useful diagnostic when no RemSound traffic reaches iOS.
    func checkSenderLiveness(now: Date = .now) {
        guard receiverSnapshot.state == .authenticating
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
            drainQueuedFrames()
        }
    }

    /// Deterministic test seam. Production datagrams and fixtures travel through
    /// this same parser, without any controller or UI reference. Tests that need
    /// to inspect a generated Heartbeat Pong use ingestAndPrepareReply instead.
    func ingest(_ datagram: Data) {
        _ = ingestAndPrepareReply(datagram)
    }

    /// Parses one datagram and returns an audio-local protocol reply when the
    /// current RemSound contract requires one. Today only Heartbeat Ping has a
    /// reply. Returning the bytes keeps socket mechanics out of protocol tests.
    func ingestAndPrepareReply(_ datagram: Data) -> Data? {
        receiverSnapshot.statistics.packetsReceived += 1
        guard datagram.count <= Self.maximumDatagramBytes,
              let header = RemSoundPacketHeader.parse(datagram)
        else {
            dropPacket()
            return nil
        }
        let payload = Data(datagram.dropFirst(RemSoundPacketHeader.size))
        switch header.type {
        case .format:
            ingestFormat(payload, streamID: header.streamID)
            return nil
        case .audio:
            ingestAudio(payload, streamID: header.streamID, sequence: header.sequence)
            return nil
        case .heartbeat:
            guard let heartbeat = RemSoundHeartbeat.parse(payload) else {
                dropPacket()
                return nil
            }
            guard heartbeat.kind == .ping else { return nil }
            receiverSnapshot.statistics.heartbeatPingsReceived += 1
            heartbeatSequence &+= 1
            let reply = RemSoundHeartbeat.pongResponse(to: datagram, sequence: heartbeatSequence)
            if reply == nil { dropPacket() } else { publish() }
            return reply
        case .keepAlive, .control, .addressCheck:
            // Phase 1 does not implement remote RemSound controls. These packet
            // types remain inert and cannot reach FarRelay control-plane state.
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
        } catch {
            fail("Unable to bind the audio UDP socket.")
        }
    }

    private func handleListenerState(_ state: NWListener.State, generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            listenerReadyAt = .now
            if receiverSnapshot.state == .connecting || receiverSnapshot.state == .reconnecting {
                receiverSnapshot.state = .authenticating
                publish()
            }
        case .failed:
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
                    let reply = await self.ingestAndPrepareReply(content)
                    if let reply {
                        await self.sendHeartbeatReply(reply, on: id, generation: generation)
                    }
                }
                if error == nil { await self.receiveNext(on: id, generation: generation) }
                else { await self.removeConnection(id, generation: generation) }
            }
        }
    }

    private func sendHeartbeatReply(_ reply: Data, on id: UUID, generation: Int) {
        guard generation == self.generation,
              let connection = inboundConnections[id]
        else { return }
        receiverSnapshot.statistics.heartbeatPongsSent += 1
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

    private func ingestFormat(_ payload: Data, streamID: UInt16) {
        guard let format = RemSoundFormat.parse(payload),
              let expectedFingerprint,
              let fingerprint = format.fingerprint
        else {
            dropPacket()
            return
        }
        guard RemSoundCrypto.fingerprintsMatch(fingerprint, expectedFingerprint) else {
            receiverSnapshot.statistics.authenticationFailures += 1
            fail("The sender password does not match.")
            return
        }
        activeStreamID = streamID
        activeFormat = format
        expectedSequence = nil
        assembler.reset()
        lastSenderActivity = .now
        receiverSnapshot.sampleRate = format.sampleRate
        receiverSnapshot.channelCount = format.channels
        receiverSnapshot.state = .buffering
        publish()
    }

    private func ingestAudio(_ payload: Data, streamID: UInt16, sequence: UInt32) {
        guard activeStreamID == streamID, let format = activeFormat, let key else {
            // A packet from a former stream cannot contaminate its replacement.
            dropPacket()
            return
        }
        guard acceptSequence(sequence) else { return }
        guard let part = RemSoundPCMPart.parse(payload),
              let encryptedFrame = assembler.append(part),
              let plaintext = RemSoundCrypto.decrypt(encryptedFrame, using: key),
              plaintext.count.isMultiple(of: 3)
        else {
            dropPacket()
            return
        }

        let frame = decodePCM24(plaintext, sampleRate: Double(format.sampleRate), channels: format.channels)
        guard queuedPCM.append(frame) else {
            receiverSnapshot.statistics.bufferDroppedFrames += frame.samples.count / format.channels
            dropPacket()
            return
        }
        lastSenderActivity = .now
        receiverSnapshot.statistics.bufferDepthFrames = queuedPCM.totalFrameCount
        if !playbackArmed, queuedPCM.totalFrameCount >= Self.startupBufferFrames {
            playbackArmed = true
        }
        guard playbackArmed else {
            publish()
            return
        }
        drainQueuedFrames()
        receiverSnapshot.state = .playing
        publish()
    }

    private func acceptSequence(_ sequence: UInt32) -> Bool {
        guard let expected = expectedSequence else {
            expectedSequence = sequence &+ 1
            return true
        }
        if sequence == expected {
            expectedSequence = sequence &+ 1
            return true
        }
        let forwardGap = sequence &- expected
        if forwardGap < 1_000_000 {
            receiverSnapshot.statistics.packetsLost += Int(forwardGap)
            expectedSequence = sequence &+ 1
            return true
        }
        if sequence == (expected &- 1) {
            receiverSnapshot.statistics.packetsDuplicated += 1
        } else {
            receiverSnapshot.statistics.packetsReordered += 1
        }
        receiverSnapshot.statistics.packetsDropped += 1
        publish()
        return false
    }

    private func decodePCM24(_ data: Data, sampleRate: Double, channels: Int) -> AudioPCMFrame {
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
        return AudioPCMFrame(samples: samples, sampleRate: sampleRate, channels: channels)
    }

    private func dropPacket() {
        receiverSnapshot.statistics.packetsDropped += 1
        publish()
    }

    private func fail(_ message: String) {
        receiverSnapshot.statistics.lastError = message
        receiverSnapshot.state = .failed(message)
        publish()
    }

    private func resetPipeline() {
        activeStreamID = nil
        activeFormat = nil
        expectedSequence = nil
        assembler.reset()
        queuedPCM = BoundedPCMQueue()
        playbackArmed = false
        listenerReadyAt = nil
        lastSenderActivity = nil
        key = nil
        expectedFingerprint = nil
    }

    private func stopNetwork() {
        senderWatchdog?.cancel()
        senderWatchdog = nil
        listener?.cancel()
        listener = nil
        for connection in inboundConnections.values { connection.cancel() }
        inboundConnections.removeAll()
    }

    private func publish() {
        for continuation in snapshotContinuations.values { continuation.yield(receiverSnapshot) }
    }

    private func removeConnection(_ id: UUID, generation: Int) {
        guard generation == self.generation else { return }
        inboundConnections.removeValue(forKey: id)
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

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == self.generation
    }

    private func drainQueuedFrames() {
        guard playbackArmed, !frameContinuations.isEmpty else { return }
        while let next = queuedPCM.popFirst() {
            receiverSnapshot.statistics.bufferDepthFrames = queuedPCM.totalFrameCount
            for continuation in frameContinuations.values {
                if case .dropped(let dropped) = continuation.yield(next) {
                    receiverSnapshot.statistics.bufferDroppedFrames += dropped.samples.count / max(dropped.channels, 1)
                }
            }
        }
    }
}

private struct AudioReceiverEndpoint: Sendable {
    let host: String
    let port: UInt16
}

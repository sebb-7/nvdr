import Foundation
import Observation

/// App-owned target-side protocol router. The SSH child is only a local-socket
/// proxy; this model is the sole owner of the input engine and controller lease.
@MainActor
@Observable
final class MacHostService {
    private(set) var socketStatus = "Stopped"
    private(set) var connectedSessionCount = 0
    private(set) var activeControllerID: String?
    private(set) var lastSpeechEventDate: Date?

    @ObservationIgnored private let input: MacRemoteInputEngine
    @ObservationIgnored private let inbox: RemoteSpeechInbox
    @ObservationIgnored private let readiness: MacHostReadinessModel
    @ObservationIgnored private var server: MacHostSocketServer?
    @ObservationIgnored private var subscribers: [Int32: @Sendable (String) -> Void] = [:]
    @ObservationIgnored private var controllerOwnerClientID: Int32?

    init(input: MacRemoteInputEngine, inbox: RemoteSpeechInbox, readiness: MacHostReadinessModel) {
        self.input = input
        self.inbox = inbox
        self.readiness = readiness
        inbox.onEvents = { [weak self] events in self?.publish(events) }
    }

    func startIfEnabled() {
        guard readiness.isEnabled else { stop(); return }
        guard server == nil else { return }
        do {
            let server = try MacHostSocketServer { [weak self] clientID, line, reply in
                Task { @MainActor in
                    reply(self?.handle(clientID: clientID, line: line, reply: reply) ?? MacHostProtocol.error(nil, code: "host_unavailable", message: "FarRelay is not running."))
                }
            } onClientClosed: { [weak self] clientID in
                Task { @MainActor in self?.disconnect(clientID: clientID) }
            }
            self.server = server
            socketStatus = "Ready"
            readiness.refresh(socketReady: true)
        } catch {
            socketStatus = "Error"
            readiness.refresh(socketReady: false)
        }
    }

    func stop() {
        input.revokeControl()
        activeControllerID = nil
        controllerOwnerClientID = nil
        connectedSessionCount = 0
        subscribers.removeAll()
        server?.stop()
        server = nil
        socketStatus = "Stopped"
        readiness.refresh(socketReady: false)
    }

    func emergencyStop() {
        input.revokeControl()
        activeControllerID = nil
    }

    func refreshSpeech() {
        if inbox.receivedEventCount > 0 { lastSpeechEventDate = inbox.lastReceivedAt }
    }

    func diagnostics() -> MacDiagnosticSnapshot {
        readiness.snapshot(
            socketReady: server != nil,
            controllerID: activeControllerID,
            lastEventDate: lastSpeechEventDate
        )
    }

    private func handle(clientID: Int32, line: String, reply: @escaping @Sendable (String) -> Void) -> String {
        guard line.utf8.count <= MacHostProtocol.maximumFrameBytes else {
            return MacHostProtocol.error(nil, code: "frame_too_large", message: "Host protocol frames are limited to 32 KiB.")
        }
        guard let request = try? JSONDecoder().decode(MacHostProtocol.Request.self, from: Data(line.utf8)) else {
            return MacHostProtocol.error(nil, code: "malformed_json", message: "Request is not valid JSON.")
        }
        guard request.version == 1, let requestID = request.requestID else {
            return MacHostProtocol.error(request.requestID, code: "invalid_request", message: "version 1 and request_id are required.")
        }
        switch request.operation {
        case "capabilities":
            return MacHostProtocol.success(requestID, value: ["protocol_version": 1, "host_implementation": "farrelay-host-proxy", "operations": ["host.status", "subscribe", "control.request", "control.release", "input.key", "emergency.stop"]])
        case "host.status":
            let snapshot = diagnostics()
            return MacHostProtocol.success(requestID, value: ["status": snapshot.readiness.label, "speech_events_received": snapshot.providerEventsReceived, "input_ready": snapshot.inputMonitoringGranted && snapshot.accessibilityGranted])
        case "subscribe":
            subscribers[clientID] = reply
            connectedSessionCount = subscribers.count
            return MacHostProtocol.success(requestID, value: ["subscribed": true])
        case "control.request":
            let controllerID = request.params?["controller_id"]?.stringValue ?? ""
            switch input.requestControl(controllerID: controllerID) {
            case .granted(let generation):
                activeControllerID = controllerID
                controllerOwnerClientID = clientID
                return MacHostProtocol.success(requestID, value: ["state": "granted", "generation": Int(generation)])
            case .busy:
                return MacHostProtocol.success(requestID, value: ["state": "busy"])
            }
        case "control.release":
            let controllerID = request.params?["controller_id"]?.stringValue ?? ""
            input.releaseControl(controllerID: controllerID)
            if activeControllerID == controllerID {
                activeControllerID = nil
                controllerOwnerClientID = nil
            }
            return MacHostProtocol.success(requestID, value: ["released": true])
        case "input.key":
            guard let controllerID = request.params?["controller_id"]?.stringValue,
                  let generation = request.params?["generation"]?.uint64Value,
                  let usage = request.params?["usage"]?.uint16Value,
                  let pressed = request.params?["pressed"]?.boolValue,
                  let key = RemoteKey(rawValue: usage) else {
                return MacHostProtocol.error(requestID, code: "invalid_parameters", message: "input.key requires controller_id, generation, usage, and pressed.")
            }
            let accepted = input.handle(RemoteKeyEvent(controllerID: controllerID, generation: generation, key: key, isPressed: pressed))
            return MacHostProtocol.success(requestID, value: ["accepted": accepted == .accepted(RemoteKeyEvent(controllerID: controllerID, generation: generation, key: key, isPressed: pressed))])
        case "emergency.stop":
            emergencyStop()
            return MacHostProtocol.success(requestID, value: ["stopped": true])
        default:
            return MacHostProtocol.error(requestID, code: "unsupported_operation", message: "Unsupported host operation.")
        }
    }

    private func disconnect(clientID: Int32) {
        subscribers.removeValue(forKey: clientID)
        connectedSessionCount = subscribers.count
        if controllerOwnerClientID == clientID {
            input.revokeControl()
            activeControllerID = nil
            controllerOwnerClientID = nil
        }
    }

    private func publish(_ events: [RemoteSpeechEvent]) {
        guard !subscribers.isEmpty else { return }
        lastSpeechEventDate = Date()
        for event in events {
            let name = event.kind == .cancel ? "speech.cancel" : "speech.utterance"
            guard let encoded = try? JSONEncoder().encode(event),
                  let object = try? JSONSerialization.jsonObject(with: encoded) else { continue }
            let frame = MacHostProtocol.event(name: name, payload: object)
            subscribers.values.forEach { $0(frame) }
        }
    }
}

enum MacHostProtocol {
    static let maximumFrameBytes = 32 * 1024

    struct Request: Decodable {
        let version: Int
        let requestID: String?
        let operation: String
        let params: [String: JSONValue]?

        enum CodingKeys: String, CodingKey { case version; case requestID = "request_id"; case operation; case params }
    }

    static func success(_ requestID: String, value: [String: Any]) -> String {
        encode(["version": 1, "request_id": requestID, "ok": true, "result": value])
    }

    static func error(_ requestID: String?, code: String, message: String) -> String {
        var response: [String: Any] = ["version": 1, "ok": false, "error": ["code": code, "message": String(message.prefix(256))]]
        if let requestID { response["request_id"] = requestID }
        return encode(response)
    }

    static func event(name: String, payload: Any) -> String {
        encode(["version": 1, "type": "event", "event": name, "payload": payload])
    }

    private static func encode(_ value: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{\"version\":1,\"ok\":false}".utf8)
        guard data.count <= maximumFrameBytes else {
            return "{\"error\":{\"code\":\"frame_too_large\",\"message\":\"Host response exceeds 32 KiB.\"},\"ok\":false,\"version\":1}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let value = try? value.decode(String.self) { self = .string(value) }
        else if let value = try? value.decode(Bool.self) { self = .bool(value) }
        else if let value = try? value.decode(Double.self) { self = .number(value) }
        else { self = .null }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var uint64Value: UInt64? { if case .number(let value) = self, value >= 0, value.rounded() == value { UInt64(value) } else { nil } }
    var uint16Value: UInt16? { uint64Value.flatMap { UInt16(exactly: $0) } }
}

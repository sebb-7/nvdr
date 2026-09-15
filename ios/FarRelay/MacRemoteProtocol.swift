import Foundation

/// USB HID keyboard usage IDs carried by the additive Mac Remote host protocol.
/// They are physical-key values, never Windows virtual-key values.
struct MacRemoteKey: Codable, Hashable, Sendable {
    let usage: UInt16

    static let rightArrow = Self(usage: 0x4F)
    static let leftArrow = Self(usage: 0x50)
    static let downArrow = Self(usage: 0x51)
    static let upArrow = Self(usage: 0x52)
    static let space = Self(usage: 0x2C)
    static let tab = Self(usage: 0x2B)
    static let returnKey = Self(usage: 0x28)
    static let escape = Self(usage: 0x29)
    static let leftControl = Self(usage: 0xE0)
    static let leftShift = Self(usage: 0xE1)
    static let leftOption = Self(usage: 0xE2)
    static let leftCommand = Self(usage: 0xE3)
}

struct MacRemoteSubscription: Codable, Equatable, Sendable {
    let subscribed: Bool
}

struct MacRemoteControlResult: Codable, Equatable, Sendable {
    let state: String
    let generation: UInt64?
}

struct MacRemoteKeyResult: Codable, Equatable, Sendable {
    let accepted: Bool
}

struct MacRemoteSpeechEvent: Codable, Equatable, Sendable {
    let generation: UUID
    let sequence: UInt64
    let kind: String
    let ssml: String?
    let plainText: String?

    enum CodingKeys: String, CodingKey {
        case generation, sequence, kind, ssml
        case plainText = "plain_text"
    }
}

struct MacRemoteHostEvent: Codable, Equatable, Sendable {
    let name: String
    let speech: MacRemoteSpeechEvent?

    enum CodingKeys: String, CodingKey {
        case name = "event"
        case speech = "payload"
    }
}

private struct MacRemoteSubscribeParameters: Encodable, Sendable { let events: [String] }
private struct MacRemoteControlParameters: Encodable, Sendable { let controllerID: String; enum CodingKeys: String, CodingKey { case controllerID = "controller_id" } }
private struct MacRemoteKeyParameters: Encodable, Sendable {
    let controllerID: String
    let generation: UInt64
    let usage: UInt16
    let pressed: Bool
    enum CodingKeys: String, CodingKey { case controllerID = "controller_id"; case generation, usage, pressed }
}

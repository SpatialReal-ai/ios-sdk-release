import Foundation
internal import SwiftProtobuf

/// The avatar's messages in Pipecat RTVI messages: `pipecat/v1/avatar.proto`, generated into
/// `Generated/avatar.pb.swift` (see `.github/workflows/protobuf-codegen.yml`). The JSON is proto3 JSON
/// with proto field names and base64 bytes; unknown keys are ignored, as the contract requires.
typealias AvatarMessage = Pipecat_V1_AvatarMessage

enum AvatarWire {
    /// `AvatarMessage.tag` / `AvatarClientMessage.tag`, and the RTVI client-message type.
    static let tag = "spatialreal-avatar"

    /// Decodes one server message the app forwards: Pipecat's `Value`, any other `Encodable`, a
    /// dictionary, or JSON `Data` / `String`; either the AvatarMessage itself or the whole RTVI envelope
    /// (`{"label": "rtvi-ai", "type": "server-message", "data": {...}}`). Nil for anything that is not
    /// the avatar's.
    static func decode(_ data: Any) -> AvatarMessage? {
        guard var dict = jsonObject(from: data) as? [String: Any] else { return nil }
        if dict["tag"] == nil, (dict["type"] as? String) == "server-message", let inner = dict["data"] as? [String: Any] {
            dict = inner
        }
        guard (dict["tag"] as? String) == tag, let json = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        return try? AvatarMessage(jsonUTF8Data: json, options: options)
    }

    /// `AvatarClientMessage{audio_request: {}}` as proto3 JSON with proto field names:
    /// `{"tag":"spatialreal-avatar","audio_request":{}}`.
    static func audioRequestJSON() -> Data {
        var message = Pipecat_V1_AvatarClientMessage()
        message.tag = tag
        message.audioRequest = Pipecat_V1_AudioRequest()
        var options = JSONEncodingOptions()
        options.preserveProtoFieldNames = true
        return (try? message.jsonUTF8Data(options: options)) ?? Data(#"{"tag":"spatialreal-avatar","audio_request":{}}"#.utf8)
    }

    private static func jsonObject(from data: Any) -> Any? {
        switch data {
        case let d as [String: Any]: return d
        case let d as Data: return try? JSONSerialization.jsonObject(with: d)
        case let s as String: return s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        case let e as any Encodable:
            guard let d = try? JSONEncoder().encode(e) else { return nil }
            return try? JSONSerialization.jsonObject(with: d)
        default: return nil
        }
    }
}

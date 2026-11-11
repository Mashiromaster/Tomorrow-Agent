import Foundation

/// A segment of a finished turn, in storable form.
///
/// Deliberately a value type with a flat `Codable` representation: this is
/// what goes in `StoredTurn.segmentsData`, and an enum with associated classes
/// would encode object identity that means nothing after a reload.
public enum TurnSegment: Codable, Sendable, Hashable {
    case thinking(String)
    case text(String)
    case tool(name: String, failed: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind, text, name, failed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "thinking":
            self = .thinking(try container.decode(String.self, forKey: .text))
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "tool":
            self = .tool(
                name: try container.decode(String.self, forKey: .name),
                failed: try container.decode(Bool.self, forKey: .failed)
            )
        case let other:
            // A segment kind written by a newer build. Rendering it as text
            // beats failing the whole conversation to decode — the user would
            // lose a transcript over a forward-compatibility problem.
            self = .text("[无法识别的内容：\(other)]")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .thinking(let text):
            try container.encode("thinking", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .text(let text):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .tool(let name, let failed):
            try container.encode("tool", forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(failed, forKey: .failed)
        }
    }
}

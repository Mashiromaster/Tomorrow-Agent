import Foundation

/// A tool the model may call. Every one of these executes **on the device**
/// (§7.2), so the definitions here are the full contract between the model and
/// the data layer.
public struct ToolDefinition: Sendable, Hashable, Codable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

/// The tool list sent with a request.
///
/// Tools render first in the cached prefix (§7.3), so their order is part of
/// the cache key. `ToolSet` sorts by name on construction — there is no way to
/// hold an unsorted set — because "remembered to sort the tools" is exactly
/// the kind of invariant that survives code review and then breaks six months
/// later when someone appends one.
public struct ToolSet: Sendable, Hashable {
    public let tools: [ToolDefinition]

    public init(_ tools: [ToolDefinition]) {
        self.tools = tools.sorted { $0.name < $1.name }
    }

    public var names: [String] { tools.map(\.name) }

    public func definition(named name: String) -> ToolDefinition? {
        tools.first { $0.name == name }
    }
}

/// The read-only tool surface from §7.2.
///
/// ## Why there is no `create_calendar_events`
///
/// Writing to the calendar is **not** a tool, and that absence is the single
/// most load-bearing security decision in the design (§7.2, §9.4). Content
/// shared into the app from the web is untrusted input; if the model were
/// compromised by prompt injection, the worst it can do is produce a bad
/// `ItineraryProposal`, which the user then sees and rejects. The commit path
/// runs in the UI layer after an explicit tap, so no amount of injected text
/// can reach EventKit.
///
/// `PAgentTools.standard` is therefore asserted in tests to contain no
/// mutating tool. Adding one here would quietly convert a structural guarantee
/// into a prompt-engineering one.
public enum PAgentTools {
    public static let searchCalendar = ToolDefinition(
        name: "search_calendar",
        description: """
            Find free time and existing commitments in a date range. Event \
            titles are returned as coarse categories (meeting / personal / \
            commute) rather than their real titles, unless the user has \
            explicitly allowed sending titles. Call this before proposing any \
            schedule so the proposal fits around what is already booked.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "start": ["type": "string", "description": "Inclusive ISO-8601 start of the range."],
                "end": ["type": "string", "description": "Exclusive ISO-8601 end of the range."],
            ],
            "required": ["start", "end"],
            "additionalProperties": false,
        ]
    )

    public static let searchPlaces = ToolDefinition(
        name: "search_places",
        description: """
            Search for places near a coordinate. Call this when the user asks \
            for somewhere to go, or when a proposal needs a concrete venue \
            rather than a category. Results come from the device's map data.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "What to search for, e.g. 独立书店."],
                "near": [
                    "type": "object",
                    "properties": [
                        "latitude": ["type": "number"],
                        "longitude": ["type": "number"],
                    ],
                    "required": ["latitude", "longitude"],
                    "additionalProperties": false,
                ],
                "radius_meters": ["type": "integer", "description": "Search radius in metres."],
                "open_at": ["type": "string", "description": "ISO-8601 time the place must be open."],
            ],
            "required": ["query", "near"],
            "additionalProperties": false,
        ]
    )

    public static let travelTime = ToolDefinition(
        name: "get_travel_time",
        description: """
            Estimated travel time between two coordinates for a departure \
            time. Call this between consecutive proposal items so the schedule \
            is actually reachable.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "from": [
                    "type": "object",
                    "properties": ["latitude": ["type": "number"], "longitude": ["type": "number"]],
                    "required": ["latitude", "longitude"],
                    "additionalProperties": false,
                ],
                "to": [
                    "type": "object",
                    "properties": ["latitude": ["type": "number"], "longitude": ["type": "number"]],
                    "required": ["latitude", "longitude"],
                    "additionalProperties": false,
                ],
                "mode": ["type": "string", "enum": ["walking", "transit", "driving"]],
                "depart_at": ["type": "string", "description": "ISO-8601 departure time."],
            ],
            "required": ["from", "to", "mode"],
            "additionalProperties": false,
        ]
    )

    public static let userProfile = ToolDefinition(
        name: "get_user_profile",
        description: """
            Read specific facets of the user's interest profile. The summary \
            card is already in the system prompt; call this only when you need \
            a facet it does not cover.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "facets": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["taste", "activity", "routine", "geography", "avoid"]],
                ]
            ],
            "required": ["facets"],
            "additionalProperties": false,
        ]
    )

    public static let routine = ToolDefinition(
        name: "get_routine",
        description: """
            The user's habitual pattern for a given weekday — typical wake and \
            sleep times, and when they are usually free. Call this when a \
            proposal needs to respect their rhythm rather than just empty \
            calendar slots.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "day_of_week": [
                    "type": "integer",
                    "description": "1 = Monday through 7 = Sunday.",
                ]
            ],
            "required": ["day_of_week"],
            "additionalProperties": false,
        ]
    )

    /// Every tool, read-only, deterministically ordered.
    public static let standard = ToolSet([
        searchCalendar,
        searchPlaces,
        travelTime,
        userProfile,
        routine,
    ])
}

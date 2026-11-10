import Foundation

// MARK: - Redaction

/// What a calendar event is, with the title removed.
///
/// §7.2: `search_calendar` returns the *time structure* of the user's day,
/// not its content. The model needs to know a 14:00 slot is taken; it does
/// not need to know the event is "和 X 谈离职".
public enum EventCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case meeting
    case personal
    case commute
    case travel
    /// Deliberately blocked-out working time.
    case focus
    /// Could not be classified. Treated as busy — a slot of unknown purpose
    /// is still a slot the user is not free in.
    case unknown

    /// A crude keyword classifier.
    ///
    /// Phase 2 replaces this with the on-device model, which is what §7.1
    /// routes `signalExtraction` to and what this kind of one-line
    /// classification is actually good at. Until Foundation Models is wired
    /// up, a keyword pass is better than labelling everything `.unknown`,
    /// and it has the useful property of being free and offline.
    ///
    /// Misclassification is cheap here: every category is equally busy, so
    /// getting it wrong costs the model a little context and costs the
    /// schedule nothing.
    public static func classify(title: String) -> EventCategory {
        let lowered = title.lowercased()
        func contains(_ needles: [String]) -> Bool {
            needles.contains { lowered.contains($0) }
        }

        if contains(["会", "meeting", "1:1", "standup", "评审", "review", "sync", "面试", "interview"]) {
            return .meeting
        }
        if contains(["通勤", "commute", "接送", "送娃"]) { return .commute }
        if contains(["航班", "flight", "高铁", "火车", "train", "出差", "trip"]) { return .travel }
        if contains(["专注", "focus", "deep work", "写作", "block"]) { return .focus }
        if contains(["生日", "birthday", "医院", "体检", "家庭", "family", "晚餐", "dinner"]) {
            return .personal
        }
        return .unknown
    }
}

/// A calendar event as the model is allowed to see it.
///
/// ## The title can only arrive through an explicit opt-in
///
/// `init` takes a `TitlePolicy`, and the raw title is stored *only* under
/// ``TitlePolicy/allowTitles``. There is no other initialiser and `title` is
/// `let`, so there is no path that carries a title into this type by
/// accident — which is the §7.2 guarantee ("除非用户显式开启") expressed in
/// the type rather than left to each call site to remember.
public struct RedactedEvent: Sendable, Hashable {
    /// Whether the user has turned on "allow sending calendar titles".
    public enum TitlePolicy: Sendable, Hashable {
        /// The default. The title is dropped at construction and never stored.
        case redact
        /// The user explicitly enabled title sharing in settings.
        case allowTitles
    }

    public let category: EventCategory
    public let interval: DateInterval
    public let isAllDay: Bool

    /// `nil` unless the policy was ``TitlePolicy/allowTitles``.
    public let title: String?

    public init(
        title rawTitle: String,
        category: EventCategory? = nil,
        interval: DateInterval,
        isAllDay: Bool = false,
        policy: TitlePolicy = .redact
    ) {
        self.category = category ?? EventCategory.classify(title: rawTitle)
        self.interval = interval
        self.isAllDay = isAllDay
        self.title = policy == .allowTitles ? rawTitle : nil
    }

    /// What the model sees for this event.
    ///
    /// The category when redacted, the real title when permitted.
    public var displayLabel: String {
        title ?? category.rawValue
    }
}

// MARK: - Free time

/// Interval arithmetic over a day's commitments.
///
/// Separated from EventKit on purpose: fetching events needs the SDK and a
/// permission prompt, while *this* is where the bugs live — merging
/// overlapping meetings, honouring a minimum usable duration, keeping a
/// travel buffer, deciding what an all-day event means. All of it is pure,
/// so all of it is tested.
public enum FreeTime {
    /// Merges overlapping and touching intervals into a minimal covering set.
    ///
    /// Touching counts as overlapping: a 14:00–15:00 and a 15:00–16:00
    /// meeting leave no usable gap between them, and reporting a zero-length
    /// free slot would be worse than useless.
    public static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }

        var merged: [DateInterval] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end {
                // `max` matters: a long meeting can fully contain a short one,
                // and taking `next.end` unconditionally would shrink the block.
                current = DateInterval(start: current.start, end: max(current.end, next.end))
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    /// The gaps in `window` not covered by `busy`.
    ///
    /// - Parameters:
    ///   - padding: Expands every busy block on both sides before merging, so
    ///     a slot that butts up against a meeting is not offered as usable.
    ///     The user cannot teleport out of a 15:00 call into a 15:00 dinner.
    ///   - minimumDuration: Slots shorter than this are dropped. A 7-minute
    ///     gap is noise, and offering it invites the model to schedule into it.
    public static func free(
        in window: DateInterval,
        busy: [DateInterval],
        padding: TimeInterval = 0,
        minimumDuration: TimeInterval = 0
    ) -> [DateInterval] {
        guard window.duration > 0 else { return [] }

        let padded = busy.compactMap { block -> DateInterval? in
            let start = block.start.addingTimeInterval(-max(0, padding))
            let end = block.end.addingTimeInterval(max(0, padding))
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }

        var slots: [DateInterval] = []
        var cursor = window.start

        for block in merge(padded) {
            // Entirely before the window, or entirely after it.
            if block.end <= cursor { continue }
            if block.start >= window.end { break }

            if block.start > cursor {
                slots.append(DateInterval(start: cursor, end: min(block.start, window.end)))
            }
            cursor = max(cursor, block.end)
            if cursor >= window.end { break }
        }

        if cursor < window.end {
            slots.append(DateInterval(start: cursor, end: window.end))
        }

        return slots.filter { $0.duration >= minimumDuration && $0.duration > 0 }
    }
}

// MARK: - Routine

/// When the user is typically awake.
///
/// Feeds the `get_routine` tool and clips free slots to hours the user would
/// actually accept — §6.3's "工作日 7:10 起 / 23:30 睡" line exists so a plan
/// does not propose breakfast at 05:00 just because the calendar was empty.
public struct DailyRoutine: Sendable, Hashable, Codable {
    /// Minutes from local midnight. 7:10 → 430.
    public let wakeMinutes: Int
    /// Minutes from local midnight. 23:30 → 1410. A value at or below
    /// `wakeMinutes` is read as the following morning (e.g. 00:30 → 30).
    public let sleepMinutes: Int

    public init(wakeMinutes: Int, sleepMinutes: Int) {
        precondition((0..<1440).contains(wakeMinutes), "wakeMinutes must be within a day")
        precondition((0..<1440).contains(sleepMinutes), "sleepMinutes must be within a day")
        self.wakeMinutes = wakeMinutes
        self.sleepMinutes = sleepMinutes
    }

    /// Whether the user's day runs past midnight.
    public var crossesMidnight: Bool { sleepMinutes <= wakeMinutes }

    /// The awake window on a given day, in the supplied calendar's timezone.
    ///
    /// Returns `nil` only if the calendar cannot resolve midnight for the
    /// date — a daylight-saving transition on a date that has no midnight,
    /// which exists in a handful of timezones.
    public func awakeWindow(on day: Date, in calendar: Calendar) -> DateInterval? {
        guard let midnight = calendar.dateInterval(of: .day, for: day)?.start else { return nil }
        let wake = midnight.addingTimeInterval(TimeInterval(wakeMinutes * 60))
        let sleepOffset = crossesMidnight ? sleepMinutes + 1440 : sleepMinutes
        let sleep = midnight.addingTimeInterval(TimeInterval(sleepOffset * 60))
        guard sleep > wake else { return nil }
        return DateInterval(start: wake, end: sleep)
    }
}

// MARK: - Composition

/// What `search_calendar` hands back to the model.
public struct Availability: Sendable, Hashable {
    public let day: DateInterval
    /// Usable gaps, already clipped to the awake window and filtered by
    /// minimum duration.
    public let freeSlots: [DateInterval]
    /// Existing commitments, titles redacted unless the user opted in.
    public let commitments: [RedactedEvent]

    public init(day: DateInterval, freeSlots: [DateInterval], commitments: [RedactedEvent]) {
        self.day = day
        self.freeSlots = freeSlots
        self.commitments = commitments
    }

    /// Computes availability for one day.
    ///
    /// - Parameter treatingAllDayAsBusy: `false` by default, which is a
    ///   judgement call worth naming: most all-day events are markers
    ///   ("某人生日", "报销截止") rather than commitments, and treating them
    ///   as busy would report a free user as fully booked. They stay in
    ///   `commitments` so the model can see them and reason about them — an
    ///   all-day "出差" should visibly discourage a local dinner plan even
    ///   though it blocks no specific hour.
    public static func forDay(
        _ day: Date,
        routine: DailyRoutine,
        events: [RedactedEvent],
        calendar: Calendar,
        padding: TimeInterval = 15 * 60,
        minimumDuration: TimeInterval = 30 * 60,
        treatingAllDayAsBusy: Bool = false
    ) -> Availability? {
        guard let dayInterval = calendar.dateInterval(of: .day, for: day),
            let awake = routine.awakeWindow(on: day, in: calendar)
        else { return nil }

        // An awake window that runs past midnight is still clipped to the day
        // being asked about; the caller asks again for tomorrow.
        let windowEnd = min(awake.end, dayInterval.end)
        guard windowEnd > awake.start else { return nil }
        let window = DateInterval(start: awake.start, end: windowEnd)

        let relevant = events.filter { $0.interval.intersects(dayInterval) }
        let busy = relevant
            .filter { treatingAllDayAsBusy || !$0.isAllDay }
            .map(\.interval)

        return Availability(
            day: dayInterval,
            freeSlots: FreeTime.free(
                in: window,
                busy: busy,
                padding: padding,
                minimumDuration: minimumDuration
            ),
            commitments: relevant.sorted { $0.interval.start < $1.interval.start }
        )
    }

    /// Total usable free time.
    public var totalFree: TimeInterval {
        freeSlots.reduce(0) { $0 + $1.duration }
    }
}

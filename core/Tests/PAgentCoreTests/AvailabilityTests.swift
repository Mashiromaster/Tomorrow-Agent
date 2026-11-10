import Foundation
import Testing

@testable import PAgentCore

/// Fixed calendar so nothing here depends on the machine's locale or zone.
private let shanghai = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

/// Saturday 2026-11-14, local midnight.
private let saturday = shanghai.date(
    from: DateComponents(year: 2026, month: 11, day: 14, hour: 0, minute: 0)
)!

private let minute: TimeInterval = 60
private let hour: TimeInterval = 3600

/// `at(14)` → Saturday 14:00; `at(14, 30)` → 14:30.
private func at(_ hours: Int, _ minutes: Int = 0) -> Date {
    saturday.addingTimeInterval(TimeInterval(hours) * hour + TimeInterval(minutes) * minute)
}

private func span(_ fromHour: Int, _ toHour: Int) -> DateInterval {
    DateInterval(start: at(fromHour), end: at(toHour))
}

/// Renders slots as `"14:00-18:00"` so failures are legible.
private func describe(_ intervals: [DateInterval]) -> [String] {
    let formatter = DateFormatter()
    formatter.calendar = shanghai
    formatter.timeZone = shanghai.timeZone
    formatter.dateFormat = "HH:mm"
    return intervals.map { "\(formatter.string(from: $0.start))-\(formatter.string(from: $0.end))" }
}

@Suite("EventCategory redaction")
struct EventCategoryTests {
    @Test("classifies common calendar titles")
    func classification() {
        #expect(EventCategory.classify(title: "周会") == .meeting)
        #expect(EventCategory.classify(title: "1:1 with Sam") == .meeting)
        #expect(EventCategory.classify(title: "设计评审") == .meeting)
        #expect(EventCategory.classify(title: "通勤") == .commute)
        #expect(EventCategory.classify(title: "飞往北京的航班") == .travel)
        #expect(EventCategory.classify(title: "专注写作") == .focus)
        #expect(EventCategory.classify(title: "妈妈生日") == .personal)
    }

    @Test("falls back to unknown rather than guessing")
    func unknownFallback() {
        // `.unknown` is still busy, so a wrong guess costs the model context
        // and costs the schedule nothing. Inventing a category would be worse.
        #expect(EventCategory.classify(title: "XJ-4471") == .unknown)
        #expect(EventCategory.classify(title: "") == .unknown)
    }

    @Test("drops the title by default and never stores it")
    func titleIsRedactedByDefault() {
        // §7.2: the model needs the time structure, not "和 X 谈离职".
        let event = RedactedEvent(
            title: "和 X 谈离职",
            interval: span(14, 15)
        )

        #expect(event.title == nil)
        #expect(event.displayLabel == "unknown")
        // The sensitive string is nowhere in the value.
        #expect(String(describing: event).contains("离职") == false)
    }

    @Test("keeps the title only under an explicit opt-in")
    func titleRequiresOptIn() {
        let allowed = RedactedEvent(
            title: "和 X 谈离职",
            interval: span(14, 15),
            policy: .allowTitles
        )
        #expect(allowed.title == "和 X 谈离职")
        #expect(allowed.displayLabel == "和 X 谈离职")
    }

    @Test("classifies from the title even when redacting it")
    func categoryDerivedBeforeRedaction() {
        // The classification is the useful residue of a title we then discard.
        let event = RedactedEvent(title: "产品评审会", interval: span(10, 11))
        #expect(event.category == .meeting)
        #expect(event.title == nil)
    }

    @Test("accepts an externally supplied category")
    func explicitCategory() {
        // Phase 2 replaces the keyword pass with the on-device model, which
        // will classify and hand the result in.
        let event = RedactedEvent(
            title: "XJ-4471",
            category: .travel,
            interval: span(8, 12)
        )
        #expect(event.category == .travel)
    }
}

@Suite("FreeTime.merge")
struct FreeTimeMergeTests {
    @Test("merges overlapping intervals")
    func mergesOverlaps() {
        let merged = FreeTime.merge([span(9, 11), span(10, 12)])
        #expect(describe(merged) == ["09:00-12:00"])
    }

    @Test("merges touching intervals, which leave no usable gap")
    func mergesTouching() {
        // 14:00-15:00 then 15:00-16:00 is one solid block. Reporting a
        // zero-length free slot between them would be worse than useless.
        let merged = FreeTime.merge([span(14, 15), span(15, 16)])
        #expect(describe(merged) == ["14:00-16:00"])
    }

    @Test("keeps disjoint intervals separate")
    func keepsDisjoint() {
        let merged = FreeTime.merge([span(9, 10), span(14, 15)])
        #expect(describe(merged) == ["09:00-10:00", "14:00-15:00"])
    }

    @Test("does not shrink a block that fully contains another")
    func containedIntervalDoesNotShrink() {
        // The `max(current.end, next.end)` case: a 9-17 all-hands containing
        // a 10-11 standup must stay 9-17.
        let merged = FreeTime.merge([span(9, 17), span(10, 11)])
        #expect(describe(merged) == ["09:00-17:00"])
    }

    @Test("sorts before merging, so input order does not matter")
    func inputOrderIrrelevant() {
        let forward = FreeTime.merge([span(9, 10), span(11, 12), span(13, 14)])
        let shuffled = FreeTime.merge([span(13, 14), span(9, 10), span(11, 12)])
        #expect(describe(forward) == describe(shuffled))
    }

    @Test("drops zero-length intervals")
    func dropsEmpty() {
        let merged = FreeTime.merge([
            DateInterval(start: at(10), end: at(10)),
            span(14, 15),
        ])
        #expect(describe(merged) == ["14:00-15:00"])
    }

    @Test("handles a chain where each interval extends the last")
    func chainedOverlaps() {
        let merged = FreeTime.merge([span(9, 10), span(10, 11), span(11, 12), span(12, 13)])
        #expect(describe(merged) == ["09:00-13:00"])
    }

    @Test("returns nothing for no input")
    func emptyInput() {
        #expect(FreeTime.merge([]).isEmpty)
    }
}

@Suite("FreeTime.free")
struct FreeTimeGapTests {
    @Test("returns the whole window when nothing is booked")
    func emptyCalendar() {
        let free = FreeTime.free(in: span(9, 18), busy: [])
        #expect(describe(free) == ["09:00-18:00"])
    }

    @Test("returns the gaps around booked blocks")
    func gapsAroundMeetings() {
        let free = FreeTime.free(in: span(9, 18), busy: [span(10, 11), span(14, 15)])
        #expect(describe(free) == ["09:00-10:00", "11:00-14:00", "15:00-18:00"])
    }

    @Test("returns nothing when the window is fully booked")
    func fullyBooked() {
        #expect(FreeTime.free(in: span(9, 18), busy: [span(8, 19)]).isEmpty)
    }

    @Test("clips busy blocks that extend past the window")
    func clipsOverhangingBlocks() {
        // An overnight flight 22:00-06:00 overlapping a 09:00-18:00 window
        // must not produce a negative or inverted slot.
        let free = FreeTime.free(in: span(9, 18), busy: [span(7, 10), span(17, 23)])
        #expect(describe(free) == ["10:00-17:00"])
    }

    @Test("ignores blocks entirely outside the window")
    func ignoresIrrelevantBlocks() {
        let free = FreeTime.free(in: span(14, 18), busy: [span(9, 10), span(20, 21)])
        #expect(describe(free) == ["14:00-18:00"])
    }

    @Test("keeps a travel buffer around each commitment")
    func paddingIsApplied() {
        // The user cannot teleport out of a 15:00 call into a 15:00 dinner.
        // 15 minutes either side of a 14:00-15:00 meeting.
        let free = FreeTime.free(
            in: span(9, 18),
            busy: [span(14, 15)],
            padding: 15 * minute
        )
        #expect(describe(free) == ["09:00-13:45", "15:15-18:00"])
    }

    @Test("padding can merge two meetings into one busy block")
    func paddingCausesMerge() {
        // 14:00-15:00 and 15:20-16:00 are 20 minutes apart; with 15 minutes
        // of padding each side the gap closes, and offering the 20 minutes
        // would be offering time that does not exist.
        let free = FreeTime.free(
            in: span(9, 18),
            busy: [span(14, 15), DateInterval(start: at(15, 20), end: at(16))],
            padding: 15 * minute
        )
        #expect(describe(free) == ["09:00-13:45", "16:15-18:00"])
    }

    @Test("drops slots below the minimum usable duration")
    func minimumDuration() {
        // A 20-minute gap between two meetings is noise; offering it invites
        // the model to schedule into it.
        let free = FreeTime.free(
            in: span(9, 18),
            busy: [span(10, 12), DateInterval(start: at(12, 20), end: at(15))],
            minimumDuration: 30 * minute
        )
        #expect(describe(free) == ["09:00-10:00", "15:00-18:00"])
    }

    @Test("keeps a slot exactly at the minimum")
    func minimumIsInclusive() {
        // Tight but usable. Dropping it would train the user to distrust the
        // free-slot list.
        let free = FreeTime.free(
            in: span(9, 18),
            busy: [span(10, 12), DateInterval(start: at(12, 30), end: at(15))],
            minimumDuration: 30 * minute
        )
        #expect(describe(free).contains("12:00-12:30"))
    }

    @Test("returns nothing for an empty or inverted window")
    func degenerateWindow() {
        #expect(FreeTime.free(in: DateInterval(start: at(14), end: at(14)), busy: []).isEmpty)
    }

    @Test("never returns an inverted or zero-length slot")
    func slotsAreAlwaysValid() {
        // Property check over a messy, overlapping, out-of-order schedule.
        let busy = [
            span(9, 11), span(10, 10), span(10, 14), span(13, 13),
            span(16, 18), span(17, 17), span(7, 9), span(18, 22),
        ]
        for padding in [0.0, 5 * minute, 30 * minute] {
            let free = FreeTime.free(
                in: span(8, 20),
                busy: busy,
                padding: padding,
                minimumDuration: 15 * minute
            )
            for slot in free {
                #expect(slot.duration > 0, "padding=\(padding)")
                #expect(slot.end > slot.start, "padding=\(padding)")
                #expect(slot.start >= at(8), "padding=\(padding)")
                #expect(slot.end <= at(20), "padding=\(padding)")
            }
            // And no two slots overlap.
            for (earlier, later) in zip(free, free.dropFirst()) {
                #expect(earlier.end <= later.start, "padding=\(padding)")
            }
        }
    }
}

@Suite("DailyRoutine")
struct DailyRoutineTests {
    @Test("resolves the awake window for a normal day")
    func normalDay() {
        // §6.3's "工作日 7:10 起 / 23:30 睡".
        let routine = DailyRoutine(wakeMinutes: 7 * 60 + 10, sleepMinutes: 23 * 60 + 30)
        let window = routine.awakeWindow(on: saturday, in: shanghai)

        #expect(window != nil)
        #expect(describe([window!]) == ["07:10-23:30"])
    }

    @Test("reads a past-midnight bedtime as the next morning")
    func crossesMidnight() {
        // 08:00 up, 01:00 to bed. Treating 01:00 as *earlier* than 08:00
        // would produce an inverted window and no free time at all.
        let routine = DailyRoutine(wakeMinutes: 8 * 60, sleepMinutes: 60)
        #expect(routine.crossesMidnight)

        let window = routine.awakeWindow(on: saturday, in: shanghai)
        #expect(window != nil)
        #expect(window!.start == at(8))
        #expect(window!.end == at(25))  // 01:00 the next day
        #expect(window!.duration == 17 * hour)
    }

    @Test("does not treat a normal evening bedtime as crossing midnight")
    func doesNotCrossMidnight() {
        let routine = DailyRoutine(wakeMinutes: 7 * 60, sleepMinutes: 23 * 60)
        #expect(routine.crossesMidnight == false)
    }

    @Test("resolves the window in the supplied calendar's timezone")
    func respectsTimeZone() {
        // The same instant is a different wall-clock hour elsewhere, so the
        // window must come from the calendar rather than the machine's zone.
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let routine = DailyRoutine(wakeMinutes: 7 * 60, sleepMinutes: 23 * 60)
        let shanghaiWindow = routine.awakeWindow(on: saturday, in: shanghai)
        let laWindow = routine.awakeWindow(on: saturday, in: losAngeles)

        #expect(shanghaiWindow != nil && laWindow != nil)
        #expect(shanghaiWindow!.start != laWindow!.start)
    }
}

@Suite("Availability")
struct AvailabilityTests {
    private let routine = DailyRoutine(wakeMinutes: 7 * 60 + 10, sleepMinutes: 23 * 60 + 30)

    @Test("computes free slots within the awake window")
    func freeWithinAwakeHours() {
        // The empty 03:00 hour is not offered: the calendar is clear, but the
        // user is asleep.
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [RedactedEvent(title: "午饭", interval: span(12, 13))],
            calendar: shanghai,
            padding: 0,
            minimumDuration: 30 * minute
        )

        #expect(availability != nil)
        #expect(describe(availability!.freeSlots) == ["07:10-12:00", "13:00-23:30"])
    }

    @Test("applies the default travel buffer and minimum duration")
    func appliesDefaults() {
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [RedactedEvent(title: "周会", interval: span(14, 15))],
            calendar: shanghai
        )

        // 15 minutes of padding by default.
        #expect(describe(availability!.freeSlots) == ["07:10-13:45", "15:15-23:30"])
    }

    @Test("keeps commitments in chronological order with titles redacted")
    func commitmentsAreOrderedAndRedacted() {
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [
                RedactedEvent(title: "晚餐", interval: span(18, 20)),
                RedactedEvent(title: "产品评审会", interval: span(10, 11)),
            ],
            calendar: shanghai
        )

        #expect(availability!.commitments.map(\.category) == [.meeting, .personal])
        #expect(availability!.commitments.allSatisfy { $0.title == nil })
    }

    @Test("an all-day event does not blank out the day")
    func allDayIsNotBusyByDefault() {
        // Most all-day entries are markers ("某人生日", "报销截止"), not
        // commitments. Treating them as busy would report a free user as
        // fully booked — which is the more damaging error of the two.
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [
                RedactedEvent(
                    title: "妈妈生日",
                    interval: DateInterval(start: saturday, end: at(24)),
                    isAllDay: true
                )
            ],
            calendar: shanghai
        )

        #expect(describe(availability!.freeSlots) == ["07:10-23:30"])
        // It stays visible, so the model can still reason about it.
        #expect(availability!.commitments.count == 1)
    }

    @Test("an all-day event can be treated as busy when the caller asks")
    func allDayCanBeBusy() {
        // An all-day "出差" genuinely does block the day.
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [
                RedactedEvent(
                    title: "出差",
                    interval: DateInterval(start: saturday, end: at(24)),
                    isAllDay: true
                )
            ],
            calendar: shanghai,
            treatingAllDayAsBusy: true
        )

        #expect(availability!.freeSlots.isEmpty)
    }

    @Test("ignores events on other days but keeps those that overlap")
    func filtersByDay() {
        let friday = saturday.addingTimeInterval(-12 * hour)
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [
                RedactedEvent(title: "周五的会", interval: DateInterval(start: friday, end: friday.addingTimeInterval(hour))),
                // Crosses into Saturday morning, so it is relevant.
                RedactedEvent(title: "夜间航班", interval: DateInterval(start: at(-2), end: at(8))),
            ],
            calendar: shanghai,
            padding: 0
        )

        #expect(availability!.commitments.count == 1)
        #expect(availability!.commitments[0].category == .travel)
        // The flight consumes the morning up to 08:00.
        #expect(describe(availability!.freeSlots) == ["08:00-23:30"])
    }

    @Test("reports a fully booked day as having no free time")
    func fullyBookedDay() {
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [RedactedEvent(title: "全天会议", interval: span(6, 24))],
            calendar: shanghai
        )

        #expect(availability!.freeSlots.isEmpty)
        #expect(availability!.totalFree == 0)
    }

    @Test("sums total free time")
    func totalFree() {
        let availability = Availability.forDay(
            saturday,
            routine: routine,
            events: [RedactedEvent(title: "午饭", interval: span(12, 13))],
            calendar: shanghai,
            padding: 0
        )

        // 07:10-12:00 is 4h50m, 13:00-23:30 is 10h30m.
        #expect(availability!.totalFree == (4 * hour + 50 * minute) + (10 * hour + 30 * minute))
    }

    @Test("clips a past-midnight awake window to the day being asked about")
    func lateNightRoutineIsClippedToTheDay() {
        // A night owl's window runs to 01:00, but a question about Saturday
        // should not hand back Sunday's early hours — the caller asks again
        // for Sunday.
        let nightOwl = DailyRoutine(wakeMinutes: 10 * 60, sleepMinutes: 60)
        let availability = Availability.forDay(
            saturday,
            routine: nightOwl,
            events: [],
            calendar: shanghai
        )

        #expect(describe(availability!.freeSlots) == ["10:00-00:00"])
        #expect(availability!.freeSlots.last!.end == at(24))
    }
}

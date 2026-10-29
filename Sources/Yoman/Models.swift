import AppKit
import EventKit
import SwiftUI

// MARK: - View modes

enum ViewMode: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", schedule = "Schedule"
    var id: String { rawValue }
}

// MARK: - Calendars (EventKit or Google)

struct CalendarInfo: Identifiable, Hashable {
    enum Backend: Hashable {
        case eventKit
        case google(account: String)
    }

    /// EventKit calendar identifier, or `google:<account>:<calendarId>`.
    let id: String
    /// EventKit identifier or Google calendarId.
    let remoteID: String
    let title: String
    let nsColor: NSColor
    let isWritable: Bool
    let sourceTitle: String
    let backend: Backend
    var defaultAlerts: [Int] = []

    var color: Color { Color(nsColor: nsColor) }
    var isGoogle: Bool { if case .google = backend { true } else { false } }

    init(ek c: EKCalendar) {
        id = c.calendarIdentifier
        remoteID = c.calendarIdentifier
        title = c.title
        nsColor = c.color ?? .systemBlue
        isWritable = c.allowsContentModifications
        sourceTitle = c.source?.title ?? "Other"
        backend = .eventKit
    }

    init(googleAccount: String, calendarID: String, title: String, color: NSColor, writable: Bool, defaultAlerts: [Int]) {
        id = "google:\(googleAccount):\(calendarID)"
        remoteID = calendarID
        self.title = title
        nsColor = color
        isWritable = writable
        sourceTitle = googleAccount
        backend = .google(account: googleAccount)
        self.defaultAlerts = defaultAlerts
    }

    static func == (a: CalendarInfo, b: CalendarInfo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct CalendarGroup: Identifiable {
    let id: String
    let title: String
    let calendars: [CalendarInfo]
    var warning: String? = nil
}

// MARK: - Event (EventKit or Google)

struct Attendee: Hashable {
    enum Status: String { case accepted, declined, tentative, needsAction }
    let name: String
    let email: String
    let status: Status
    let isSelf: Bool
    let isOrganizer: Bool
}

struct GoogleEventRef {
    let account: String
    let calendarID: String
    let eventID: String
    /// Set for an instance of a recurring event.
    let seriesID: String?
    /// Attendee objects exactly as Google returned them, so an RSVP PATCH doesn't drop fields.
    let rawAttendees: [[String: Any]]
}

struct CalEvent: Identifiable, Hashable {
    enum Origin {
        case eventKit(EKEvent)
        case google(GoogleEventRef)
        case demo
    }

    let id: String
    let origin: Origin
    let calendar: CalendarInfo
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    var colorOverride: NSColor? = nil
    var location: String? = nil
    var notes: String? = nil
    var url: URL? = nil
    var meetingURL: URL? = nil
    var recurrence: Recurrence = .none
    var isRecurring = false
    var attendees: [Attendee] = []
    var alertMinutes: [Int] = []
    var webLink: URL? = nil

    init(id: String, origin: Origin, calendar: CalendarInfo, title: String?, start: Date, end: Date, isAllDay: Bool) {
        self.id = id
        self.origin = origin
        self.calendar = calendar
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = t.isEmpty ? "(No title)" : t
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    init(ek: EKEvent, calendar: CalendarInfo) {
        self.init(id: "\(ek.calendarItemIdentifier)|\(ek.startDate.timeIntervalSince1970)", origin: .eventKit(ek),
                  calendar: calendar, title: ek.title, start: ek.startDate, end: ek.endDate, isAllDay: ek.isAllDay)
        location = ek.location?.isEmpty == false ? ek.location : nil
        notes = ek.notes?.isEmpty == false ? ek.notes : nil
        url = ek.url
        meetingURL = MeetingLink.cached(for: ek)
        isRecurring = ek.hasRecurrenceRules
        recurrence = Recurrence(ek.recurrenceRules?.first?.frequency)
        alertMinutes = ek.alarms?.map { Int(-$0.relativeOffset / 60) } ?? []
        attendees = (ek.attendees ?? []).map { a in
            let status: Attendee.Status = switch a.participantStatus {
            case .accepted: .accepted
            case .declined: .declined
            case .tentative: .tentative
            default: .needsAction
            }
            return Attendee(name: a.name ?? "", email: a.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                            status: status, isSelf: a.isCurrentUser, isOrganizer: ek.organizer?.url == a.url)
        }
    }

    var ekEvent: EKEvent? { if case .eventKit(let e) = origin { e } else { nil } }
    var isDemo: Bool { if case .demo = origin { true } else { false } }
    var googleRef: GoogleEventRef? { if case .google(let r) = origin { r } else { nil } }

    /// Rendered in the all-day lane rather than the time grid (Google Calendar behaviour).
    var isLaneEvent: Bool { isAllDay || end.timeIntervalSince(start) >= 24 * 3600 }
    var nsColor: NSColor { colorOverride ?? calendar.nsColor }
    var color: Color { Color(nsColor: nsColor) }
    var calendarTitle: String { calendar.title }
    var isEditable: Bool { calendar.isWritable }
    var selfAttendee: Attendee? { attendees.first(where: \.isSelf) }
    var isDeclined: Bool { selfAttendee?.status == .declined }

    static func == (a: CalEvent, b: CalEvent) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func timeRange(_ cal: Calendar) -> String {
        if isAllDay { return "All day" }
        return Fmt.range(start, end)
    }

    func longDateLine(_ cal: Calendar) -> String {
        if isAllDay {
            let last = end.addingTimeInterval(-1)
            if cal.isDate(start, inSameDayAs: last) { return Fmt.f(start, "EEEEMMMMd") }
            return "\(Fmt.f(start, "EEEMMMd")) – \(Fmt.f(last, "EEEMMMd"))"
        }
        if cal.isDate(start, inSameDayAs: end) {
            return "\(Fmt.f(start, "EEEEMMMMd")) · \(Fmt.time(start)) – \(Fmt.time(end))"
        }
        return "\(Fmt.f(start, "EEEMMMd")) \(Fmt.time(start)) – \(Fmt.f(end, "EEEMMMd")) \(Fmt.time(end))"
    }
}

// MARK: - Editing

enum Recurrence: String, CaseIterable, Identifiable {
    case none = "Does not repeat", daily = "Daily", weekly = "Weekly", monthly = "Monthly", yearly = "Yearly"
    var id: String { rawValue }

    var frequency: EKRecurrenceFrequency? {
        switch self {
        case .none: nil
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
    }

    init(_ f: EKRecurrenceFrequency?) {
        switch f {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        default: self = .none
        }
    }
}

struct EventDraft: Identifiable {
    let id = UUID()
    var existing: CalEvent?
    var title = ""
    var start: Date
    var end: Date
    var allDay = false
    var calendarID: String
    var location = ""
    var url = ""
    var notes = ""
    /// Minutes before start; nil = no alert.
    var alertMinutes: Int? = 10
    var recurrence: Recurrence = .none
    var applyToFuture = false
    /// Google calendars only: create a Google Meet link.
    var addMeet = false

    static let alertChoices: [Int?] = [nil, 0, 5, 10, 15, 30, 60, 1440]

    static func alertLabel(_ m: Int?) -> String {
        switch m {
        case nil: "No notification"
        case 0: "At time of event"
        case 1440: "1 day before"
        case 60: "1 hour before"
        case let m?: "\(m) minutes before"
        }
    }
}

// MARK: - Meeting links

enum MeetingLink {
    private static let markers = [
        "zoom.us/j/", "zoom.us/my/", "zoomgov.com/j/", "meet.google.com/", "teams.microsoft.com/l/meetup-join",
        "teams.live.com/meet", "webex.com/", "whereby.com/", "facetime.apple.com/join", "chime.aws/", "around.co/",
    ]
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Detection runs a data detector over notes, which can be long; cache it per event revision.
    private static var cache: [String: URL?] = [:]

    static func cached(for e: EKEvent) -> URL? {
        let key = "\(e.calendarItemIdentifier)|\(e.lastModifiedDate?.timeIntervalSince1970 ?? 0)"
        if let hit = cache[key] { return hit }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        let url = find(in: [e.url?.absoluteString, e.location, e.notes])
        cache[key] = url
        return url
    }

    static func find(in texts: [String?]) -> URL? {
        for t in texts.compactMap({ $0 }) {
            let matches = detector?.matches(in: t, range: NSRange(t.startIndex..., in: t)) ?? []
            for m in matches {
                if let u = m.url, markers.contains(where: { u.absoluteString.contains($0) }) { return u }
            }
        }
        return nil
    }

    static func service(_ url: URL) -> String {
        let s = url.absoluteString
        if s.contains("zoom") { return "Zoom" }
        if s.contains("meet.google") { return "Google Meet" }
        if s.contains("teams.") { return "Microsoft Teams" }
        if s.contains("webex") { return "Webex" }
        if s.contains("facetime") { return "FaceTime" }
        return "meeting"
    }
}

// MARK: - Dates

extension Calendar {
    func startOfWeek(for date: Date) -> Date {
        let d = startOfDay(for: date)
        let diff = (component(.weekday, from: d) - firstWeekday + 7) % 7
        return self.date(byAdding: .day, value: -diff, to: d)!
    }

    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }

    func days(from start: Date, count: Int) -> [Date] {
        (0..<count).map { self.date(byAdding: .day, value: $0, to: start)! }
    }

    /// Position on a 0–24 h grid by wall-clock time, so days with a DST change (23 or 25 hours long)
    /// still line up with the hour labels. Clamped to the day.
    func wallHours(_ date: Date, dayStart: Date) -> Double {
        if date <= dayStart { return 0 }
        guard let next = self.date(byAdding: .day, value: 1, to: dayStart), date < next else { return 24 }
        let c = dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    /// The date at a wall-clock offset (in hours) from the start of a day.
    func wallClock(_ dayStart: Date, hours: Double) -> Date {
        let h = Int(hours), m = Int((hours - Double(h)) * 60)
        return date(bySettingHour: min(h, 23), minute: m, second: 0, of: dayStart) ?? dayStart
    }

    /// Weekday symbols ordered by `firstWeekday`.
    func orderedWeekdaySymbols(_ symbols: [String]) -> [String] {
        let i = firstWeekday - 1
        return Array(symbols[i...] + symbols[..<i])
    }
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSinceReferenceDate }
}

enum Fmt {
    private static var cache: [String: DateFormatter] = [:]

    static func f(_ date: Date, _ template: String) -> String {
        if let df = cache[template] { return df.string(from: date) }
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate(template)
        cache[template] = df
        return df.string(from: date)
    }

    static func time(_ date: Date) -> String { f(date, "jmm") }

    /// "20:30 – 22:30" wrapped in a left-to-right isolate, so it doesn't flip when the
    /// surrounding text (a Hebrew title or location) makes the line right-to-left.
    static func range(_ start: Date, _ end: Date) -> String {
        "\u{2066}\(time(start)) – \(time(end))\u{2069}"
    }

    /// A single time, isolated the same way.
    static func ltrTime(_ date: Date) -> String { "\u{2066}\(time(date))\u{2069}" }

    static func hourLabel(_ hour: Int) -> String {
        let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return f(d, "j")
    }

    static func relative(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }
}

import AppKit
import Foundation

/// `--demo`: replaces real calendars with a fictional week (for screenshots, videos and trying the UI
/// without granting calendar access). Nothing here touches EventKit or Google.
enum Demo {
    static let enabled = CommandLine.arguments.contains("--demo")
    /// `--select=<title>`: the popup opens with this event's detail card showing.
    static let selectTitle: String? = CommandLine.arguments.first { $0.hasPrefix("--select=") }.map { String($0.dropFirst(9)) }

    private static func cal(_ account: String, _ id: String, _ title: String, _ hex: String) -> CalendarInfo {
        CalendarInfo(googleAccount: account, calendarID: id, title: title, color: NSColor(hex: hex) ?? .systemBlue,
                     writable: true, defaultAlerts: [10])
    }

    static let work = cal("you@acme.dev", "you@acme.dev", "you@acme.dev", "#039BE5")
    static let team = cal("you@acme.dev", "team", "Team rituals", "#7986CB")
    static let holidays = cal("you@acme.dev", "holidays", "Holidays", "#33B679")
    static let personal = cal("Personal", "personal", "Personal", "#F4511E")
    static let gym = cal("Personal", "gym", "Gym", "#0B8043")

    static let groups: [CalendarGroup] = [
        CalendarGroup(id: "demo:work", title: "you@acme.dev", calendars: [work, team, holidays]),
        CalendarGroup(id: "demo:personal", title: "Personal", calendars: [personal, gym]),
    ]

    private static let meet = URL(string: "https://meet.google.com/abc-defg-hij")
    private static let zoom = URL(string: "https://acme.zoom.us/j/1234567890")
    private static let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/demo")

    private struct Spec {
        var day: Int          // offset from the start of this week
        var start: Double     // hour, e.g. 11.25 = 11:15
        var end: Double
        var title: String
        var cal: CalendarInfo
        var link: URL? = nil
        var rsvp: Attendee.Status? = nil
        var location: String? = nil
        var allDayDays: Int = 0  // > 0: all-day event spanning this many days
    }

    static func events(in interval: DateInterval) -> [CalEvent] {
        let c = Calendar.current
        let weekStart = c.startOfWeek(for: Date())
        var specs: [Spec] = []

        // This week, Sun–Sat (workweek Sun–Thu).
        for d in 0..<5 {
            specs.append(Spec(day: d, start: 9, end: 9.25, title: "Daily standup", cal: team, link: meet, rsvp: .accepted))
        }
        specs += [
            Spec(day: 1, start: 0, end: 0, title: "Release week 🚢", cal: work, allDayDays: 4),
            Spec(day: 0, start: 11, end: 12, title: "Sprint planning", cal: work, link: meet, rsvp: .accepted),
            Spec(day: 0, start: 16, end: 16.75, title: "Coffee with Noa", cal: personal, location: "Café Levinsky"),
            Spec(day: 1, start: 10.5, end: 11.25, title: "Customer call", cal: work, link: zoom, rsvp: .accepted),
            Spec(day: 1, start: 14, end: 15, title: "Interview: iOS engineer", cal: work, link: meet, rsvp: .accepted),
            Spec(day: 2, start: 12, end: 13.5, title: "Architecture review", cal: work, link: meet, rsvp: .needsAction),
            Spec(day: 2, start: 19, end: 20, title: "Yoga", cal: gym),
            // Today
            Spec(day: 3, start: 9.5, end: 10.5, title: "Focus time", cal: work),
            Spec(day: 3, start: 11, end: 12, title: "Design review", cal: work, link: meet, rsvp: .accepted, location: "Room 4 / Meet"),
            Spec(day: 3, start: 11.5, end: 12.25, title: "Roadmap sync", cal: work, link: zoom, rsvp: .needsAction),
            Spec(day: 3, start: 13, end: 14, title: "Lunch with Maya", cal: personal, location: "Port Said"),
            Spec(day: 3, start: 14.5, end: 15.5, title: "Ship Yoman 1.0 🚀", cal: work, rsvp: .accepted),
            Spec(day: 3, start: 16, end: 16.5, title: "1:1 with Dana", cal: work, link: teams, rsvp: .tentative),
            Spec(day: 3, start: 18.5, end: 19.5, title: "Gym", cal: gym),
            Spec(day: 4, start: 15, end: 16, title: "Retro", cal: team, link: meet, rsvp: .accepted),
            Spec(day: 4, start: 17.5, end: 19, title: "Happy hour 🍻", cal: personal, location: "Rooftop"),
            Spec(day: 5, start: 10.5, end: 12, title: "Brunch", cal: personal),
            Spec(day: 6, start: 0, end: 0, title: "Halloween 🎃", cal: holidays, allDayDays: 1),
            Spec(day: 6, start: 8, end: 11, title: "Hike", cal: personal),
        ]

        // Other weeks: a believable rhythm so month views aren't empty.
        let rotation: [(String, CalendarInfo, Double, URL?)] = [
            ("Sprint planning", work, 11, meet), ("Customer call", work, 14, zoom), ("Design crit", work, 12, meet),
            ("1:1 with Dana", work, 16, teams), ("Interview", work, 13, meet), ("Retro", team, 15, meet),
        ]
        for d in -35..<42 where !(0..<7).contains(d) {
            guard let date = c.date(byAdding: .day, value: d, to: weekStart), !c.isDateInWeekend(date) else { continue }
            specs.append(Spec(day: d, start: 9, end: 9.25, title: "Daily standup", cal: team, link: meet, rsvp: .accepted))
            let r = rotation[(d % rotation.count + rotation.count) % rotation.count]
            specs.append(Spec(day: d, start: r.2, end: r.2 + 1, title: r.0, cal: r.1, link: r.3, rsvp: .accepted))
            if d % 3 == 0 { specs.append(Spec(day: d, start: 18.5, end: 19.5, title: d % 2 == 0 ? "Gym" : "Yoga", cal: gym)) }
        }

        return specs.enumerated().compactMap { i, s -> CalEvent? in
            guard let day = c.date(byAdding: .day, value: s.day, to: weekStart) else { return nil }
            let start: Date, end: Date
            if s.allDayDays > 0 {
                start = day
                end = c.date(byAdding: .day, value: s.allDayDays, to: day)!
            } else {
                start = c.wallClock(day, hours: s.start)
                end = c.wallClock(day, hours: s.end)
            }
            guard start < interval.end, end > interval.start else { return nil }
            var e = CalEvent(id: "demo|\(i)", origin: .demo, calendar: s.cal, title: s.title,
                             start: start, end: end, isAllDay: s.allDayDays > 0)
            e.meetingURL = s.link
            e.location = s.location ?? s.link?.absoluteString
            if let r = s.rsvp {
                e.attendees = [
                    Attendee(name: "You", email: "you@acme.dev", status: r, isSelf: true, isOrganizer: false),
                    Attendee(name: "Maya Levi", email: "maya@acme.dev", status: .accepted, isSelf: false, isOrganizer: true),
                    Attendee(name: "Dana Cohen", email: "dana@acme.dev", status: .accepted, isSelf: false, isOrganizer: false),
                    Attendee(name: "Omer Katz", email: "omer@acme.dev", status: .tentative, isSelf: false, isOrganizer: false),
                ]
            }
            e.alertMinutes = s.allDayDays > 0 ? [] : [10]
            if s.title == "Design review" {
                e.notes = "Walk through the new popup: List · Day · Week · Month.\nBring feedback on the weekend highlight."
            }
            return e
        }
    }
}

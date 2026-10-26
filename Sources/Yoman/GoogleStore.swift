import AppKit
import Foundation
import Observation

/// Google Calendar API backend: signed-in accounts, their calendar lists, and a month-keyed event cache.
/// `CalendarModel.fetch` reads the cache synchronously; missing months load in the background and
/// `onChange` fires when they arrive.
@MainActor
@Observable
final class GoogleStore {
    struct Account: Identifiable {
        let email: String
        var calendars: [CalendarInfo] = []
        var error: String?
        var id: String { email }
    }

    @ObservationIgnored let auth = GoogleAuth()
    @ObservationIgnored var onChange: () -> Void = {}

    var accounts: [Account] = []
    var signingIn = false
    var lastError: String?

    @ObservationIgnored private var cache: [String: [CalEvent]] = [:]  // "email|monthStart" → events
    @ObservationIgnored private var loaded: Set<String> = []
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var eventPalette: [String: [String: NSColor]] = [:]  // email → colorId → color
    @ObservationIgnored private var lastRefresh = Date.distantPast

    private static let api = "https://www.googleapis.com/calendar/v3"
    private var savedEmails: [String] {
        get { UserDefaults.standard.stringArray(forKey: "googleAccounts") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "googleAccounts") }
    }

    func start() {
        accounts = savedEmails.map { Account(email: $0) }
        for a in accounts { Task { await loadCalendars(a.email) } }
    }

    var allCalendars: [CalendarInfo] { accounts.flatMap(\.calendars) }

    // MARK: Accounts

    func signIn() async {
        signingIn = true
        lastError = nil
        defer { signingIn = false }
        do {
            let (email, _) = try await auth.signIn()
            if !savedEmails.contains(email) { savedEmails.append(email) }
            if !accounts.contains(where: { $0.email == email }) { accounts.append(Account(email: email)) }
            await loadCalendars(email)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut(_ email: String) {
        auth.signOut(email)
        savedEmails.removeAll { $0 == email }
        accounts.removeAll { $0.email == email }
        cache = cache.filter { !$0.key.hasPrefix(email + "|") }
        loaded = loaded.filter { !$0.hasPrefix(email + "|") }
        onChange()
    }

    // MARK: Reading

    func loadCalendars(_ email: String) async {
        guard accounts.contains(where: { $0.email == email }) else { return }
        do {
            let colors = try await request(email, "GET", "/colors")
            var palette: [String: NSColor] = [:]
            for (k, v) in (colors["event"] as? [String: [String: Any]]) ?? [:] {
                if let hex = v["background"] as? String { palette[k] = NSColor(hex: hex) }
            }
            eventPalette[email] = palette

            var items: [[String: Any]] = []
            var page: String?
            repeat {
                var q = [URLQueryItem(name: "maxResults", value: "250")]
                if let page { q.append(.init(name: "pageToken", value: page)) }
                let json = try await request(email, "GET", "/users/me/calendarList", query: q)
                items += (json["items"] as? [[String: Any]]) ?? []
                page = json["nextPageToken"] as? String
            } while page != nil

            let known = Set(UserDefaults.standard.stringArray(forKey: "knownGoogleCalendars") ?? [])
            var newlyKnown = known
            let cals: [CalendarInfo] = items.compactMap { c in
                guard let id = c["id"] as? String else { return nil }
                let role = c["accessRole"] as? String ?? "reader"
                let reminders = (c["defaultReminders"] as? [[String: Any]] ?? []).compactMap { $0["minutes"] as? Int }
                let info = CalendarInfo(
                    googleAccount: email, calendarID: id,
                    title: (c["summaryOverride"] as? String) ?? (c["summary"] as? String) ?? id,
                    color: NSColor(hex: c["backgroundColor"] as? String ?? "") ?? .systemBlue,
                    writable: role == "owner" || role == "writer",
                    defaultAlerts: reminders)
                // Respect Google's own "show in list" checkbox the first time we see a calendar.
                if !known.contains(info.id) {
                    newlyKnown.insert(info.id)
                    if (c["selected"] as? Bool) != true { Prefs.shared.hiddenCalendarIDs.insert(info.id) }
                }
                return info
            }
            .sorted { a, b in
                // Primary (the email-named calendar) first, then alphabetical.
                if (a.remoteID == email) != (b.remoteID == email) { return a.remoteID == email }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            UserDefaults.standard.set(Array(newlyKnown), forKey: "knownGoogleCalendars")
            if let i = accounts.firstIndex(where: { $0.email == email }) {
                accounts[i].calendars = cals
                accounts[i].error = nil
            }
        } catch {
            if let i = accounts.firstIndex(where: { $0.email == email }) { accounts[i].error = error.localizedDescription }
        }
        onChange()
    }

    /// Cached events in `interval` for the given visible calendars; schedules loads for uncached months.
    func events(in interval: DateInterval, visible: Set<String>, load: Bool = true) -> [CalEvent] {
        let months = Self.months(covering: interval)
        var seen = Set<String>()
        var out: [CalEvent] = []
        for a in accounts {
            for m in months {
                let key = "\(a.email)|\(m.timeIntervalSince1970)"
                if load, !loaded.contains(key), !inflight.contains(key) {
                    inflight.insert(key)
                    Task { await loadMonth(a.email, m) }
                }
                for e in cache[key] ?? [] where visible.contains(e.calendar.id)
                    && e.start < interval.end && (e.end > interval.start || e.start == interval.start)
                    && seen.insert(e.id).inserted {
                    out.append(e)
                }
            }
        }
        return out
    }

    /// Re-pulls calendar lists and every cached month (at most once a minute unless forced).
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = Date()
        for a in accounts { Task { await loadCalendars(a.email) } }
        for key in loaded where !inflight.contains(key) {
            let parts = key.split(separator: "|")
            guard parts.count == 2, let t = Double(parts[1]) else { continue }
            inflight.insert(key)
            Task { await loadMonth(String(parts[0]), Date(timeIntervalSince1970: t)) }
        }
    }

    private func loadMonth(_ email: String, _ monthStart: Date) async {
        let key = "\(email)|\(monthStart.timeIntervalSince1970)"
        defer { inflight.remove(key) }
        guard let account = accounts.first(where: { $0.email == email }) else { return }
        let monthEnd = Calendar.current.date(byAdding: .month, value: 1, to: monthStart)!
        var result: [CalEvent] = []
        do {
            for cal in account.calendars {
                var page: String?
                repeat {
                    var q: [URLQueryItem] = [
                        .init(name: "timeMin", value: Self.iso.string(from: monthStart)),
                        .init(name: "timeMax", value: Self.iso.string(from: monthEnd)),
                        .init(name: "singleEvents", value: "true"),
                        .init(name: "maxResults", value: "2500"),
                    ]
                    if let page { q.append(.init(name: "pageToken", value: page)) }
                    let json = try await request(email, "GET", "/calendars/\(Self.pathEscape(cal.remoteID))/events", query: q)
                    result += ((json["items"] as? [[String: Any]]) ?? []).compactMap { parseEvent($0, calendar: cal, email: email) }
                    page = json["nextPageToken"] as? String
                } while page != nil
            }
            cache[key] = result
            loaded.insert(key)
            onChange()
        } catch {
            if let i = accounts.firstIndex(where: { $0.email == email }) { accounts[i].error = error.localizedDescription }
        }
    }

    private func parseEvent(_ e: [String: Any], calendar: CalendarInfo, email: String) -> CalEvent? {
        guard let id = e["id"] as? String, (e["status"] as? String) != "cancelled",
              let (start, allDay) = Self.parseDate(e["start"]), let (end, _) = Self.parseDate(e["end"]) else { return nil }
        let rawAttendees = (e["attendees"] as? [[String: Any]]) ?? []
        let ref = GoogleEventRef(account: email, calendarID: calendar.remoteID, eventID: id,
                                 seriesID: e["recurringEventId"] as? String, rawAttendees: rawAttendees)
        var ev = CalEvent(id: "g|\(calendar.id)|\(id)", origin: .google(ref), calendar: calendar,
                          title: e["summary"] as? String, start: start, end: end, isAllDay: allDay)
        if let colorID = e["colorId"] as? String { ev.colorOverride = eventPalette[email]?[colorID] }
        ev.location = (e["location"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ev.notes = (e["description"] as? String).flatMap { $0.isEmpty ? nil : Self.stripHTML($0) }
        ev.url = ((e["source"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
        ev.webLink = (e["htmlLink"] as? String).flatMap(URL.init(string:))
        let video = ((e["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]])?
            .first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
        ev.meetingURL = (e["hangoutLink"] as? String ?? video).flatMap(URL.init(string:))
            ?? MeetingLink.find(in: [ev.location, ev.notes, ev.url?.absoluteString])
        ev.isRecurring = ref.seriesID != nil
        ev.attendees = rawAttendees.map { a in
            Attendee(name: a["displayName"] as? String ?? "", email: a["email"] as? String ?? "",
                     status: Attendee.Status(rawValue: a["responseStatus"] as? String ?? "") ?? .needsAction,
                     isSelf: a["self"] as? Bool ?? false, isOrganizer: a["organizer"] as? Bool ?? false)
        }
        let reminders = e["reminders"] as? [String: Any]
        if reminders?["useDefault"] as? Bool ?? true {
            ev.alertMinutes = calendar.defaultAlerts
        } else {
            ev.alertMinutes = ((reminders?["overrides"] as? [[String: Any]]) ?? []).compactMap { $0["minutes"] as? Int }
        }
        return ev
    }

    // MARK: Writing

    func save(_ d: EventDraft, calendar: CalendarInfo) async throws {
        guard case .google(let email) = calendar.backend else { return }
        var body: [String: Any] = ["summary": d.title.isEmpty ? "(No title)" : d.title]
        let cal = Calendar.current
        if d.allDay {
            let last = cal.startOfDay(for: max(d.end, d.start))
            body["start"] = ["date": Self.ymd.string(from: d.start)]
            body["end"] = ["date": Self.ymd.string(from: cal.date(byAdding: .day, value: 1, to: last)!)]
        } else {
            let tz = TimeZone.current.identifier
            body["start"] = ["dateTime": Self.iso.string(from: d.start), "timeZone": tz]
            body["end"] = ["dateTime": Self.iso.string(from: max(d.end, d.start)), "timeZone": tz]
        }
        body["location"] = d.location
        body["description"] = d.notes
        if let u = URL(string: d.url), u.scheme?.hasPrefix("http") == true {
            body["source"] = ["title": u.host ?? "Link", "url": d.url]
        }
        body["reminders"] = ["useDefault": false,
                             "overrides": d.alertMinutes.map { [["method": "popup", "minutes": $0]] } ?? []]
        var query: [URLQueryItem] = []
        if d.addMeet, d.existing?.meetingURL == nil {
            body["conferenceData"] = ["createRequest": ["requestId": UUID().uuidString,
                                                        "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
            query.append(.init(name: "conferenceDataVersion", value: "1"))
        }

        let calPath = "/calendars/\(Self.pathEscape(calendar.remoteID))/events"
        if let existing = d.existing, let ref = existing.googleRef {
            var target = ref.eventID
            if d.applyToFuture, let series = ref.seriesID {
                // Whole series: change details but not this instance's time.
                target = series
                body["start"] = nil
                body["end"] = nil
            }
            if ref.seriesID == nil, d.recurrence != existing.recurrence {
                body["recurrence"] = d.recurrence.rrule.map { [$0] } ?? []
            }
            if ref.calendarID != calendar.remoteID {
                _ = try await request(email, "POST", "/calendars/\(Self.pathEscape(ref.calendarID))/events/\(Self.pathEscape(target))/move",
                                      query: [.init(name: "destination", value: calendar.remoteID)])
            }
            _ = try await request(email, "PATCH", "\(calPath)/\(Self.pathEscape(target))", query: query, body: body)
        } else {
            if let r = d.recurrence.rrule { body["recurrence"] = [r] }
            _ = try await request(email, "POST", calPath, query: query, body: body)
        }
        invalidate(email)
    }

    func delete(_ e: CalEvent, wholeSeries: Bool) async throws {
        guard let ref = e.googleRef else { return }
        let target = wholeSeries ? (ref.seriesID ?? ref.eventID) : ref.eventID
        _ = try await request(ref.account, "DELETE", "/calendars/\(Self.pathEscape(ref.calendarID))/events/\(Self.pathEscape(target))")
        invalidate(ref.account)
    }

    func rsvp(_ e: CalEvent, _ status: Attendee.Status) async throws {
        guard let ref = e.googleRef else { return }
        let attendees = ref.rawAttendees.map { a -> [String: Any] in
            var a = a
            if a["self"] as? Bool == true { a["responseStatus"] = status.rawValue }
            return a
        }
        _ = try await request(ref.account, "PATCH", "/calendars/\(Self.pathEscape(ref.calendarID))/events/\(Self.pathEscape(ref.eventID))",
                              query: [.init(name: "sendUpdates", value: "all")], body: ["attendees": attendees])
        invalidate(ref.account)
    }

    private func invalidate(_ email: String) {
        loaded = loaded.filter { !$0.hasPrefix(email + "|") }
        onChange()
    }

    // MARK: HTTP

    @discardableResult
    private func request(_ email: String, _ method: String, _ path: String,
                         query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await auth.accessToken(for: email)
        var c = URLComponents(string: Self.api + path)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw GoogleError.api("Google Calendar: \(msg)")
        }
        return json
    }

    // MARK: Parsing helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parseDate(_ any: Any?) -> (Date, Bool)? {
        guard let o = any as? [String: Any] else { return nil }
        if let s = o["dateTime"] as? String, let d = iso.date(from: s) ?? isoFractional.date(from: s) { return (d, false) }
        if let s = o["date"] as? String, let d = ymd.date(from: s) { return (d, true) }
        return nil
    }

    private static func months(covering interval: DateInterval) -> [Date] {
        let cal = Calendar.current
        var m = cal.date(from: cal.dateComponents([.year, .month], from: interval.start))!
        var out: [Date] = []
        while m < interval.end {
            out.append(m)
            m = cal.date(byAdding: .month, value: 1, to: m)!
        }
        return out
    }

    private static func pathEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Google descriptions are often HTML; keep the text and links.
    private static func stripHTML(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var t = s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
        t = t.replacingOccurrences(of: "<a[^>]*href=\"([^\"]+)\"[^>]*>[^<]*</a>", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Recurrence {
    var rrule: String? {
        switch self {
        case .none: nil
        case .daily: "RRULE:FREQ=DAILY"
        case .weekly: "RRULE:FREQ=WEEKLY"
        case .monthly: "RRULE:FREQ=MONTHLY"
        case .yearly: "RRULE:FREQ=YEARLY"
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

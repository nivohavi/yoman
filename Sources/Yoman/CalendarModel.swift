import AppKit
import EventKit
import Observation
import SwiftUI

/// Single source of truth. Merges two backends:
/// - EventKit (every account macOS syncs — iCloud, Exchange, Google via Internet Accounts), optional;
/// - Google Calendar API accounts signed in directly in Yoman (`GoogleStore`).
@MainActor
@Observable
final class CalendarModel {
    enum Access { case unknown, granted, denied, disabled }

    @ObservationIgnored let store = EKEventStore()
    let google = GoogleStore()
    let prefs = Prefs.shared

    /// EventKit access; `.disabled` when the user turned Apple Calendar off.
    var access: Access = .unknown
    var groups: [CalendarGroup] = []
    var events: [CalEvent] = []
    var upcoming: [CalEvent] = []
    var revision = 0
    var now = Date()

    var mode: ViewMode = .week { didSet { reload() } }
    var anchor: Date = .now { didSet { reload() } }

    var searchText = ""
    var searchResults: [CalEvent] = []

    var selected: CalEvent?
    var draft: EventDraft?
    var errorMessage: String?
    var busy = false
    /// Launch flag `--date=YYYY-MM-DD`: the popup opens on this day instead of today (for checking a specific day).
    /// Testing: `--switch-to=YYYY-MM-DD` selects this day a few seconds after the popup opens, like a click would.
    @ObservationIgnored var switchDate: Date? = {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--switch-to=") }) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(arg.dropFirst(12)))
    }()
    @ObservationIgnored var launchDate: Date? = {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--date=") }) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(arg.dropFirst(7)))
    }()
    /// Keeps the menu-bar popup open when it loses focus (Itsycal's "pin").
    var pinned = false { didSet { onPinChange(pinned) } }

    // Hooks wired up by the AppDelegate.
    @ObservationIgnored var onUpcomingChange: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var openWindow: () -> Void = {}
    @ObservationIgnored var closePopover: () -> Void = {}
    @ObservationIgnored var onPinChange: (Bool) -> Void = { _ in }

    @ObservationIgnored private var ekCalendars: [CalendarInfo] = []

    var cal: Calendar { prefs.calendar }
    private var appleEnabled: Bool { prefs.useAppleCalendars && access == .granted }

    /// Something to show: Apple access, or at least one Google account.
    var hasAnySource: Bool { Demo.enabled || appleEnabled || !google.accounts.isEmpty }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
        google.onChange = { [weak self] in self?.storeChanged() }
        google.start()
    }

    // MARK: Access

    func requestAccess() async {
        if Demo.enabled {
            access = .disabled
            storeChanged()
            return
        }
        guard prefs.useAppleCalendars else {
            access = .disabled
            storeChanged()
            return
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
        case .denied, .restricted, .writeOnly:
            access = .denied
        default:
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            access = ok ? .granted : .denied
        }
        storeChanged()
    }

    func appleCalendarsToggled() {
        Task { await requestAccess() }
    }

    /// EventKit posts change notifications in bursts while syncing; handle each burst once.
    @ObservationIgnored private var pendingChange: DispatchWorkItem?

    func storeChanged() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.loadCalendars()
            self.reload()
            self.reloadUpcoming()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Number of full-calendar views on screen (window or full popup). `events` is only kept
    /// up to date while one is visible; the compact popup fetches its own range.
    @ObservationIgnored var fullViews = 0 {
        didSet { if fullViews > 0 && oldValue == 0 { reload() } else if fullViews == 0 { events = [] } }
    }

    func refreshNow() {
        now = Date()
        if appleEnabled { store.refreshSourcesIfNecessary() }
        google.refresh()
        reloadUpcoming()
    }

    // MARK: Calendars

    private func loadCalendars() {
        if Demo.enabled {
            groups = Demo.groups
            return
        }
        ekCalendars = appleEnabled ? store.calendars(for: .event).map(CalendarInfo.init(ek:)) : []
        var appleGroups = Dictionary(grouping: ekCalendars, by: \.sourceTitle)
            .map { title, cals in
                CalendarGroup(id: "ek:\(title)", title: title,
                              calendars: cals.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !google.accounts.isEmpty {
            // Make clear which entries come through macOS rather than Yoman's own Google sign-in.
            appleGroups = appleGroups.map { CalendarGroup(id: $0.id, title: "\($0.title) (via macOS)", calendars: $0.calendars) }
        }
        let googleGroups = google.accounts.map {
            CalendarGroup(id: "google:\($0.email)", title: $0.email, calendars: $0.calendars, warning: $0.error)
        }
        groups = googleGroups + appleGroups
    }

    var allCalendars: [CalendarInfo] { groups.flatMap(\.calendars) }
    var visibleCalendars: [CalendarInfo] { allCalendars.filter(isVisible) }
    var writableCalendars: [CalendarInfo] { allCalendars.filter(\.isWritable) }

    func isVisible(_ c: CalendarInfo) -> Bool { !prefs.hiddenCalendarIDs.contains(c.id) }

    func toggle(_ c: CalendarInfo) {
        if isVisible(c) { prefs.hiddenCalendarIDs.insert(c.id) } else { prefs.hiddenCalendarIDs.remove(c.id) }
        calendarsChanged()
    }

    func showOnly(_ c: CalendarInfo) {
        prefs.hiddenCalendarIDs = Set(allCalendars.map(\.id)).subtracting([c.id])
        calendarsChanged()
    }

    func setGroup(_ g: CalendarGroup, visible: Bool) {
        let ids = Set(g.calendars.map(\.id))
        if visible { prefs.hiddenCalendarIDs.subtract(ids) } else { prefs.hiddenCalendarIDs.formUnion(ids) }
        calendarsChanged()
    }

    private func calendarsChanged() {
        reload()
        reloadUpcoming()
        if !searchText.isEmpty { runSearch() }
    }

    var defaultCalendar: CalendarInfo? {
        let writable = writableCalendars
        if let c = writable.first(where: { $0.id == prefs.defaultCalendarID }) { return c }
        // Prefer a Google primary calendar, then macOS's default.
        if let g = writable.first(where: { c in google.accounts.contains { $0.email == c.remoteID } }) { return g }
        if appleEnabled, let ek = store.defaultCalendarForNewEvents,
           let c = writable.first(where: { $0.id == ek.calendarIdentifier }) { return c }
        return writable.first
    }

    func calendar(withID id: String) -> CalendarInfo? { allCalendars.first { $0.id == id } }

    // MARK: Fetching

    var visibleRange: DateInterval {
        switch mode {
        case .day:
            let s = cal.startOfDay(for: anchor)
            return DateInterval(start: s, end: cal.date(byAdding: .day, value: 1, to: s)!)
        case .week:
            let s = cal.startOfWeek(for: anchor)
            return DateInterval(start: s, end: cal.date(byAdding: .day, value: 7, to: s)!)
        case .month:
            let s = cal.startOfWeek(for: cal.startOfMonth(for: anchor))
            return DateInterval(start: s, end: cal.date(byAdding: .day, value: 42, to: s)!)
        case .schedule:
            let s = cal.startOfDay(for: anchor)
            return DateInterval(start: s, end: cal.date(byAdding: .day, value: 45, to: s)!)
        }
    }

    /// Events from both backends. Google months that aren't cached yet load in the background
    /// (unless `load` is false) and trigger a reload when they arrive.
    func fetch(_ interval: DateInterval, load: Bool = true) -> [CalEvent] {
        let visible = Set(visibleCalendars.map(\.id))
        var out: [CalEvent] = []
        if Demo.enabled { out = Demo.events(in: interval).filter { visible.contains($0.calendar.id) } }
        if appleEnabled {
            let ekCals = ekCalendars.filter { visible.contains($0.id) }
            let byID = Dictionary(uniqueKeysWithValues: ekCals.map { ($0.id, $0) })
            let cals = ekCals.compactMap { store.calendar(withIdentifier: $0.id) }
            if !cals.isEmpty {
                let p = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: cals)
                autoreleasepool {
                    out += store.events(matching: p).compactMap { e in
                        e.calendar.flatMap { byID[$0.calendarIdentifier] }.map { CalEvent(ek: e, calendar: $0) }
                    }
                }
            }
        }
        if !Demo.enabled { out += google.events(in: interval, visible: visible, load: load) }
        return out
            .filter { !(prefs.hideDeclined && $0.isDeclined) }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                if a.start != b.start { return a.start < b.start }
                return a.end > b.end
            }
    }

    func reload() {
        guard fullViews > 0 else { revision += 1; return }
        events = fetch(visibleRange)
        if let s = selected { selected = events.first { $0.id == s.id } ?? s }
        revision += 1
    }

    func reloadUpcoming() {
        now = Date()
        upcoming = fetch(DateInterval(start: now.addingTimeInterval(-12 * 3600), duration: 48 * 3600))
            .filter { !$0.isAllDay && !$0.isDeclined }
        onUpcomingChange()
    }

    func events(on day: Date, from list: [CalEvent]? = nil) -> [CalEvent] {
        let s = cal.startOfDay(for: day)
        let e = cal.date(byAdding: .day, value: 1, to: s)!
        return (list ?? events).filter { ($0.start < e && $0.end > s) || $0.start == s }
    }

    /// The ongoing or next timed event, used by the menu bar and the sidebar "Up next" card.
    var nextEvent: CalEvent? {
        upcoming.first { $0.end > now && $0.start > now.addingTimeInterval(-15 * 60) }
            ?? upcoming.first { $0.end > now }
    }

    func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; return }
        let s = cal.date(byAdding: .month, value: -6, to: now)!
        let e = cal.date(byAdding: .month, value: 12, to: now)!
        // Google: search what's already cached rather than pulling 18 months.
        searchResults = fetch(DateInterval(start: s, end: e), load: false).filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.location?.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.notes?.localizedCaseInsensitiveContains(q) ?? false)
                || $0.calendarTitle.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: Navigation

    func step(_ dir: Int) {
        switch mode {
        case .day: anchor = cal.date(byAdding: .day, value: dir, to: anchor)!
        case .week: anchor = cal.date(byAdding: .day, value: 7 * dir, to: anchor)!
        case .month: anchor = cal.date(byAdding: .month, value: dir, to: anchor)!
        case .schedule: anchor = cal.date(byAdding: .day, value: 14 * dir, to: anchor)!
        }
    }

    func goToday() { anchor = Date() }

    func open(day: Date) {
        anchor = day
        mode = .day
    }

    var title: String {
        switch mode {
        case .day: return Fmt.f(anchor, "EEEEMMMMdy")
        case .week:
            let r = visibleRange
            let last = r.end.addingTimeInterval(-1)
            if cal.isDate(r.start, equalTo: last, toGranularity: .month) { return Fmt.f(r.start, "MMMMy") }
            if cal.isDate(r.start, equalTo: last, toGranularity: .year) {
                return "\(Fmt.f(r.start, "MMM")) – \(Fmt.f(last, "MMMy"))"
            }
            return "\(Fmt.f(r.start, "MMMy")) – \(Fmt.f(last, "MMMy"))"
        case .month, .schedule: return Fmt.f(anchor, "MMMMy")
        }
    }

    // MARK: Editing

    func newDraft(start: Date? = nil, allDay: Bool = false) {
        let base: Date
        if let start { base = start } else {
            // Next half hour on the anchor day.
            let n = Date()
            let day = cal.isDate(anchor, inSameDayAs: n) ? n : cal.date(bySettingHour: 9, minute: 0, second: 0, of: anchor)!
            let m = cal.component(.minute, from: day)
            base = cal.date(byAdding: .minute, value: (30 - m % 30) % 30, to: cal.date(bySetting: .second, value: 0, of: day) ?? day)!
        }
        selected = nil
        errorMessage = nil
        draft = EventDraft(
            start: base,
            end: allDay ? base : base.addingTimeInterval(TimeInterval(prefs.defaultDuration * 60)),
            allDay: allDay,
            calendarID: defaultCalendar?.id ?? "")
    }

    func edit(_ e: CalEvent) {
        selected = nil
        errorMessage = nil
        draft = EventDraft(
            existing: e,
            title: e.title == "(No title)" ? "" : e.title,
            start: e.start,
            end: e.isAllDay ? e.end.addingTimeInterval(-1) : e.end,
            allDay: e.isAllDay,
            calendarID: e.calendar.id,
            location: e.location ?? "",
            url: e.url?.absoluteString ?? "",
            notes: e.notes ?? "",
            alertMinutes: e.alertMinutes.first,
            recurrence: e.recurrence)
    }

    func duplicate(_ e: CalEvent) {
        edit(e)
        draft?.existing = nil
        draft?.title = (draft?.title ?? "") + " (copy)"
    }

    func save(_ d: EventDraft) {
        guard let target = calendar(withID: d.calendarID) else {
            errorMessage = "Choose a calendar."
            return
        }
        if target.isGoogle || d.existing?.googleRef != nil {
            guard target.isGoogle else {
                errorMessage = "Moving a Google event to a macOS calendar isn't supported."
                return
            }
            busy = true
            Task {
                defer { busy = false }
                do {
                    try await google.save(d, calendar: target)
                    draft = nil
                    anchor = d.start
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        saveToEventKit(d, calendar: target)
    }

    private func saveToEventKit(_ d: EventDraft, calendar target: CalendarInfo) {
        let existing = d.existing?.ekEvent
        let ev = existing ?? EKEvent(eventStore: store)
        ev.title = d.title.isEmpty ? "(No title)" : d.title
        ev.isAllDay = d.allDay
        ev.startDate = d.allDay ? cal.startOfDay(for: d.start) : d.start
        ev.endDate = d.allDay ? cal.startOfDay(for: max(d.end, d.start)) : max(d.end, d.start)
        if let c = store.calendar(withIdentifier: target.remoteID) { ev.calendar = c }
        ev.location = d.location.isEmpty ? nil : d.location
        ev.url = d.url.isEmpty ? nil : URL(string: d.url)
        ev.notes = d.notes.isEmpty ? nil : d.notes
        ev.alarms = d.alertMinutes.map { [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))] } ?? []
        if existing == nil || d.recurrence != d.existing?.recurrence {
            ev.recurrenceRules = d.recurrence.frequency.map { [EKRecurrenceRule(recurrenceWith: $0, interval: 1, end: nil)] }
        }
        do {
            try store.save(ev, span: d.applyToFuture ? .futureEvents : .thisEvent, commit: true)
            draft = nil
            anchor = ev.startDate
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ e: CalEvent, future: Bool = false) {
        if e.googleRef != nil {
            Task {
                do {
                    try await google.delete(e, wholeSeries: future)
                    selected = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        guard let ek = e.ekEvent else { return }
        do {
            try store.remove(ek, span: future ? .futureEvents : .thisEvent, commit: true)
            selected = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rsvp(_ e: CalEvent, _ status: Attendee.Status) {
        Task {
            do { try await google.rsvp(e, status) } catch { errorMessage = error.localizedDescription }
        }
    }

    /// For a Google event synced by macOS, the link to that exact occurrence on calendar.google.com.
    /// The iCal UID is "<googleEventId>@google.com"; a recurring occurrence's id gets "_<start in UTC>",
    /// and Google's `eid` is base64("<eventId> <calendarId>"). Falls back to a search when the
    /// calendar's Google address isn't known (e.g. a personal calendar titled with your name).
    func googleWebLink(for e: CalEvent) -> URL? {
        if let link = e.webLink { return link }
        guard let ek = e.ekEvent, let ext = ek.calendarItemExternalIdentifier, ext.contains("@google.com") else { return nil }
        var id = ext.components(separatedBy: "@google.com")[0]
        if ext.contains("/RID=") || ek.hasRecurrenceRules {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = ek.isAllDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
            if ek.isAllDay { f.timeZone = .current }
            id += "_" + f.string(from: ek.startDate)
        }
        let account = [e.calendar.title, e.calendar.sourceTitle].first { $0.contains("@") }
        guard let account else {
            let q = e.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return URL(string: "https://calendar.google.com/calendar/r/search?q=\(q)")
        }
        let eid = Data("\(id) \(account)".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return URL(string: "https://calendar.google.com/calendar/event?eid=\(eid)&authuser=\(account)")
    }

    /// Opens the event's page in Google Calendar, where you can accept or decline.
    func respondInGoogle(_ e: CalEvent) {
        guard let url = googleWebLink(for: e) else { return }
        NSWorkspace.shared.open(url)
        closePopover()
    }

    func openInCalendarApp(_ e: CalEvent? = nil) {
        if let link = e?.webLink {
            NSWorkspace.shared.open(link)
        } else if let ek = e?.ekEvent,
                  let id = (ek.eventIdentifier ?? ek.calendarItemIdentifier).addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else if !prefs.useAppleCalendars || !google.accounts.isEmpty {
            NSWorkspace.shared.open(URL(string: "https://calendar.google.com/calendar/r")!)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
        closePopover()
    }

    func join(_ e: CalEvent) {
        guard let url = e.meetingURL else { return }
        NSWorkspace.shared.open(url)
        closePopover()
    }
}

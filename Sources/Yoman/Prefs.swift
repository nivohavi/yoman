import Foundation
import Observation

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case dayIcon = "Day-number icon"
    case iconAndDate = "Icon + date"
    case dateOnly = "Date only"
    case iconOnly = "Icon only"
    var id: String { rawValue }
}

enum PopupStyle: String, CaseIterable, Identifiable {
    case compact = "Compact (month + agenda)", full = "Full calendar"
    var id: String { rawValue }
}

enum PopupDayStyle: String, CaseIterable, Identifiable {
    case list = "List", day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }
}

enum MiniMonthSize: String, CaseIterable, Identifiable {
    case compact = "Compact", regular = "Regular", large = "Large"
    var id: String { rawValue }
    /// Day circle diameter, day-number font size, event-dot diameter.
    var circle: CGFloat { switch self { case .compact: 22; case .regular: 26; case .large: 30 } }
    var font: CGFloat { switch self { case .compact: 11; case .regular: 12; case .large: 13 } }
    var dot: CGFloat { switch self { case .compact: 3.5; case .regular: 4; case .large: 4.5 } }
    var rowSpacing: CGFloat { switch self { case .compact: 0; case .regular: 1; case .large: 2 } }
}

enum PopoverSize: String, CaseIterable, Identifiable {
    case compact = "Compact", regular = "Regular", large = "Large"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .compact: CGSize(width: 780, height: 520)
        case .regular: CGSize(width: 920, height: 620)
        case .large: CGSize(width: 1080, height: 720)
        }
    }
}

/// UserDefaults-backed preferences. Every change fires `onChange` so the status item can refresh.
@Observable
final class Prefs {
    static let shared = Prefs()
    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored var onChange: (() -> Void)?

    var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
    var menuBarDateTemplate: String { didSet { save(menuBarDateTemplate, "menuBarDateTemplate") } }
    var showNextEvent: Bool { didSet { save(showNextEvent, "showNextEvent") } }
    var nextEventLookahead: Int { didSet { save(nextEventLookahead, "nextEventLookahead") } }
    /// 0 = system default, 1 = Sunday … 7 = Saturday.
    var firstWeekday: Int { didSet { save(firstWeekday, "firstWeekday") } }
    var highlightWeekends: Bool { didSet { save(highlightWeekends, "highlightWeekends") } }
    var showWeekNumbers: Bool { didSet { save(showWeekNumbers, "showWeekNumbers") } }
    var hourHeight: Double { didSet { save(hourHeight, "hourHeight") } }
    var useAppleCalendars: Bool { didSet { save(useAppleCalendars, "useAppleCalendars") } }
    var popupStyle: PopupStyle { didSet { save(popupStyle.rawValue, "popupStyle") } }
    var popupDayStyle: PopupDayStyle { didSet { save(popupDayStyle.rawValue, "popupDayStyle") } }
    /// Popup Day view points per hour; 0 = fit the day to the pane.
    var popupHourHeight: Double { didSet { save(popupHourHeight, "popupHourHeight") } }
    /// Compact popup size: width for List/Day, width for Week/Month, and height.
    var popupWidth: Double { didSet { save(popupWidth, "popupWidth") } }
    var popupWideWidth: Double { didSet { save(popupWideWidth, "popupWideWidth") } }
    var popupHeight: Double { didSet { save(popupHeight, "popupHeight") } }
    var miniMonthSize: MiniMonthSize { didSet { save(miniMonthSize.rawValue, "miniMonthSize") } }
    var agendaDays: Int { didSet { save(agendaDays, "agendaDays") } }
    var popoverSize: PopoverSize { didSet { save(popoverSize.rawValue, "popoverSize") } }
    var globalShortcut: Bool { didSet { save(globalShortcut, "globalShortcut") } }
    var defaultDuration: Int { didSet { save(defaultDuration, "defaultDuration") } }
    var defaultCalendarID: String { didSet { save(defaultCalendarID, "defaultCalendarID") } }
    var dimPastEvents: Bool { didSet { save(dimPastEvents, "dimPastEvents") } }
    var hideDeclined: Bool { didSet { save(hideDeclined, "hideDeclined") } }
    var hiddenCalendarIDs: Set<String> { didSet { save(Array(hiddenCalendarIDs), "hiddenCalendarIDs") } }
    var collapsedSources: Set<String> { didSet { save(Array(collapsedSources), "collapsedSources") } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "menuBarStyle": MenuBarStyle.dayIcon.rawValue,
            "menuBarDateTemplate": "EEEdMMM",
            "showNextEvent": true,
            "nextEventLookahead": 30,
            "firstWeekday": 0,
            "showWeekNumbers": false,
            "highlightWeekends": true,
            "hourHeight": 46.0,
            "useAppleCalendars": true,
            "popupStyle": PopupStyle.compact.rawValue,
            "agendaDays": 7,
            "miniMonthSize": MiniMonthSize.regular.rawValue,
            "popupWidth": 360.0,
            "popupWideWidth": 680.0,
            "popupHeight": 640.0,
            "popupHourHeight": 0.0,
            "popupDayStyle": PopupDayStyle.list.rawValue,
            "popoverSize": PopoverSize.regular.rawValue,
            "globalShortcut": true,
            "defaultDuration": 30,
            "defaultCalendarID": "",
            "dimPastEvents": true,
            "hideDeclined": false,
        ])
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .dayIcon
        menuBarDateTemplate = d.string(forKey: "menuBarDateTemplate") ?? "EEEdMMM"
        showNextEvent = d.bool(forKey: "showNextEvent")
        nextEventLookahead = d.integer(forKey: "nextEventLookahead")
        firstWeekday = d.integer(forKey: "firstWeekday")
        showWeekNumbers = d.bool(forKey: "showWeekNumbers")
        highlightWeekends = d.bool(forKey: "highlightWeekends")
        hourHeight = d.double(forKey: "hourHeight")
        useAppleCalendars = d.bool(forKey: "useAppleCalendars")
        popupStyle = PopupStyle(rawValue: d.string(forKey: "popupStyle") ?? "") ?? .compact
        agendaDays = d.integer(forKey: "agendaDays")
        miniMonthSize = MiniMonthSize(rawValue: d.string(forKey: "miniMonthSize") ?? "") ?? .regular
        popupWidth = d.double(forKey: "popupWidth")
        popupWideWidth = d.double(forKey: "popupWideWidth")
        popupHeight = d.double(forKey: "popupHeight")
        popupHourHeight = d.double(forKey: "popupHourHeight")
        popupDayStyle = PopupDayStyle(rawValue: d.string(forKey: "popupDayStyle") ?? "") ?? .list
        popoverSize = PopoverSize(rawValue: d.string(forKey: "popoverSize") ?? "") ?? .regular
        globalShortcut = d.bool(forKey: "globalShortcut")
        defaultDuration = d.integer(forKey: "defaultDuration")
        defaultCalendarID = d.string(forKey: "defaultCalendarID") ?? ""
        dimPastEvents = d.bool(forKey: "dimPastEvents")
        hideDeclined = d.bool(forKey: "hideDeclined")
        hiddenCalendarIDs = Set(d.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        collapsedSources = Set(d.stringArray(forKey: "collapsedSources") ?? [])
    }

    private func save(_ value: Any, _ key: String) {
        d.set(value, forKey: key)
        onChange?()
    }

    var calendar: Calendar {
        var c = Calendar.current
        if firstWeekday > 0 { c.firstWeekday = firstWeekday }
        return c
    }
}

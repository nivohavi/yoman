import AppKit
import EventKit
import SwiftUI

/// The menu-bar popup: an Itsycal-style month + agenda, restyled.
/// The full Google-Calendar-style layout lives in `RootView` (opened with the expand button).
struct CompactView: View {
    @Bindable var model: CalendarModel
    @State private var month = Date()
    @State private var selectedDay = Date()
    @State private var events: [CalEvent] = []
    @FocusState private var focused: Bool

    private var cal: Calendar { model.cal }

    var body: some View {
        Group {
            if model.hasAnySource {
                content
            } else if model.access == .unknown {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoSourceView(model: model)
            }
        }
        .foregroundStyle(Theme.text)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            if !paneIsWide {
                monthGrid.padding(.horizontal, 10).padding(.bottom, 8)
                Rectangle().fill(Theme.grid).frame(height: 0.5)
            }
            paneBar
            switch model.prefs.popupDayStyle {
            case .list:
                agenda
            case .day:
                PopupDayTimeline(model: model, day: selectedDay, events: model.events(on: selectedDay, from: events))
            case .week:
                TimeGridView(model: model, dayCount: 7, anchor: selectedDay, source: events,
                             hourHeightOverride: model.prefs.popupHourHeight > 0 ? model.prefs.popupHourHeight : 34,
                             onOpenDay: openDay, compact: true)
            case .month:
                MonthView(model: model, anchor: month, source: events, onOpenDay: openDay)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: handleKey)
        .eventOverlays(model)
        .onAppear {
            selectedDay = model.launchDate ?? Date()
            month = selectedDay
            focused = true
        }
        .task(id: fetchKey) { reloadEvents() }
        .task {
            guard let d = model.switchDate else { return }
            try? await Task.sleep(for: .seconds(3))
            select(d)
        }
    }

    // MARK: Header

    private func monthTitle(_ template: String, year: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(Fmt.f(month, template)).font(.system(size: 17, weight: .bold))
            if year { Text(Fmt.f(month, "y")).font(.system(size: 17)).foregroundStyle(Theme.secondary) }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button { goToday() } label: {
                // "October 2026" → "Oct 2026" → "Oct", whichever fits.
                ViewThatFits(in: .horizontal) {
                    monthTitle("MMMM", year: true)
                    monthTitle("MMM", year: true)
                    monthTitle("MMM", year: false)
                }
            }
            .buttonStyle(.plain)
            .help("Go to today (T)")
            Spacer()
            IconButton(systemName: "chevron.left", help: weekPane ? "Previous week" : "Previous month", size: 26) { step(-1) }
            IconButton(systemName: "circle.fill", help: "Today", size: 26) { goToday() }
                .scaleEffect(0.6)
                .frame(width: 18)
            IconButton(systemName: "chevron.right", help: weekPane ? "Next week" : "Next month", size: 26) { step(1) }
            Rectangle().fill(Theme.grid).frame(width: 1, height: 16).padding(.horizontal, 4)
            IconButton(systemName: "plus", help: "New event (N)", size: 26) {
                model.newDraft(start: defaultStart(on: selectedDay))
            }
            IconButton(systemName: model.pinned ? "pin.fill" : "pin", help: model.pinned ? "Unpin" : "Keep open", size: 26) {
                model.pinned.toggle()
            }
            IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open full calendar", size: 26) {
                model.anchor = selectedDay
                model.openWindow()
            }
            optionsMenu
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.top, 12).padding(.bottom, 8)
    }

    private var optionsMenu: some View {
        Menu {
            ForEach(model.groups) { g in
                Section(g.title) {
                    ForEach(g.calendars) { c in
                        Toggle(isOn: Binding(get: { model.isVisible(c) }, set: { _ in model.toggle(c) })) {
                            Label { Text(c.title) } icon: { Image(nsImage: colorDot(c.nsColor)) }
                        }
                    }
                }
            }
            Divider()
            Picker("Mini month size", selection: Bindable(model.prefs).miniMonthSize) {
                ForEach(MiniMonthSize.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Day view hour height", selection: Bindable(model.prefs).popupHourHeight) {
                Text("Auto (fit the day)").tag(0.0)
                ForEach([24.0, 32, 40, 48, 60], id: \.self) { Text("\(Int($0)) pt").tag($0) }
            }
            Toggle("Highlight weekends", isOn: Bindable(model.prefs).highlightWeekends)
            Toggle("Show week numbers", isOn: Bindable(model.prefs).showWeekNumbers)
            Button("Settings…") { model.openSettings() }
            Button("Open Calendar App") { model.openInCalendarApp() }
            Divider()
            Button("Quit Yoman") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 4)
    }

    // MARK: Month grid

    private var monthGrid: some View {
        let monthStart = cal.startOfMonth(for: month)
        let gridStart = cal.startOfWeek(for: monthStart)
        let leading = cal.dateComponents([.day], from: gridStart, to: monthStart).day!
        let weeks = Int(ceil(Double(leading + cal.range(of: .day, in: .month, for: monthStart)!.count) / 7))
        let symbols = cal.orderedWeekdaySymbols(cal.veryShortWeekdaySymbols)
        let showWeeks = model.prefs.showWeekNumbers
        let dots = dayColors()
        let weekendColumns = model.prefs.highlightWeekends
            ? Set(cal.days(from: gridStart, count: 7).enumerated().filter { cal.isDateInWeekend($0.element) }.map(\.offset))
            : []

        let size = model.prefs.miniMonthSize
        return VStack(spacing: size.rowSpacing) {
            HStack(spacing: 0) {
                if showWeeks { Color.clear.frame(width: 22, height: 1) }
                ForEach(Array(symbols.enumerated()), id: \.offset) { i, s in
                    Text(s).font(.system(size: 11, weight: weekendColumns.contains(i) ? .bold : .semibold))
                        .foregroundStyle(weekendColumns.contains(i) ? Theme.weekendLabel : Theme.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            ForEach(0..<weeks, id: \.self) { w in
                let weekStart = cal.date(byAdding: .day, value: 7 * w, to: gridStart)!
                HStack(spacing: 0) {
                    if showWeeks {
                        Text("\(cal.component(.weekOfYear, from: weekStart))")
                            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.secondary.opacity(0.7))
                            .frame(width: 22)
                    }
                    ForEach(cal.days(from: weekStart, count: 7)) { day in
                        DayCell(
                            day: day, cal: cal,
                            inMonth: cal.isDate(day, equalTo: monthStart, toGranularity: .month),
                            selected: cal.isDate(day, inSameDayAs: selectedDay),
                            colors: dots[cal.startOfDay(for: day)] ?? [],
                            size: size,
                            onSelect: { select(day) },
                            onDoubleClick: { model.newDraft(start: defaultStart(on: day)) })
                    }
                }
            }
        }
        .background {
            // One rounded band per weekend column, running through the header and all weeks.
            HStack(spacing: 0) {
                if showWeeks { Color.clear.frame(width: 22) }
                ForEach(0..<7, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(weekendColumns.contains(i) ? Theme.weekendBand : .clear)
                        .padding(.horizontal, 1)
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if abs(v.translation.width) > abs(v.translation.height) { shiftMonth(v.translation.width < 0 ? 1 : -1) }
        })
    }

    /// Up to three distinct calendar colors per day, like Itsycal's colored dots.
    private func dayColors() -> [Date: [Color]] {
        var out: [Date: [NSColor]] = [:]
        for e in events {
            var d = cal.startOfDay(for: e.start)
            let last = e.isAllDay ? e.end.addingTimeInterval(-1) : e.end
            while d <= last {
                if out[d, default: []].count < 3, !out[d, default: []].contains(e.nsColor) { out[d, default: []].append(e.nsColor) }
                guard let next = cal.date(byAdding: .day, value: 1, to: d), next < last || cal.isDate(next, inSameDayAs: last) else { break }
                d = next
            }
        }
        return out.mapValues { $0.map { Color(nsColor: $0) } }
    }

    // MARK: Agenda

    /// Switches the lower half between the agenda list and a one-day time grid.
    private var paneBar: some View {
        let style = Bindable(model.prefs).popupDayStyle
        let title: String = {
            switch model.prefs.popupDayStyle {
            case .list: return "Next \(model.prefs.agendaDays) days"
            case .week:
                let s = cal.startOfWeek(for: selectedDay)
                let e = cal.date(byAdding: .day, value: 6, to: s)!
                return "\(Fmt.f(s, "MMMd")) – \(Fmt.f(e, cal.isDate(s, equalTo: e, toGranularity: .month) ? "d" : "MMMd"))"
            case .month: return Fmt.f(month, "MMMMy")
            case .day: break
            }
            if cal.isDateInToday(selectedDay) { return "Today · " + Fmt.f(selectedDay, "EEEMMMd") }
            if cal.isDateInTomorrow(selectedDay) { return "Tomorrow · " + Fmt.f(selectedDay, "EEEMMMd") }
            return Fmt.f(selectedDay, "EEEEMMMMd")
        }()
        let picker = Picker("", selection: style) {
            Text("List").help("Upcoming events (L)").tag(PopupDayStyle.list)
            Text("Day").help("Day (D)").tag(PopupDayStyle.day)
            Text("Week").help("Week (W)").tag(PopupDayStyle.week)
            Text("Month").help("Month (M)").tag(PopupDayStyle.month)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        let label = { (t: String) in
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            HStack { label(title); Spacer(minLength: 8); picker }
            HStack { label(Fmt.f(selectedDay, "EEEd")); Spacer(minLength: 8); picker }
            HStack { Spacer(minLength: 0); picker; Spacer(minLength: 0) }
            picker.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var agenda: some View {
        let days = cal.days(from: cal.startOfDay(for: selectedDay), count: max(model.prefs.agendaDays, 1))
        let sections = days.compactMap { d -> (Date, [CalEvent])? in
            let es = model.events(on: d, from: events)
            return es.isEmpty && !cal.isDate(d, inSameDayAs: selectedDay) ? nil : (d, es)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.0) { day, es in
                    Section {
                        if es.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "sun.max").foregroundStyle(Theme.secondary)
                                Text("No events").foregroundStyle(Theme.secondary)
                                Spacer()
                                Button("Add") { model.newDraft(start: defaultStart(on: day)) }
                                    .buttonStyle(.plain).foregroundStyle(Theme.blue).font(.system(size: 12, weight: .semibold))
                            }
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        } else {
                            ForEach(es) { e in CompactEventRow(model: model, event: e) }
                        }
                    } header: {
                        dayHeader(day)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        let label: String
        if cal.isDateInToday(day) { label = "Today" }
        else if cal.isDateInTomorrow(day) { label = "Tomorrow" }
        else if cal.isDateInYesterday(day) { label = "Yesterday" }
        else { label = Fmt.f(day, "EEEE") }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 11, weight: .bold))
                .foregroundStyle(cal.isDateInToday(day) ? Theme.blue : Theme.text)
            Text(Fmt.f(day, "MMMMd")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        .background(.regularMaterial)
        .onTapGesture(count: 2) { model.open(day: day); model.openWindow() }
    }

    // MARK: Actions

    private var fetchKey: String {
        "\(cal.startOfMonth(for: month).timeIntervalSince1970)-\(cal.startOfDay(for: selectedDay).timeIntervalSince1970)-\(model.revision)-\(model.prefs.agendaDays)"
    }

    private func reloadEvents() {
        let gridStart = cal.startOfWeek(for: cal.startOfMonth(for: month))
        let gridEnd = cal.date(byAdding: .day, value: 42, to: gridStart)!
        let dayStart = cal.startOfDay(for: selectedDay)
        let agendaEnd = cal.date(byAdding: .day, value: model.prefs.agendaDays, to: dayStart)!
        events = model.fetch(DateInterval(start: min(gridStart, dayStart), end: max(gridEnd, agendaEnd)))
    }

    private func select(_ day: Date) {
        selectedDay = day
        if !cal.isDate(day, equalTo: month, toGranularity: .month) { month = day }
    }

    /// Week and Month take the whole popup (it widens); List and Day sit under the mini month.
    private var paneIsWide: Bool { [.week, .month].contains(model.prefs.popupDayStyle) }
    private var weekPane: Bool { model.prefs.popupDayStyle == .week }

    private func step(_ n: Int) {
        if weekPane { select(cal.date(byAdding: .day, value: 7 * n, to: selectedDay)!) } else { shiftMonth(n) }
    }

    private func openDay(_ day: Date) {
        select(day)
        model.prefs.popupDayStyle = .day
    }

    private func shiftMonth(_ n: Int) {
        month = cal.date(byAdding: .month, value: n, to: month)!
    }

    private func goToday() { select(Date()); month = Date() }

    private func defaultStart(on day: Date) -> Date {
        if cal.isDateInToday(day) {
            let n = Date()
            let m = cal.component(.minute, from: n)
            return cal.date(byAdding: .minute, value: 30 - m % 30, to: cal.date(bySetting: .second, value: 0, of: n) ?? n)!
        }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.draft == nil else { return .ignored }
        if press.key == .escape {
            if model.selected != nil { model.selected = nil } else { model.closePopover() }
            return .handled
        }
        guard model.selected == nil else { return .ignored }
        switch press.key {
        case .leftArrow: select(cal.date(byAdding: .day, value: -1, to: selectedDay)!)
        case .rightArrow: select(cal.date(byAdding: .day, value: 1, to: selectedDay)!)
        case .upArrow: select(cal.date(byAdding: .day, value: -7, to: selectedDay)!)
        case .downArrow: select(cal.date(byAdding: .day, value: 7, to: selectedDay)!)
        case .return: model.anchor = selectedDay; model.openWindow()
        default:
            switch press.characters {
            case "t": goToday()
            case "+", "=":
                let cur = model.prefs.popupHourHeight > 0 ? model.prefs.popupHourHeight : 28
                model.prefs.popupHourHeight = min(cur + 4, 90)
            case "-":
                let cur = model.prefs.popupHourHeight > 0 ? model.prefs.popupHourHeight : 28
                model.prefs.popupHourHeight = max(cur - 4, 16)
            case "0": model.prefs.popupHourHeight = 0
            case "l": model.prefs.popupDayStyle = .list
            case "w": model.prefs.popupDayStyle = .week
            case "m": model.prefs.popupDayStyle = .month
            case "d": model.prefs.popupDayStyle = .day
            case "n", "c": model.newDraft(start: defaultStart(on: selectedDay))
            case "[": shiftMonth(-1)
            case "]": shiftMonth(1)
            default: return .ignored
            }
        }
        return .handled
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let day: Date
    let cal: Calendar
    let inMonth: Bool
    let selected: Bool
    let colors: [Color]
    let size: MiniMonthSize
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    @State private var hovering = false

    var body: some View {
        let today = cal.isDateInToday(day)
        VStack(spacing: size == .compact ? 1 : 2) {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: size.font, weight: today || selected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(
                    today ? Theme.onBlue
                    : selected ? Theme.blue
                    : !inMonth ? Theme.secondary.opacity(0.45)
                    : Theme.text)
                .frame(width: size.circle, height: size.circle)
                .background {
                    Circle().fill(today ? Theme.blue : selected ? Theme.selected : hovering ? Theme.hover : .clear)
                }
            HStack(spacing: 2.5) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                    Circle().fill(c).frame(width: size.dot, height: size.dot)
                }
            }
            .frame(height: size.dot + 0.5)
            .opacity(inMonth ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, size == .large ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
        .help(Fmt.f(day, "EEEEMMMMd") + " — double-click to add an event")
    }
}

// MARK: - Agenda row

private struct CompactEventRow: View {
    let model: CalendarModel
    let event: CalEvent
    @State private var hovering = false

    var body: some View {
        let now = model.now
        let past = event.end < now
        let ongoing = !event.isAllDay && event.start <= now && event.end > now
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .strikethrough(event.isDeclined)
                HStack(spacing: 4) {
                    Text(event.isAllDay ? "All day" : Fmt.range(event.start, event.end))
                    if let loc = event.location, event.meetingURL == nil || !loc.hasPrefix("http") {
                        Text("·")
                        Text(loc).lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                if ongoing {
                    ProgressView(value: now.timeIntervalSince(event.start), total: event.end.timeIntervalSince(event.start))
                        .progressViewStyle(.linear)
                        .tint(event.color)
                        .controlSize(.mini)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            if let url = event.meetingURL, !past {
                Button { model.join(event) } label: {
                    Label("Join", systemImage: "video.fill").labelStyle(.titleAndIcon).font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
                .help("Join \(MeetingLink.service(url))")
            } else if ongoing {
                Text("NOW").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Theme.onBlue)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.blue))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear))
        .padding(.horizontal, 6)
        .opacity(past && model.prefs.dimPastEvents ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selected = event }
        .contextMenu {
            if let url = event.meetingURL { Button("Join \(MeetingLink.service(url))") { model.join(event) } }
            Button("Copy Event Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(event.title)\n\(event.longDateLine(model.cal))" + (event.location.map { "\n\($0)" } ?? ""), forType: .string)
            }
            if event.googleRef == nil, let me = event.selfAttendee, !me.isOrganizer, model.googleWebLink(for: event) != nil {
                Button("Respond in Google Calendar…") { model.respondInGoogle(event) }
            }
            Button("Open in Calendar") { model.openInCalendarApp(event) }
            if event.isEditable {
                Divider()
                Button("Edit…") { model.edit(event) }
                Button("Delete", role: .destructive) { model.delete(event) }
            }
        }
    }
}

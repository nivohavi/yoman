import SwiftUI

// MARK: - Month

struct MonthView: View {
    let model: CalendarModel
    // Popup use: its own month, events and "open this day" action.
    var anchor: Date? = nil
    var source: [CalEvent]? = nil
    var onOpenDay: ((Date) -> Void)? = nil

    var body: some View {
        let cal = model.cal
        let monthStart = cal.startOfMonth(for: anchor ?? model.anchor)
        let gridStart = cal.startOfWeek(for: monthStart)
        let monthDays = cal.range(of: .day, in: .month, for: monthStart)!.count
        let leading = cal.dateComponents([.day], from: gridStart, to: monthStart).day!
        let weeks = Int(ceil(Double(leading + monthDays) / 7))
        let symbols = cal.orderedWeekdaySymbols(cal.shortWeekdaySymbols)
        let showWeeks = model.prefs.showWeekNumbers

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showWeeks { Color.clear.frame(width: 28) }
                ForEach(Array(symbols.enumerated()), id: \.offset) { i, s in
                    let weekend = model.prefs.highlightWeekends && cal.isDateInWeekend(cal.date(byAdding: .day, value: i, to: gridStart)!)
                    Text(s.uppercased()).font(.system(size: 11, weight: weekend ? .bold : .medium))
                        .foregroundStyle(weekend ? Theme.weekendLabel : Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            GeometryReader { geo in
                let rowH = geo.size.height / CGFloat(weeks)
                VStack(spacing: 0) {
                    ForEach(0..<weeks, id: \.self) { w in
                        let weekStart = cal.date(byAdding: .day, value: w * 7, to: gridStart)!
                        HStack(spacing: 0) {
                            if showWeeks {
                                Text("\(cal.component(.weekOfYear, from: weekStart))")
                                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                    .frame(width: 28, height: rowH, alignment: .top).padding(.top, 8)
                            }
                            ForEach(cal.days(from: weekStart, count: 7)) { day in
                                MonthCell(model: model, day: day, source: source, onOpenDay: onOpenDay,
                                          inMonth: cal.isDate(day, equalTo: monthStart, toGranularity: .month),
                                          height: rowH)
                            }
                        }
                        .frame(height: rowH)
                    }
                }
            }
        }
    }
}

private struct MonthCell: View {
    let model: CalendarModel
    let day: Date
    let source: [CalEvent]?
    let onOpenDay: ((Date) -> Void)?
    let inMonth: Bool
    let height: CGFloat

    var body: some View {
        let cal = model.cal
        let today = cal.isDateInToday(day)
        let events = model.events(on: day, from: source)
        let capacity = max(Int((height - 30) / 18), 0)
        let shown = events.count > capacity ? max(capacity - 1, 0) : capacity

        VStack(alignment: .leading, spacing: 2) {
            Button { if let onOpenDay { onOpenDay(day) } else { model.open(day: day) } } label: {
                Text(cal.component(.day, from: day) == 1 ? Fmt.f(day, "MMMd") : "\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: today ? .bold : .medium))
                    .foregroundStyle(today ? Theme.onBlue : inMonth ? Theme.text : Theme.secondary)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(today ? Theme.blue : .clear))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            ForEach(events.prefix(shown)) { e in
                MonthChip(model: model, event: e)
            }
            if events.count > shown {
                Button { if let onOpenDay { onOpenDay(day) } else { model.open(day: day) } } label: {
                    Text("\(events.count - shown) more").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(!inMonth ? Color.primary.opacity(0.05)
                    : model.prefs.highlightWeekends && cal.isDateInWeekend(day) ? Theme.weekendBand : .clear)
        .overlay(alignment: .topLeading) {
            Rectangle().fill(Theme.grid).frame(height: 0.5)
        }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.grid).frame(width: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.newDraft(start: cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)) }
    }
}

private struct MonthChip: View {
    let model: CalendarModel
    let event: CalEvent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if event.isLaneEvent {
                Text(event.title).foregroundStyle(event.nsColor.contrastingText)
            } else {
                Circle().fill(event.color).frame(width: 7, height: 7)
                Text(Fmt.time(event.start)).foregroundStyle(Theme.secondary)
                Text(event.title).foregroundStyle(Theme.text).fontWeight(.medium)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .strikethrough(event.isDeclined)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(event.isLaneEvent ? event.color : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selected = event }
    }
}

// MARK: - Schedule (agenda)

struct ScheduleView: View {
    let model: CalendarModel
    var events: [CalEvent]? = nil
    var emptyText = "Nothing planned. Enjoy your free time!"

    var body: some View {
        let cal = model.cal
        let list = events ?? model.events
        let days: [Date] = {
            if events != nil {
                return Array(Set(list.map { cal.startOfDay(for: $0.start) })).sorted()
            }
            let r = model.visibleRange
            return cal.days(from: r.start, count: cal.dateComponents([.day], from: r.start, to: r.end).day!)
        }()
        let rows = days.compactMap { d -> (Date, [CalEvent])? in
            let es = events != nil ? list.filter { cal.isDate($0.start, inSameDayAs: d) } : model.events(on: d, from: list)
            return es.isEmpty ? nil : (d, es)
        }

        if rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 40)).foregroundStyle(Theme.secondary)
                Text(emptyText).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.0) { day, es in
                        ScheduleDay(model: model, day: day, events: es)
                        Rectangle().fill(Theme.grid).frame(height: 0.5)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct ScheduleDay: View {
    let model: CalendarModel
    let day: Date
    let events: [CalEvent]

    var body: some View {
        let cal = model.cal
        let today = cal.isDateInToday(day)
        HStack(alignment: .top, spacing: 12) {
            Button { model.open(day: day) } label: {
                HStack(spacing: 8) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 20))
                        .foregroundStyle(today ? Theme.onBlue : Theme.text)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(today ? Theme.blue : .clear))
                    Text(Fmt.f(day, "MMMEEE").uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(today ? Theme.blue : Theme.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(events) { e in ScheduleRow(model: model, event: e) }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ScheduleRow: View {
    let model: CalendarModel
    let event: CalEvent
    @State private var hovering = false

    var body: some View {
        let past = event.end < model.now
        HStack(spacing: 12) {
            Circle().fill(event.color).frame(width: 10, height: 10)
            Text(event.timeRange(model.cal))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 13, weight: .medium)).strikethrough(event.isDeclined)
                if let loc = event.location {
                    Text(loc).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let url = event.meetingURL, !past {
                Button("Join") { model.join(event) }
                    .buttonStyle(PrimaryButtonStyle())
                    .help(url.absoluteString)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .opacity(past && model.prefs.dimPastEvents ? 0.55 : 1)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selected = event }
    }
}

import SwiftUI

/// Day / week view: all-day lane on top, scrollable 24h grid with overlapping-event layout below.
struct TimeGridView: View {
    let model: CalendarModel
    let dayCount: Int
    // Popup use: its own date, events, hour height and "open this day" action; smaller header.
    var anchor: Date? = nil
    var source: [CalEvent]? = nil
    var hourHeightOverride: CGFloat? = nil
    var onOpenDay: ((Date) -> Void)? = nil
    var compact = false

    private var gutter: CGFloat { compact ? 38 : 56 }
    private var hourHeight: CGFloat { hourHeightOverride ?? model.prefs.hourHeight }
    private var cal: Calendar { model.cal }
    private var allEvents: [CalEvent] { source ?? model.events }

    private var days: [Date] {
        let a = anchor ?? model.anchor
        let start = dayCount == 1 ? cal.startOfDay(for: a) : cal.startOfWeek(for: a)
        return cal.days(from: start, count: dayCount)
    }

    private func open(_ day: Date) {
        if let onOpenDay { onOpenDay(day) } else { model.open(day: day) }
    }

    var body: some View {
        let days = days
        let timed = allEvents.filter { !$0.isLaneEvent }
        let lane = allEvents.filter(\.isLaneEvent)
        VStack(spacing: 0) {
            header(days)
            AllDayLane(model: model, days: days, events: lane, gutter: gutter)
            Rectangle().fill(Theme.grid).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        ForEach(days) { day in
                            DayColumn(model: model, day: day, events: model.events(on: day, from: timed), hourHeight: hourHeight, cascade: compact)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .background(gridLines)
                    .padding(.top, 8)
                }
                .onAppear { scrollToWorkingHours(proxy) }
                .onChange(of: model.mode) { scrollToWorkingHours(proxy) }
                .onChange(of: days.first) { scrollToWorkingHours(proxy) }
            }
        }
    }

    private func scrollToWorkingHours(_ proxy: ScrollViewProxy) {
        // Open at the first timed event among the visible days (the popup passes a whole month of events).
        let visible = Set(days.map { cal.startOfDay(for: $0) })
        let firstEvent = allEvents
            .filter { !$0.isLaneEvent && visible.contains(cal.startOfDay(for: $0.start)) }
            .map { cal.component(.hour, from: $0.start) }.min()
        let hour = firstEvent ?? 8
        proxy.scrollTo("h\(min(max(hour, 0), 23))", anchor: .top)
    }

    private func header(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            Group {
                if model.prefs.showWeekNumbers, let d = days.first {
                    Text("W\(cal.component(.weekOfYear, from: d))")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                } else { Color.clear }
            }
            .frame(width: gutter)
            ForEach(days) { day in
                let today = cal.isDateInToday(day)
                VStack(spacing: 2) {
                    let weekend = model.prefs.highlightWeekends && cal.isDateInWeekend(day)
                    Text(Fmt.f(day, "EEE").uppercased())
                        .font(.system(size: compact ? 10 : 11, weight: weekend ? .bold : .medium))
                        .foregroundStyle(today ? Theme.blue : weekend ? Theme.weekendLabel : Theme.secondary)
                    Button { open(day) } label: {
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: compact ? 14 : dayCount == 1 ? 24 : 20, weight: compact ? .semibold : .regular))
                            .foregroundStyle(today ? Theme.onBlue : Theme.text)
                            .frame(width: compact ? 26 : 40, height: compact ? 26 : 40)
                            .background(Circle().fill(today ? Theme.blue : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 3 : 6)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Text(h == 0 ? "" : Fmt.hourLabel(h))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -6)
                    .padding(.trailing, 8)
                    .id("h\(h)")
            }
        }
    }

    /// Hour lines as plain shapes. (A Canvas here was rasterized as one bitmap the size of the whole
    /// scrollable day — ~130 MB at first draw in the popup's Week view.)
    private var gridLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Rectangle().fill(h == 0 ? .clear : Theme.grid)
                    .frame(height: 0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.leading, gutter - 6)
    }
}

// MARK: - Day column

private struct DayColumn: View {
    let model: CalendarModel
    let day: Date
    let events: [CalEvent]
    let hourHeight: CGFloat
    /// Narrow columns (popup): overlapping events cascade instead of splitting into slivers.
    var cascade = false

    var body: some View {
        let cal = model.cal
        let dayStart = cal.startOfDay(for: day)
        GeometryReader { geo in
            let width = geo.size.width - 8
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { p in
                        let slot = Int(p.y / (hourHeight / 2))  // half-hour slots
                        model.newDraft(start: Calendar.current.wallClock(dayStart, hours: Double(slot) / 2))
                    }
                if cascade {
                    let layout = EventLayout.cascade(EventLayout.layout(events, dayStart: dayStart), width: width)
                    ForEach(layout.order) { item in
                        let y = cal.wallHours(item.start, dayStart: dayStart) * hourHeight
                        let h = max((cal.wallHours(item.end, dayStart: dayStart) - cal.wallHours(item.start, dayStart: dayStart)) * hourHeight - 1, 16)
                        let f = layout.frames[item.id] ?? (0, width)
                        TimelineBlock(model: model, event: item.event, height: h)
                            .frame(width: max(f.w - 2, 12), height: h)
                            .offset(x: f.x, y: y)
                    }
                } else {
                    ForEach(EventLayout.layout(events, dayStart: dayStart)) { item in
                        let y = cal.wallHours(item.start, dayStart: dayStart) * hourHeight
                        let h = max((cal.wallHours(item.end, dayStart: dayStart) - cal.wallHours(item.start, dayStart: dayStart)) * hourHeight - 1, 16)
                        let colW = width / CGFloat(item.columns)
                        TimelineBlock(model: model, event: item.event, height: h)
                            .frame(width: max(colW * CGFloat(item.span) - 2, 12), height: h)
                            .offset(x: colW * CGFloat(item.column), y: y)
                    }
                }
                if cal.isDateInToday(day) {
                    NowLine(dayStart: dayStart, hourHeight: hourHeight)
                }
            }
        }
        .background(model.prefs.highlightWeekends && cal.isDateInWeekend(day) ? Theme.weekendBand : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.grid).frame(width: 0.5) }
    }
}

private struct NowLine: View {
    let dayStart: Date
    let hourHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let y = Calendar.current.wallHours(ctx.date, dayStart: dayStart) * hourHeight
            HStack(spacing: 0) {
                Circle().fill(Theme.now).frame(width: 11, height: 11).offset(x: -5.5)
                Rectangle().fill(Theme.now).frame(height: 2).offset(x: -5.5)
            }
            .offset(y: y - 5.5)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - All-day lane

private struct AllDayLane: View {
    let model: CalendarModel
    let days: [Date]
    let events: [CalEvent]
    let gutter: CGFloat
    @State private var expanded = false

    private struct Bar: Identifiable { let event: CalEvent; let first: Int; let last: Int; var row = 0; var id: String { event.id } }

    var body: some View {
        let bars = layoutBars()
        let rows = (bars.map(\.row).max() ?? -1) + 1
        let shownRows = expanded ? rows : min(rows, 3)
        if rows > 0 {
            HStack(alignment: .top, spacing: 0) {
                Group {
                    if rows > 3 {
                        IconButton(systemName: expanded ? "chevron.up" : "chevron.down", help: "Show all", size: 22) { expanded.toggle() }
                    } else { Color.clear }
                }
                .frame(width: gutter, height: 22)
                GeometryReader { geo in
                    let colW = geo.size.width / CGFloat(days.count)
                    ZStack(alignment: .topLeading) {
                        ForEach(bars.filter { $0.row < shownRows }) { b in
                            let ev = b.event
                            Text(ev.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(ev.nsColor.contrastingText)
                                .padding(.horizontal, 6)
                                .frame(width: colW * CGFloat(b.last - b.first + 1) - 4, height: 20, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5).fill(ev.color))
                                .offset(x: colW * CGFloat(b.first) + 2, y: CGFloat(b.row) * 22)
                                .onTapGesture { model.selected = ev }
                        }
                    }
                }
                .frame(height: CGFloat(shownRows) * 22)
            }
            .padding(.bottom, 4)
        }
    }

    private func layoutBars() -> [Bar] {
        let cal = model.cal
        guard let first = days.first else { return [] }
        let n = days.count
        func index(_ d: Date) -> Int { cal.dateComponents([.day], from: first, to: cal.startOfDay(for: d)).day ?? 0 }
        var bars: [Bar] = events.compactMap { e in
            let s = index(e.start), l = index(e.end.addingTimeInterval(-1))
            guard l >= 0, s < n else { return nil }
            return Bar(event: e, first: max(s, 0), last: min(l, n - 1))
        }
        bars.sort { ($0.first, -($0.last - $0.first)) < ($1.first, -($1.last - $1.first)) }
        var rowEnds: [Int] = []
        for i in bars.indices {
            if let r = rowEnds.firstIndex(where: { $0 < bars[i].first }) {
                bars[i].row = r
                rowEnds[r] = bars[i].last
            } else {
                bars[i].row = rowEnds.count
                rowEnds.append(bars[i].last)
            }
        }
        return bars
    }
}

// MARK: - Overlap layout

enum EventLayout {
    /// Google Calendar's rule for narrow columns: events that start within 30 minutes of each other
    /// share the width side by side; an event that starts later is indented on top of what it overlaps.
    /// Returns x offset and width per event id, plus a back-to-front drawing order.
    static func cascade(_ items: [Item], width: CGFloat) -> (frames: [String: (x: CGFloat, w: CGFloat)], order: [Item]) {
        let sorted = items.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var frames: [String: (x: CGFloat, w: CGFloat)] = [:]
        var placed: [Item] = []
        let indent = width * 0.3
        for it in sorted {
            let overlapping = placed.filter { $0.start < it.end && $0.end > it.start }
            let siblings = overlapping.filter { it.start.timeIntervalSince($0.start) < 30 * 60 }
            if let first = siblings.first {
                // Near-simultaneous: split the siblings' region into equal slices.
                let x0 = siblings.compactMap { frames[$0.id]?.x }.min() ?? frames[first.id]?.x ?? 0
                let region = width - x0
                let group = siblings + [it]
                let slice = region / CGFloat(group.count)
                for (i, g) in group.enumerated() { frames[g.id] = (x0 + CGFloat(i) * slice, slice) }
            } else if !overlapping.isEmpty {
                let x = min((overlapping.compactMap { frames[$0.id]?.x }.max() ?? 0) + indent, width * 0.6)
                frames[it.id] = (x, width - x)
            } else {
                frames[it.id] = (0, width)
            }
            placed.append(it)
        }
        return (frames, sorted)
    }

    struct Item: Identifiable {
        let event: CalEvent
        let start: Date
        let end: Date
        var column = 0
        var columns = 1
        var span = 1
        var id: String { event.id }
    }

    /// Greedy column packing per cluster of transitively-overlapping events, then let each event
    /// stretch right across free columns — the same visual result Google Calendar produces.
    static func layout(_ events: [CalEvent], dayStart: Date) -> [Item] {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let items = events.map { e -> Item in
            let s = max(e.start, dayStart)
            let en = min(max(e.end, s.addingTimeInterval(20 * 60)), dayEnd)
            return Item(event: e, start: s, end: en)
        }
        .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }

        var result: [Item] = []
        var cluster: [Item] = []
        var colEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let n = colEnds.count
            for var c in cluster {
                c.columns = n
                // Expand into following columns that have no overlapping event.
                var span = 1
                while c.column + span < n,
                      !cluster.contains(where: { $0.column == c.column + span && $0.start < c.end && $0.end > c.start }) {
                    span += 1
                }
                c.span = span
                result.append(c)
            }
            cluster = []
            colEnds = []
        }

        for var it in items {
            if it.start >= clusterEnd { flush() }
            if let i = colEnds.firstIndex(where: { $0 <= it.start }) {
                it.column = i
                colEnds[i] = it.end
            } else {
                it.column = colEnds.count
                colEnds.append(it.end)
            }
            cluster.append(it)
            clusterEnd = max(clusterEnd, it.end)
        }
        flush()
        return result
    }
}

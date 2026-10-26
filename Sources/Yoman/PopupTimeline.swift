import SwiftUI

/// The popup's "Day" pane: one day as a Google-Calendar-style time grid. Overlapping events cascade
/// (each later one indented and drawn on top), which reads better than side-by-side columns at popup width.
struct PopupDayTimeline: View {
    let model: CalendarModel
    let day: Date
    let events: [CalEvent]

    var body: some View {
        let allDay = events.filter(\.isLaneEvent)
        let timed = events.filter { !$0.isLaneEvent }

        VStack(spacing: 0) {
            if !allDay.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(allDay) { e in
                        Text(e.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(e.nsColor.contrastingText)
                            .padding(.horizontal, 7)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(e.color))
                            .contentShape(Rectangle())
                            .onTapGesture { model.selected = e }
                    }
                }
                .padding(.leading, DayGrid.gutter).padding(.trailing, 12).padding(.vertical, 6)
                Rectangle().fill(Theme.grid).frame(height: 0.5)
            }
            GeometryReader { geo in
                let range = focusRange(timed)
                // Shrink the hour height so the hours that matter fit the pane without scrolling.
                let fixed = model.prefs.popupHourHeight
                let hourHeight = fixed > 0
                    ? CGFloat(fixed)
                    : min(max((geo.size.height - 16) / CGFloat(range.upperBound - range.lowerBound), 22), 46)
                DayGrid(model: model, day: day, timed: timed, hourHeight: hourHeight, firstHour: range.lowerBound)
                    // A fresh grid (and scroll position) per day, so switching days opens at that day's first event.
                    .id(model.cal.startOfDay(for: day))
            }
        }
    }

    /// Hours worth showing: from the first event's hour to the last event's end (at least 6 hours),
    /// so the view opens on the first event. Days without timed events start at 08:00.
    private func focusRange(_ timed: [CalEvent]) -> Range<Int> {
        let cal = model.cal
        let dayStart = cal.startOfDay(for: day)
        let starts = timed.map { Int(cal.wallHours($0.start, dayStart: dayStart)) }
        let ends = timed.map { Int(cal.wallHours($0.end, dayStart: dayStart).rounded(.up)) }
        let lo = starts.min() ?? 8
        var hi = ends.max() ?? lo + 10
        if cal.isDateInToday(day), let first = starts.min(), cal.component(.hour, from: Date()) >= first {
            hi = max(hi, cal.component(.hour, from: Date()) + 1)  // keep "now" in view once the day has started
        }
        hi = max(hi, lo + 6)
        return max(lo, 0)..<min(hi, 24)
    }
}

private struct DayGrid: View {
    static let gutter: CGFloat = 42
    let model: CalendarModel
    let day: Date
    let timed: [CalEvent]
    let hourHeight: CGFloat
    let firstHour: Int

    private var gutter: CGFloat { Self.gutter }

    var body: some View {
        let cal = model.cal
        let dayStart = cal.startOfDay(for: day)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    hourRows
                    // Scroll targets sit a little above each hour line so its label stays visible.
                    ForEach(0..<24, id: \.self) { h in
                        Color.clear.frame(width: 1, height: 1)
                            .alignmentGuide(.top) { _ in -max(CGFloat(h) * hourHeight - 14, 0) }
                            .id("ph\(h)")
                    }
                    GeometryReader { geo in
                        let width = geo.size.width - gutter - 12
                        let layout = EventLayout.cascade(EventLayout.layout(timed, dayStart: dayStart), width: width)
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 1, coordinateSpace: .local) { p in
                                    let slot = max(Int(p.y / (hourHeight / 2)), 0)
                                    model.newDraft(start: cal.wallClock(dayStart, hours: Double(slot) / 2))
                                }
                            ForEach(layout.order) { item in
                                let y = cal.wallHours(item.start, dayStart: dayStart) * hourHeight
                                let h = max((cal.wallHours(item.end, dayStart: dayStart) - cal.wallHours(item.start, dayStart: dayStart)) * hourHeight - 2, 16)
                                let f = layout.frames[item.id] ?? (0, width)
                                TimelineBlock(model: model, event: item.event, height: h)
                                    .frame(width: max(f.w - 2, 12), height: h)
                                    .offset(x: gutter + f.x, y: y + 1)
                            }
                            if cal.isDateInToday(day) {
                                PopupNowLine(dayStart: dayStart, hourHeight: hourHeight, gutter: gutter)
                            }
                        }
                    }
                }
                .frame(height: hourHeight * 24)
                .padding(.vertical, 8)
            }
            .onAppear {
                proxy.scrollTo("ph\(firstHour)", anchor: .top)
                // Again after the first layout pass, once the final hour height is known.
                DispatchQueue.main.async { proxy.scrollTo("ph\(firstHour)", anchor: .top) }
            }
            .onChange(of: day) { proxy.scrollTo("ph\(firstHour)", anchor: .top) }
            .onChange(of: firstHour) { proxy.scrollTo("ph\(firstHour)", anchor: .top) }
            .onChange(of: hourHeight) { proxy.scrollTo("ph\(firstHour)", anchor: .top) }
        }
    }

    private var hourRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.grid.opacity(0.7)).frame(height: 0.5).padding(.leading, gutter - 4)
                    Text(h == 0 ? "" : Fmt.hourLabel(h))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: gutter - 10, alignment: .trailing)
                        .offset(y: -6)
                }
                .frame(height: hourHeight, alignment: .top)
            }
        }
    }
}

/// An event block styled like Google Calendar: filled when accepted (or no RSVP),
/// outlined when you haven't responded, striped for "maybe", struck through when declined.
struct TimelineBlock: View {
    let model: CalendarModel
    let event: CalEvent
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        let me = event.selfAttendee
        let pending = me?.status == .needsAction && me?.isOrganizer == false
        let tentative = me?.status == .tentative
        let declined = me?.status == .declined
        let outlined = pending || declined
        let past = model.prefs.dimPastEvents && event.end < model.now
        // Dimming and hover are applied to the colors, not as view-wide opacity/brightness effects,
        // which would make every block render into its own offscreen buffer (a big memory spike in Week view).
        let dim: Double = past ? 0.6 : 1
        let fg: Color = (outlined ? event.color : event.nsColor.contrastingText).opacity(dim)
        let shape = RoundedRectangle(cornerRadius: 7)

        shape
            .fill((outlined ? Theme.bg : event.color).opacity(dim))
            .overlay { if hovering { shape.fill(Color.black.opacity(0.08)) } }
            .overlay {
                if tentative {
                    Stripes().stroke(Color.black.opacity(0.22), lineWidth: 2.5).clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(outlined ? event.color : Theme.bg.opacity(0.9), lineWidth: outlined ? 1.5 : 1))
            .overlay(alignment: height < 30 ? .leading : .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    if height < 30 {
                        Text("\(event.title), \(Fmt.ltrTime(event.start))")
                            .font(.system(size: height < 20 ? 10.5 : 11.5, weight: .semibold))
                            .lineLimit(1)
                    } else {
                        Text(event.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(max(Int((height - 18) / 15), 1))
                        Text([Fmt.range(event.start, event.end), event.location].compactMap { $0 }.joined(separator: ", "))
                            .font(.system(size: 11))
                            .lineLimit(height > 70 ? 2 : 1)
                    }
                }
                .strikethrough(declined)
                .foregroundStyle(fg)
                .padding(.horizontal, 7).padding(.vertical, height < 30 ? 0 : 4)
            }
            .overlay(alignment: .topTrailing) {
                if event.meetingURL != nil, height >= 34, !past {
                    Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(fg.opacity(0.85)).padding(6)
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture { model.selected = event }
            .help("\(event.title)\n\(event.timeRange(model.cal))")
    }
}

/// Diagonal hatching for tentative ("maybe") events.
private struct Stripes: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = -r.height
        while x < r.width {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 9
        }
        return p
    }
}

private struct PopupNowLine: View {
    let dayStart: Date
    let hourHeight: CGFloat
    let gutter: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let y = Calendar.current.wallHours(ctx.date, dayStart: dayStart) * hourHeight
            HStack(spacing: 0) {
                Circle().fill(Theme.now).frame(width: 10, height: 10)
                Rectangle().fill(Theme.now).frame(height: 2)
            }
            .offset(x: gutter - 5, y: y - 5)
            .allowsHitTesting(false)
        }
    }
}

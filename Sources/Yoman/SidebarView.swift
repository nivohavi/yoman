import EventKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.newDraft() } label: {
                Label { Text("Create") } icon: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.blue)
                }
            }
            .buttonStyle(CreateButtonStyle())
            .help("Create event (C)")

            MiniMonthView(model: model)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search events", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Capsule().fill(Theme.hover))
            .task(id: model.searchText) {
                try? await Task.sleep(for: .milliseconds(200))
                model.runSearch()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.groups) { g in CalendarGroupView(model: model, group: g) }
                }
            }

            if let next = model.nextEvent {
                UpNextCard(model: model, event: next)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}

private struct CalendarGroupView: View {
    let model: CalendarModel
    let group: CalendarGroup

    var body: some View {
        let collapsed = model.prefs.collapsedSources.contains(group.id)
        let allVisible = group.calendars.allSatisfy(model.isVisible)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button {
                    if collapsed { model.prefs.collapsedSources.remove(group.id) } else { model.prefs.collapsedSources.insert(group.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text(group.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if let w = group.warning {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10)).help(w)
                        }
                        Spacer()
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contextMenu {
                Button(allVisible ? "Hide all in \(group.title)" : "Show all in \(group.title)") {
                    model.setGroup(group, visible: !allVisible)
                }
            }
            .padding(.vertical, 4)

            if !collapsed {
                ForEach(group.calendars) { c in CalendarRow(model: model, calendar: c) }
            }
        }
    }
}

private struct CalendarRow: View {
    let model: CalendarModel
    let calendar: CalendarInfo
    @State private var hovering = false

    var body: some View {
        let visible = model.isVisible(calendar)
        HStack(spacing: 10) {
            ColorCheckbox(color: calendar.color, checked: visible)
            Text(calendar.title).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button("Only") { model.showOnly(calendar) }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.blue)
                    .help("Show only this calendar")
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.toggle(calendar) }
        .help(calendar.isWritable ? calendar.title : "\(calendar.title) (read-only)")
    }
}

private struct UpNextCard: View {
    let model: CalendarModel
    let event: CalEvent

    var body: some View {
        let ongoing = event.start <= model.now
        VStack(alignment: .leading, spacing: 6) {
            Text(ongoing ? "NOW" : "UP NEXT · in \(Fmt.relative(event.start.timeIntervalSince(model.now)))")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.blue)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(event.timeRange(model.cal)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            if let url = event.meetingURL {
                Button { model.join(event) } label: {
                    Label("Join \(MeetingLink.service(url))", systemImage: "video.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.grid))
        .contentShape(Rectangle())
        .onTapGesture { model.selected = event }
    }
}

// MARK: - Mini month

struct MiniMonthView: View {
    let model: CalendarModel
    @State private var month = Date()
    @State private var busyDays: Set<Date> = []

    var body: some View {
        let cal = model.cal
        let monthStart = cal.startOfMonth(for: month)
        let gridStart = cal.startOfWeek(for: monthStart)
        let days = cal.days(from: gridStart, count: 42)
        let symbols = cal.orderedWeekdaySymbols(cal.veryShortWeekdaySymbols)
        let range = model.visibleRange

        VStack(spacing: 4) {
            HStack {
                Text(Fmt.f(month, "MMMMy")).font(.system(size: 13, weight: .semibold))
                Spacer()
                IconButton(systemName: "chevron.left", size: 22) { month = cal.date(byAdding: .month, value: -1, to: month)! }
                IconButton(systemName: "chevron.right", size: 22) { month = cal.date(byAdding: .month, value: 1, to: month)! }
            }
            .padding(.leading, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary).frame(height: 18)
                }
                ForEach(days) { day in
                    let today = cal.isDateInToday(day)
                    let selected = cal.isDate(day, inSameDayAs: model.anchor)
                    let inRange = model.mode == .week && range.contains(day)
                    let inMonth = cal.isDate(day, equalTo: monthStart, toGranularity: .month)
                    Button { model.anchor = day } label: {
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 10.5, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? Theme.onBlue : selected ? Theme.blue : inMonth ? Theme.text : Theme.secondary.opacity(0.7))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(today ? Theme.blue : selected ? Theme.selected : .clear))
                            .overlay(alignment: .bottom) {
                                if busyDays.contains(day), !today {
                                    Circle().fill(Theme.secondary.opacity(0.7)).frame(width: 3, height: 3).offset(y: -1)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .background(inRange ? Theme.hover : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: model.anchor, initial: true) { month = model.anchor }
        .task(id: "\(monthStart.timeIntervalSince1970)-\(model.revision)") {
            let evs = model.fetch(DateInterval(start: gridStart, end: cal.date(byAdding: .day, value: 42, to: gridStart)!))
            busyDays = Set(evs.map { cal.startOfDay(for: $0.start) })
        }
    }
}

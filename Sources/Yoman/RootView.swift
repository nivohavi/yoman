import AppKit
import SwiftUI

struct RootView: View {
    @Bindable var model: CalendarModel
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.hasAnySource {
                main
            } else if model.access == .unknown {
                ProgressView("Loading calendars…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoSourceView(model: model)
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private var main: some View {
        HStack(spacing: 0) {
            SidebarView(model: model).frame(width: 236)
            Rectangle().fill(Theme.grid).frame(width: 0.5)
            VStack(spacing: 0) {
                HeaderBar(model: model)
                Rectangle().fill(Theme.grid).frame(height: 0.5)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress(action: handleKey)
            }
        }
        .eventOverlays(model)
        .onAppear { focused = true; model.fullViews += 1 }
        .onDisappear { model.fullViews -= 1 }
    }

    @ViewBuilder private var content: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(model.searchResults.count) results for “\(model.searchText)”")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(12)
                ScheduleView(model: model, events: model.searchResults, emptyText: "No matching events")
            }
        } else {
            switch model.mode {
            case .day: TimeGridView(model: model, dayCount: 1)
            case .week: TimeGridView(model: model, dayCount: 7)
            case .month: MonthView(model: model)
            case .schedule: ScheduleView(model: model)
            }
        }
    }

    /// Google Calendar keyboard shortcuts.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.draft == nil else { return .ignored }
        if press.key == .escape, model.selected != nil { model.selected = nil; return .handled }
        guard model.selected == nil, press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.characters {
        case "d", "1": model.mode = .day
        case "w", "2": model.mode = .week
        case "m", "3": model.mode = .month
        case "a", "4": model.mode = .schedule
        case "t": model.goToday()
        case "j", "n": model.step(1)
        case "k", "p": model.step(-1)
        case "c": model.newDraft()
        default:
            switch press.key {
            case .rightArrow: model.step(1)
            case .leftArrow: model.step(-1)
            default: return .ignored
            }
        }
        return .handled
    }
}

struct HeaderBar: View {
    @Bindable var model: CalendarModel

    var body: some View {
        HStack(spacing: 10) {
            Button("Today") { model.goToday() }.buttonStyle(PillButtonStyle()).help("Today (T)")
            HStack(spacing: 0) {
                IconButton(systemName: "chevron.left", help: "Previous (K)") { model.step(-1) }
                IconButton(systemName: "chevron.right", help: "Next (J)") { model.step(1) }
            }
            Text(model.title).font(.system(size: 19)).lineLimit(1)
            Spacer()
            Picker("", selection: $model.mode) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            Menu {
                Button("Settings…") { model.openSettings() }
                Button("Open in Window") { model.openWindow() }
                Button("Open Calendar App") { model.openInCalendarApp() }
                Button("Refresh") { model.refreshNow(); model.reload() }
                Divider()
                Button("Quit Yoman") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }
}

/// Shown when there is nothing to display yet: no Google account and no Apple Calendar access.
struct NoSourceView: View {
    let model: CalendarModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.plus").font(.system(size: 44)).foregroundStyle(Theme.blue)
            Text("Connect a calendar").font(.system(size: 16, weight: .semibold))
            Text(model.access == .denied
                 ? "Apple Calendar access is off. Sign in to Google directly, or allow access in System Settings › Privacy & Security › Calendars."
                 : "Sign in to your Google account to see your calendars.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.secondary).frame(maxWidth: 320)
            Button("Connect Google Calendar…") { model.openSettings() }
                .buttonStyle(PrimaryButtonStyle())
            if model.access == .denied {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Event detail / editor dialogs, shared by the compact popup and the full calendar.
extension View {
    func eventOverlays(_ model: CalendarModel) -> some View {
        overlay {
            if let draft = model.draft {
                ModalCard(onDismiss: { model.draft = nil }) {
                    EventEditor(model: model, draft: draft).id(draft.id)
                }
            } else if let e = model.selected {
                ModalCard(onDismiss: { model.selected = nil }) {
                    EventDetailCard(model: model, event: e).id(e.id)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.selected?.id)
        .animation(.easeOut(duration: 0.15), value: model.draft?.id)
    }
}

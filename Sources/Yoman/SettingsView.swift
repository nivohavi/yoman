import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: CalendarModel
    @Bindable var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Weekend days per the Mac's region, e.g. "Fri & Sat" in Israel.
    private var weekendNames: String {
        let cal = Calendar.current
        let start = cal.startOfWeek(for: Date())
        return cal.days(from: start, count: 7).filter(cal.isDateInWeekend).map { Fmt.f($0, "EEE") }.joined(separator: " & ")
    }

    private let dateTemplates: [(String, String)] = [
        ("EEEdMMM", "Sun 25 Oct"), ("EEEEdMMMM", "Sunday 25 October"), ("dMMM", "25 Oct"),
        ("EEEd", "Sun 25"), ("EEE", "Sun"), ("yMd", "10/25/2026"),
    ]

    var body: some View {
        TabView {
            page { general }.tabItem { Label("General", systemImage: "gearshape") }
            page { GoogleAccountsSection(model: model) }.tabItem { Label("Google", systemImage: "person.crop.circle") }
            page { menuBar }.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            page { popup }.tabItem { Label("Popup", systemImage: "rectangle.topthird.inset.filled") }
            page { calendar }.tabItem { Label("Calendar", systemImage: "calendar") }
        }
        .padding(.top, 8)
        .frame(width: 520, height: 470)
        .onChange(of: prefs.firstWeekday) { model.reload() }
        .onChange(of: prefs.hideDeclined) { model.reload(); model.reloadUpcoming() }
    }
}

extension SettingsView {
    /// One tab: a grouped form that scrolls if it is taller than the window.
    private func page<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Form { content() }.formStyle(.grouped)
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }
            Toggle("Global shortcut ⌥⌘K opens Yoman", isOn: $prefs.globalShortcut)
        }
        Section {
            Toggle("Use Apple Calendar (accounts synced by macOS)", isOn: $prefs.useAppleCalendars)
                .onChange(of: prefs.useAppleCalendars) { model.appleCalendarsToggled() }
        } footer: {
            Text("Turn off to show only Google accounts signed in on the Google tab. If a Google account is also added in Internet Accounts, turn this off or hide its “via macOS” calendars to avoid duplicates.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Section("New events") {
            Picker("Default calendar", selection: $prefs.defaultCalendarID) {
                Text("System default").tag("")
                ForEach(model.writableCalendars) { c in
                    Text("\(c.title) — \(c.sourceTitle)").tag(c.id)
                }
            }
            Picker("Default duration", selection: $prefs.defaultDuration) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
            }
        }
    }

    @ViewBuilder private var menuBar: some View {
        Section("Menu bar item") {
            Picker("Style", selection: $prefs.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Date format", selection: $prefs.menuBarDateTemplate) {
                ForEach(dateTemplates, id: \.0) { t in Text(Fmt.f(Date(), t.0)).tag(t.0) }
            }
            .disabled(prefs.menuBarStyle == .iconOnly || prefs.menuBarStyle == .dayIcon)
        }
        Section("Next meeting") {
            Toggle("Show countdown in the menu bar", isOn: $prefs.showNextEvent)
            Picker("When starting within", selection: $prefs.nextEventLookahead) {
                ForEach([10, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            .disabled(!prefs.showNextEvent)
        }
    }

    @ViewBuilder private var popup: some View {
        Section {
            Picker("Menu bar click opens", selection: $prefs.popupStyle) {
                ForEach(PopupStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Mini month size", selection: $prefs.miniMonthSize) {
                ForEach(MiniMonthSize.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Lower half shows", selection: $prefs.popupDayStyle) {
                ForEach(PopupDayStyle.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        Section {
            Slider(value: $prefs.popupWidth, in: 320...560, step: 10) {
                Text("Width (List, Day): \(Int(prefs.popupWidth)) pt")
            }
            Slider(value: $prefs.popupWideWidth, in: 520...1100, step: 10) {
                Text("Width (Week, Month): \(Int(prefs.popupWideWidth)) pt")
            }
            Slider(value: $prefs.popupHeight, in: 440...1000, step: 10) {
                Text("Height: \(Int(prefs.popupHeight)) pt")
            }
            Button("Reset size") {
                prefs.popupWidth = 360
                prefs.popupWideWidth = 680
                prefs.popupHeight = 640
            }
        } header: {
            Text("Popup size")
        } footer: {
            Text("Applies right away, even while the popup is open (pin it 📌 to watch it resize).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Section("List") {
            Stepper("Show \(prefs.agendaDays) days", value: $prefs.agendaDays, in: 1...31)
        }
        Section("Day view") {
            Toggle("Fit the day (auto hour height)", isOn: Binding(
                get: { prefs.popupHourHeight == 0 },
                set: { prefs.popupHourHeight = $0 ? 0 : 40 }))
            if prefs.popupHourHeight > 0 {
                Slider(value: $prefs.popupHourHeight, in: 16...90, step: 2) {
                    Text("Hour height: \(Int(prefs.popupHourHeight)) pt")
                }
            }
        }
        Section("Full calendar window") {
            Picker("Size", selection: $prefs.popoverSize) {
                ForEach(PopoverSize.allCases) { Text($0.rawValue).tag($0) }
            }
            Slider(value: $prefs.hourHeight, in: 20...90, step: 2) {
                Text("Hour height: \(Int(prefs.hourHeight)) pt")
            }
        }
    }

    @ViewBuilder private var calendar: some View {
        Section {
            Picker("Week starts on", selection: $prefs.firstWeekday) {
                Text("System default").tag(0)
                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
            }
            Toggle("Highlight weekends (\(weekendNames))", isOn: $prefs.highlightWeekends)
            Toggle("Show week numbers", isOn: $prefs.showWeekNumbers)
        }
        Section("Events") {
            Toggle("Dim past events", isOn: $prefs.dimPastEvents)
            Toggle("Hide declined events", isOn: $prefs.hideDeclined)
        }
    }
}

private struct GoogleAccountsSection: View {
    let model: CalendarModel
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var showSetup = false

    var body: some View {
        let google = model.google
        Section {
            ForEach(google.accounts) { a in
                HStack {
                    Image(systemName: a.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(a.error == nil ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.email)
                        Text(a.error ?? "\(a.calendars.count) calendars").font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if a.error != nil {
                        Button("Reconnect") { Task { await google.signIn() } }
                    }
                    Button("Sign Out") { google.signOut(a.email) }
                }
            }
            HStack {
                Button(google.accounts.isEmpty ? "Sign in with Google…" : "Add Another Google Account…") {
                    saveCredentials()
                    Task { await google.signIn() }
                }
                .disabled(clientID.isEmpty || google.signingIn)
                if google.signingIn {
                    ProgressView().controlSize(.small)
                    Text("Finish in your browser…").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Cancel") { google.auth.cancelSignIn() }
                }
            }
            if let err = google.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }
            DisclosureGroup("OAuth client (one-time setup)", isExpanded: $showSetup) {
                TextField("Client ID", text: $clientID, prompt: Text("xxxx.apps.googleusercontent.com"))
                SecureField("Client secret", text: $clientSecret)
                Button("Save") { saveCredentials() }
                Text("""
                1. console.cloud.google.com → create a project (in your organization, if you use Google Workspace).
                2. APIs & Services → Library → enable “Google Calendar API”.
                3. OAuth consent screen → User type “Internal” → add scope …/auth/calendar.
                4. Credentials → Create credentials → OAuth client ID → type “Desktop app”.
                5. Paste the client ID and secret here, then Sign in with Google.
                """)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.system(size: 11))
            }
        } header: {
            Text("Google accounts")
        }
        .onAppear {
            clientID = google.auth.clientID
            clientSecret = google.auth.clientSecret
            showSetup = clientID.isEmpty
        }
    }

    private func saveCredentials() {
        model.google.auth.clientID = clientID
        model.google.auth.clientSecret = clientSecret
    }
}

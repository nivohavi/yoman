import AppKit
import SwiftUI

// MARK: - Detail card

struct EventDetailCard: View {
    let model: CalendarModel
    let event: CalEvent
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 2) {
                Spacer()
                if event.isEditable {
                    IconButton(systemName: "pencil", help: "Edit") { model.edit(event) }
                    IconButton(systemName: "doc.on.doc", help: "Duplicate") { model.duplicate(event) }
                    IconButton(systemName: "trash", help: "Delete") {
                        if event.isRecurring { confirmDelete = true } else { model.delete(event) }
                    }
                }
                IconButton(systemName: "arrow.up.forward.app", help: event.webLink != nil ? "Open in Google Calendar" : "Open in Calendar") {
                    model.openInCalendarApp(event)
                }
                IconButton(systemName: "xmark", help: "Close") { model.selected = nil }
            }

            if confirmDelete {
                HStack(spacing: 8) {
                    Text("Delete recurring event:").font(.system(size: 12))
                    Button("This event") { model.delete(event) }
                    Button(event.googleRef != nil ? "All events" : "This and following") { model.delete(event, future: true) }
                    Button("Cancel") { confirmDelete = false }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hover))
            }

            row(icon: nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.system(size: 20)).textSelection(.enabled)
                    Text(event.longDateLine(model.cal)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    if event.isRecurring {
                        Text(event.recurrence == .none ? "Repeats" : event.recurrence.rawValue)
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            } leading: {
                RoundedRectangle(cornerRadius: 4).fill(event.color).frame(width: 14, height: 14).padding(.top, 6)
            }

            if let url = event.meetingURL {
                row(icon: "video") {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Join with \(MeetingLink.service(url))") { model.join(event) }
                            .buttonStyle(PrimaryButtonStyle())
                        Text(url.absoluteString).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
            }

            if let loc = event.location {
                row(icon: "mappin.and.ellipse") {
                    Button(loc) {
                        let q = loc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let u = URL(string: "maps://?q=\(q)") { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(.plain).font(.system(size: 13)).multilineTextAlignment(.leading)
                }
            }

            if !event.attendees.isEmpty {
                let attendees = event.attendees
                row(icon: "person.2") {
                    VStack(alignment: .leading, spacing: 3) {
                        let yes = attendees.filter { $0.status == .accepted }.count
                        Text("\(attendees.count) guests").font(.system(size: 13, weight: .medium))
                        Text("\(yes) yes · \(attendees.count - yes) other").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        ForEach(Array(attendees.prefix(6).enumerated()), id: \.offset) { _, a in
                            HStack(spacing: 6) {
                                Image(systemName: statusIcon(a.status)).font(.system(size: 10))
                                    .foregroundStyle(a.status == .accepted ? .green : a.status == .declined ? .red : Theme.secondary)
                                Text(a.name.isEmpty ? a.email : a.name).font(.system(size: 12)).lineLimit(1)
                                if a.isOrganizer {
                                    Text("Organizer").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        if attendees.count > 6 {
                            Text("+\(attendees.count - 6) more").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }

            if event.googleRef == nil, let me = event.selfAttendee, !me.isOrganizer {
                // Apple's calendar API can't send RSVPs; hand off to Google Calendar or the Calendar app.
                row(icon: "hand.raised") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(me.status == .needsAction ? "You haven't responded" : "You answered: \(statusLabel(me.status))")
                            .font(.system(size: 13))
                        HStack(spacing: 8) {
                            if model.googleWebLink(for: event) != nil {
                                Button("Respond in Google Calendar") { model.respondInGoogle(event) }
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                            Button("Calendar app") { model.openInCalendarApp(event) }
                                .buttonStyle(PillButtonStyle())
                        }
                    }
                }
            }

            if event.googleRef != nil, let me = event.selfAttendee, !me.isOrganizer {
                row(icon: "hand.raised") {
                    HStack(spacing: 6) {
                        Text("Going?").font(.system(size: 13))
                        ForEach([(Attendee.Status.accepted, "Yes"), (.declined, "No"), (.tentative, "Maybe")], id: \.1) { status, label in
                            Button(label) { model.rsvp(event, status) }
                                .buttonStyle(RSVPButtonStyle(selected: me.status == status))
                        }
                    }
                }
            }

            if !event.alertMinutes.isEmpty {
                row(icon: "bell") {
                    Text(event.alertMinutes.map { EventDraft.alertLabel($0) }.joined(separator: ", "))
                        .font(.system(size: 13))
                }
            }

            row(icon: "calendar") {
                Text("\(event.calendarTitle) · \(event.calendar.sourceTitle)")
                    .font(.system(size: 13))
            }

            if let err = model.errorMessage {
                Text(err).font(.system(size: 12)).foregroundStyle(.red)
            }

            if let notes = event.notes {
                row(icon: "text.alignleft") {
                    ScrollView {
                        Text(notes).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
        .frame(maxWidth: 420)
    }

    private func statusLabel(_ s: Attendee.Status) -> String {
        switch s {
        case .accepted: "Yes"
        case .declined: "No"
        case .tentative: "Maybe"
        case .needsAction: "—"
        }
    }

    private func statusIcon(_ s: Attendee.Status) -> String {
        switch s {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle"
        case .tentative: "questionmark.circle"
        default: "circle"
        }
    }

    private func row<C: View>(icon: String?, @ViewBuilder content: () -> C) -> some View {
        row(icon: icon, content: content) {
            Image(systemName: icon ?? "circle").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .frame(width: 14).padding(.top, 2)
        }
    }

    private func row<C: View, L: View>(icon: String?, @ViewBuilder content: () -> C, @ViewBuilder leading: () -> L) -> some View {
        HStack(alignment: .top, spacing: 16) {
            leading().frame(width: 18)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Editor

struct EventEditor: View {
    let model: CalendarModel
    @State var draft: EventDraft
    @FocusState private var titleFocused: Bool
    @State private var showMore = false

    var body: some View {
        let isNew = draft.existing == nil
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isNew ? "New event" : "Edit event").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                IconButton(systemName: "xmark", help: "Discard") { model.draft = nil }
            }

            TextField("Add title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($titleFocused)
                .onSubmit(save)
            Rectangle().fill(titleFocused ? Theme.blue : Theme.grid).frame(height: titleFocused ? 2 : 1)

            field("clock") {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits {
                        HStack {
                            startPicker
                            Text("–").foregroundStyle(Theme.secondary)
                            endPicker
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            startPicker
                            endPicker
                        }
                    }
                    HStack(spacing: 16) {
                        Toggle("All day", isOn: $draft.allDay).toggleStyle(.checkbox)
                        Picker("", selection: $draft.recurrence) {
                            ForEach(Recurrence.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            .onChange(of: draft.start) { old, new in
                // Keep duration when start moves, like Google Calendar.
                draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
            }

            field("calendar") {
                Picker("", selection: $draft.calendarID) {
                    ForEach(model.writableCalendars) { c in
                        Label { Text("\(c.title) — \(c.sourceTitle)") } icon: { Image(nsImage: colorDot(c.nsColor)) }
                            .tag(c.id)
                    }
                }
                .labelsHidden().fixedSize()
            }

            if model.calendar(withID: draft.calendarID)?.isGoogle == true, draft.existing?.meetingURL == nil {
                field("video") {
                    Toggle("Add Google Meet video conferencing", isOn: $draft.addMeet).toggleStyle(.checkbox)
                }
            }

            field("mappin.and.ellipse") {
                TextField("Add location", text: $draft.location).textFieldStyle(.roundedBorder)
            }

            field("bell") {
                Picker("", selection: $draft.alertMinutes) {
                    ForEach(EventDraft.alertChoices, id: \.self) { Text(EventDraft.alertLabel($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }

            if showMore || !draft.url.isEmpty || !draft.notes.isEmpty {
                field("link") {
                    TextField("Add video call or URL", text: $draft.url).textFieldStyle(.roundedBorder)
                }
                field("text.alignleft") {
                    TextEditor(text: $draft.notes)
                        .font(.system(size: 12.5))
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                }
            } else {
                Button("More options") { showMore = true }.buttonStyle(.plain).foregroundStyle(Theme.blue)
                    .font(.system(size: 12.5, weight: .medium)).padding(.leading, 34)
            }

            if let existing = draft.existing, existing.isRecurring {
                field("repeat") {
                    Picker("", selection: $draft.applyToFuture) {
                        Text("Only this event").tag(false)
                        Text(existing.googleRef != nil ? "All events (details only, not time)" : "This and following events").tag(true)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
            }

            if let err = model.errorMessage {
                Text(err).font(.system(size: 12)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.draft = nil }.buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Button(action: save) {
                    if model.busy { ProgressView().controlSize(.small).tint(Theme.onBlue) } else { Text("Save") }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
        .padding(20)
        .frame(maxWidth: 480)
        .onAppear {
            model.errorMessage = nil
            titleFocused = true
        }
    }

    private var startPicker: some View {
        DatePicker("", selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
            .labelsHidden()
    }

    private var endPicker: some View {
        DatePicker("", selection: $draft.end, in: draft.start..., displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
            .labelsHidden()
    }

    private func save() { model.save(draft) }

    private func field<C: View>(_ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: icon).foregroundStyle(Theme.secondary).frame(width: 18)
            content()
            Spacer(minLength: 0)
        }
    }
}

struct RSVPButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Theme.onBlue : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(selected ? Theme.blue : configuration.isPressed ? Theme.selected : .clear))
            .overlay(Capsule().strokeBorder(selected ? .clear : Theme.grid))
            .contentShape(Capsule())
    }
}

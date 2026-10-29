import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
enum YomanMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar only, like Itsycal's LSUIElement
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = CalendarModel()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private let hotKey = HotKey()
    private var lastDay = Calendar.current.startOfDay(for: Date())

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "YomanStatusItem"
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusItemClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
        }

        // `--no-focus` (testing) keeps the popup open: an unfocused transient popover closes at once.
        popover.behavior = CommandLine.arguments.contains("--no-focus") ? .applicationDefined : .transient
        popover.delegate = self
        popover.animates = false
        configurePopover()

        model.onUpcomingChange = { [weak self] in self?.updateStatusItem() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openWindow = { [weak self] in self?.showWindow() }
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }
        model.onPinChange = { [weak self] pinned in self?.popover.behavior = pinned ? .applicationDefined : .transient }
        Prefs.shared.onChange = { [weak self] in self?.prefsChanged() }

        HotKey.action = { [weak self] in self?.togglePopover() }
        applyHotKey()
        updateStatusItem()

        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        for name in [NSNotification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dayChanged() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        }

        Task { await model.requestAccess() }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--mode=") }),
           let mode = ViewMode.allCases.first(where: { $0.rawValue.lowercased() == arg.dropFirst(7).lowercased() }) {
            model.mode = mode
        }
        if CommandLine.arguments.contains("--dump-sources") { Task { [model] in
            await model.requestAccess()
            try? await Task.sleep(for: .seconds(1))  // calendar loading is debounced
            print("access=\(model.access)")
            // Diagnostics: every account and calendar EventKit exposes, including disabled/empty ones.
            for src in model.store.sources {
                let cals = src.calendars(for: .event)
                print("SOURCE title=\(src.title) type=\(src.sourceType.rawValue) id=\(src.sourceIdentifier) calendars=\(cals.count)")
                for c in cals { print("   - \(c.title) [\(c.allowsContentModifications ? "rw" : "ro")]") }
            }
            print("EK event calendars total: \(model.store.calendars(for: .event).count)")
            if let day = model.launchDate {
                let cal = Calendar.current
                let s = cal.startOfDay(for: day), e = cal.date(byAdding: .day, value: 1, to: s)!
                let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
                print("EVENTS on \(f.string(from: s)):")
                for ev in model.fetch(DateInterval(start: s, end: e)) {
                    print("  [\(ev.calendar.title) / \(ev.calendar.sourceTitle)] \(ev.title) | \(f.string(from: ev.start)) → \(f.string(from: ev.end)) allDay=\(ev.isAllDay) rsvp=\(ev.selfAttendee?.status.rawValue ?? "-") hidden=\(!model.isVisible(ev.calendar)) ext=\(ev.ekEvent?.calendarItemExternalIdentifier ?? "-") eid=\(ev.ekEvent?.eventIdentifier ?? "-") recurring=\(ev.isRecurring) organizer=\(ev.ekEvent?.organizer?.url.absoluteString ?? "-") link=\(model.googleWebLink(for: ev)?.absoluteString ?? "-")")
                }
            }
            fflush(stdout)
            NSApp.terminate(nil)
        } }
        if CommandLine.arguments.contains("--selftest") { Task { await Self.selfTest(); NSApp.terminate(nil) } }
        if CommandLine.arguments.contains("--window") { showWindow() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        // Testing: `--popup-cycle=N` opens and closes the popup N times (2 s apart), ending closed.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--popup-cycle=") }), let n = Int(arg.dropFirst(14)) {
            for i in 0..<(n * 2) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 2) { [weak self] in self?.togglePopover() }
            }
        }
        if CommandLine.arguments.contains("--popup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover() }
        }
        if CommandLine.arguments.contains("--new-event") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [model] in model.newDraft() }
        }
    }

    /// Exercises the Google plumbing that doesn't need real credentials.
    private static func selfTest() async {
        // 1. Loopback redirect receiver: start, hit it like a browser would, read back the params.
        let server = LoopbackServer()
        do {
            let port = try await server.start()
            async let params = server.waitForCallback(timeout: 10)
            let (body, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=abc123&state=xyz")!)
            let p = try await params
            print("loopback: port=\(port) status=\((resp as? HTTPURLResponse)?.statusCode ?? 0) code=\(p["code"] ?? "nil") state=\(p["state"] ?? "nil") page=\(String(data: body, encoding: .utf8)?.contains("connected") == true ? "ok" : "bad")")
        } catch { print("loopback: FAILED \(error)") }
        server.stop()
        // 2. Token endpoint round-trip with a bogus client: expect Google's invalid_client error, surfaced cleanly.
        do {
            _ = try await GoogleAuth.postForm("https://oauth2.googleapis.com/token",
                                              ["client_id": "bogus.apps.googleusercontent.com", "client_secret": "x",
                                               "refresh_token": "x", "grant_type": "refresh_token"])
            print("token: unexpected success")
        } catch { print("token: error surfaced -> \(error.localizedDescription)") }
        // 3. Calendar API without a token: expect a 401 message.
        let (d, r) = (try? await URLSession.shared.data(from: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!)) ?? (Data(), URLResponse())
        print("calendar api reachable: status=\((r as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(d.count)")
        fflush(stdout)
    }

    // MARK: Status item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "New Event…", action: #selector(newEvent), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Open in Window", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(withTitle: "Quit Yoman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let b = statusItem.button {
            model.refreshNow()
            configurePopover()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            // `--no-focus` (testing): show without taking the keyboard from the app you're typing in.
            guard !CommandLine.arguments.contains("--no-focus") else { return }
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func newEvent() {
        if !popover.isShown { togglePopover() }
        model.newDraft()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let prefs = Prefs.shared
        let now = Date()
        var text = ""
        switch prefs.menuBarStyle {
        case .iconAndDate, .dateOnly: text = Fmt.f(now, prefs.menuBarDateTemplate)
        case .dayIcon, .iconOnly: text = ""
        }
        if prefs.showNextEvent, let e = model.nextEvent {
            let until = e.start.timeIntervalSince(now)
            if until <= TimeInterval(prefs.nextEventLookahead * 60) {
                let t = e.title.count > 22 ? String(e.title.prefix(21)) + "…" : e.title
                let when = until <= 0 ? "now" : "in \(Fmt.relative(until))"
                text += (text.isEmpty ? "" : "  ·  ") + "\(t) \(when)"
            }
        }
        button.title = text.isEmpty ? "" : (prefs.menuBarStyle == .dateOnly ? text : " " + text)
        switch prefs.menuBarStyle {
        case .dayIcon: button.image = StatusIcon.day(Calendar.current.component(.day, from: now))
        case .iconAndDate, .iconOnly: button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Yoman")
        case .dateOnly: button.image = nil
        }
        button.toolTip = Fmt.f(now, "EEEEMMMMdy")
    }

    private func tick() {
        if Calendar.current.startOfDay(for: Date()) != lastDay { dayChanged(); return }
        model.now = Date()
        updateStatusItem()
    }

    private func dayChanged() {
        lastDay = Calendar.current.startOfDay(for: Date())
        model.refreshNow()
        model.reload()
        updateStatusItem()
    }

    private func prefsChanged() {
        applyHotKey()
        configurePopover()
        updateStatusItem()
    }

    /// Week and Month need room for seven columns, so the compact popup widens for them.
    private static func compactSize(_ pane: PopupDayStyle) -> CGSize {
        let p = Prefs.shared
        // Never taller than the screen below the menu bar.
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        let width = pane == .week || pane == .month ? p.popupWideWidth : p.popupWidth
        return CGSize(width: width, height: min(p.popupHeight, maxH))
    }
    private var popupStyleInUse: PopupStyle?

    /// The menu-bar popup is either the compact month + agenda (default) or the full calendar.
    private func configurePopover() {
        let style = Prefs.shared.popupStyle
        if popupStyleInUse != style {
            let host: NSViewController = switch style {
            case .compact: NSHostingController(rootView: CompactView(model: model))
            case .full: NSHostingController(rootView: RootView(model: model))
            }
            (host as? NSHostingController<CompactView>)?.sizingOptions = []
            (host as? NSHostingController<RootView>)?.sizingOptions = []
            popover.contentViewController = host
            popupStyleInUse = style
        }
        popover.contentSize = style == .compact ? Self.compactSize(Prefs.shared.popupDayStyle) : Prefs.shared.popoverSize.size
    }

    private func applyHotKey() {
        if Prefs.shared.globalShortcut {
            hotKey.register(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))
        } else {
            hotKey.unregister()
        }
    }

    // MARK: Windows

    @objc private func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Prefs.shared.popoverSize.size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Yoman"
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: RootView(model: model).padding(.top, 6))
            w.setContentSize(Prefs.shared.popoverSize.size)
            w.minSize = NSSize(width: 760, height: 480)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("YomanMainWindow")
            w.delegate = self
            w.center()
            window = w
        }
        if CommandLine.arguments.contains("--no-focus") {  // testing: show without taking the keyboard
            window?.orderFrontRegardless()
            return
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Yoman Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closed windows and the closed popup drop their SwiftUI content; it's rebuilt when reopened.
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === window {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { [weak self] in self?.window = nil }
        } else if w === settingsWindow {
            DispatchQueue.main.async { [weak self] in self?.settingsWindow = nil }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        popupStyleInUse = nil
    }
}

// MARK: - Menu bar day icon (Itsycal-style calendar page with the day number)

enum StatusIcon {
    static func day(_ day: Int) -> NSImage {
        let size = NSSize(width: 19, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let r = NSRect(x: 1, y: 0.5, width: 17, height: 15)
            let path = NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5)
            path.lineWidth = 1.2
            NSColor.black.setStroke()
            path.stroke()
            // Header band
            let band = NSBezierPath()
            band.move(to: NSPoint(x: 1, y: 11.5)); band.line(to: NSPoint(x: 18, y: 11.5))
            band.lineWidth = 1.2
            band.stroke()
            let s = "\(day)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: NSColor.black,
            ]
            let ts = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: (size.width - ts.width) / 2, y: 0.4), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Global hot key (Carbon; no extra permissions needed)

final class HotKey {
    static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4459_4252), id: 1)  // 'DYBR'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

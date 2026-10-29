<p align="center">
  <img src="Resources/AppIcon-preview.png" width="128" alt="Yoman icon">
</p>

<h1 align="center">Yoman</h1>

<p align="center">A menu-bar calendar for macOS with a Google-Calendar-style interface.<br>
<i>Yoman</i> (יומן) is Hebrew for "diary / calendar".</p>

---

Click the date in your menu bar to get a month at a glance plus your day, week or month,
styled like Google Calendar. Inspired by [Itsycal](https://www.mowglii.com/itsycal/), rebuilt
in SwiftUI with more views and multi-account support. Not affiliated with Google or Mowglii.

## Features

- **Menu-bar popup** – mini month with colored event dots and a highlighted weekend, plus a
  lower pane you can switch between **List**, **Day**, **Week** and **Month**.
- **Google-Calendar look** – time grid with a red "now" line, overlapping events laid out
  side by side or cascaded, all-day lane, outlined/striped/struck-through blocks for
  unanswered, "maybe" and declined invites, readable text on light colors.
- **Full calendar window** (⤢) – Day / Week / Month / Schedule with a sidebar, search and
  per-account calendar toggles.
- **Meetings** – detects Zoom, Google Meet, Teams, Webex, FaceTime and Chime links: one-click
  **Join**, plus a "Standup in 5m" countdown in the menu bar.
- **Create, edit, duplicate, delete** events (repeat, alert, location, notes, Google Meet).
- **Multiple calendars and accounts** – everything macOS syncs (iCloud, Google, Exchange…)
  and, optionally, Google accounts signed in directly via the Google Calendar API
  (adds RSVP, Google event colors, Meet creation).
- **Keyboard** – ⌥⌘K opens it anywhere; `d` `w` `m` `l` switch views, `t` today, `n` new
  event, arrows move the selection.
- Configurable popup size, hour height, mini-month size, week start, week numbers, weekend
  highlight, menu-bar style and more. Handles daylight-saving days and right-to-left text.

## Requirements

- macOS 14 (Sonoma) or later
- To build: Apple's Command Line Tools (`xcode-select --install`) or Xcode

## Download (easiest)

1. Download **Yoman-x.y.z.dmg** from the [latest release](https://github.com/nivohavi/yoman/releases/latest).
2. Open it and drag **Yoman** onto **Applications**.
3. Open Yoman from Applications. macOS says it can't verify the developer (the app isn't signed with
   a paid Apple Developer ID) — click **Done**, then go to **System Settings › Privacy & Security**,
   scroll down and click **Open Anyway** next to Yoman. You only do this once.
4. Allow calendar access when asked, and find the calendar icon in your menu bar (or press **⌥⌘K**).

Prefer not to approve a downloaded app? Build it yourself instead — see below.

## Install from source

Takes about 2 minutes. You build it on your own Mac, so there's no security prompt.

**1. Make sure you have Apple's build tools.** If `git --version` works, you already do; otherwise:

```bash
xcode-select --install
```

**2. Download and install Yoman:**

```bash
git clone https://github.com/nivohavi/yoman.git ~/yoman
cd ~/yoman && ./build.sh install
```

This builds the app and copies it to **/Applications/Yoman.app**, then starts it.

**3. Allow calendar access.** On first launch macOS asks — choose **Allow Full Access**.
Yoman shows every calendar your Mac already syncs (System Settings › Internet Accounts),
so Google accounts added there appear automatically.

**4. Find it in the menu bar** — a small calendar icon with today's date. Click it, or press **⌥⌘K** anywhere.
Optional: **Settings › General › Launch at login**.

### Update

```bash
cd ~/yoman && git pull && ./build.sh install
```

### Uninstall

Quit Yoman (right-click the menu-bar icon › Quit), then delete **/Applications/Yoman.app** and the `~/yoman` folder.

### Troubleshooting

- **No icon in the menu bar?** Crowded menu bars (especially with a notch) hide new icons. Press **⌥⌘K**,
  ⌘-drag other icons to make room, or quit a few menu-bar apps.
- **"Connect a calendar" / no events?** Allow access in **System Settings › Privacy & Security › Calendars › Yoman**.
- **A Google calendar is missing?** It must be synced to your Mac: add the account in Internet Accounts with
  Calendars on, and tick shared calendars at <https://calendar.google.com/calendar/syncselect>.
- **`xcrun: error` / `swift: command not found`?** Run step 1 again.

## Google sign-in (optional)

Yoman works out of the box with accounts added in **System Settings › Internet Accounts**.
For RSVP, Google event colors and Meet links, connect Google directly:

1. In [Google Cloud Console](https://console.cloud.google.com/apis/credentials) create a project
   and enable the **Google Calendar API**.
2. Configure the OAuth consent screen (Internal for Workspace, or External + add yourself as a
   test user) with the `…/auth/calendar` scope.
3. Create an **OAuth client ID** of type **Desktop app**.
4. In Yoman: **Settings › Google**, paste the client ID and secret, then **Sign in with Google**.

Sign-in uses the browser with PKCE and a loopback redirect; tokens are stored in your Keychain.
Turn off **Use Apple Calendar** if the same account is also synced by macOS, to avoid duplicates.

## Privacy

Yoman has no server and no analytics. Calendar data is read on your Mac through Apple's
EventKit; when Google sign-in is used, it talks only to Google's Calendar API.

## Project layout

| Path | What |
|---|---|
| `Sources/Yoman/YomanApp.swift` | App entry, menu-bar item, popover, windows, global hot key |
| `Sources/Yoman/CalendarModel.swift` | Merges EventKit and Google calendars; fetching and editing |
| `Sources/Yoman/GoogleAuth.swift`, `GoogleStore.swift` | OAuth (PKCE + loopback) and Calendar API client |
| `Sources/Yoman/CompactView.swift`, `PopupTimeline.swift` | The menu-bar popup |
| `Sources/Yoman/RootView.swift`, `TimeGridView.swift`, `MonthAndScheduleViews.swift` | Full calendar views |
| `scripts/make-icon.swift` | Renders `Resources/AppIcon.icns` |
| `build.sh` | Builds, signs (ad-hoc), installs and restarts the app |

Developer flags (for testing): `--demo` (fictional calendar, no access needed), `--popup`, `--window`,
`--mode=week`, `--date=YYYY-MM-DD`, `--no-focus`, `--dump-sources`, `--selftest`.

## License

[MIT](LICENSE)

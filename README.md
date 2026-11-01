# UsageBar

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

Shows your remaining **Claude** and **Codex** usage (5-hour and weekly limits) in the macOS menu bar or the Windows / Linux tray, and on the desktop.

- **Menu bar**: `Claude 68%/79%  Codex 0%/47%` — the 5-hour limit, the weekly limit, or both, on one line or two (name above, value below); click to see every limit's progress and reset time. A ↑ marks a limit used faster than its period is passing, and the menu says when it will run out at that pace
- **Notifications**: when a limit reaches 80/90/95%, when it is on pace to run out before reset, after a reset, and before a Codex reset expires
- **Two desktop cards**: a limits card (each limit with a progress bar and reset time) and a usage card (estimated cost, requests, tokens and cache hit rate for today, since reset or the last 7 days). Both sit on the desktop layer or stay on top, are draggable, and remember their place on each display — if a display goes away the card moves to the main one and comes back when it returns
- **Usage statistics**: like CC Switch's — cost, requests, tokens and cache hit rate for any period, an hourly or daily chart, a GitHub-style daily heatmap, and tables by app, by model, by project (working directory) and per request (hit rate, speed, time to first token, duration, status code; resizable, reorderable columns; click a request for its details). Built from local Claude Code and Codex session logs, read incrementally into a local SQLite database (statistics survive Claude Code's log cleanup); cost uses [models.dev](https://models.dev) API prices. Codex running on other machines can be added over SSH (filtered remotely, so only a few percent of the log is transferred) and viewed per machine. Your OpenAI account's daily token totals are shown separately as server statistics
- **Settings**: the menu bar and each card have their own options (which services, remaining or used, layout, size up to 250%, background, text color, opacity); plus launch at login, appearance, language, theme color and refresh intervals
- **In-app updates**: checks GitHub Releases daily; one click downloads the new version, verifies its SHA-256, replaces the app and restarts
- **Languages**: English / 简体中文 / 日本語, following the system by default
- Requires macOS 13 or later, Apple silicon and Intel
- **Windows / Linux**: the same features in the system tray, including usage statistics, notifications, both cards, remote machines and in-app updates. Linux shows the percentages next to the tray icon; on Windows hover over the icon or click it for a panel. Windows 10/11 x64 (also runs on Windows on ARM), Linux x64 and arm64; source in `tauri/`

## Install

### macOS

1. Download `UsageBar-x.y.z.zip` from [Releases](https://github.com/plsy1/UsageBar/releases), unzip it and drag `UsageBar.app` into Applications.
2. The app has no Apple Developer ID signature, so macOS blocks it the first time. Allow it either way:
   - after trying to open it once, go to **System Settings → Privacy & Security** and click **Open Anyway** near the bottom;
   - or run in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. Click UsageBar in the menu bar → **Open UsageBar…** → General to turn on **Launch at Login**. Updates are under **About**.

### Windows

Run `UsageBar-x.y.z-windows-x64-setup.exe` from [Releases](https://github.com/plsy1/UsageBar/releases). It isn't code-signed, so SmartScreen may say "Windows protected your PC": click **More info → Run anyway**. Launch at login is under Settings, updates under About.

### Linux

- **deb** (Ubuntu, Debian): `sudo apt install ./UsageBar-x.y.z-linux-amd64.deb` (or `arm64`). For updates, install the new deb the same way.
- **AppImage**: `chmod +x UsageBar-x.y.z-linux-amd64.AppImage` and run it; it updates itself from About.
- The tray needs AppIndicator support (built into Ubuntu; on other GNOME desktops install the AppIndicator extension).

## Where the numbers come from

### Limits

Choose per service under General → Data Sources; a change takes effect immediately:

| | Official API (default) | Local Only |
|---|---|---|
| **Claude** | Reads Claude Code's login from the Keychain and calls `api.anthropic.com/api/oauth/usage` (the endpoint behind the `/usage` command). Needs Claude Code to be logged in (`claude auth login`, or having used Claude Code in the Claude desktop app). macOS may ask once to allow Keychain access. | Reads `~/Library/Application Support/Claude/plan-usage-history.json`, written by the Claude desktop app: 5-hour and weekly percentages only, no reset times, and only updated when the app shows usage, so **it may be out of date**. Values older than their window are hidden. |
| **Codex** | Reads the login from `~/.codex/auth.json` and calls `chatgpt.com/backend-api/wham/usage`; when resets are available it also asks for their expiry, and the server statistics on the stats page are fetched at most hourly. Falls back to the session logs if a request fails. | Reads the session logs: Codex records the limits (used share and reset time) after every reply, so this is near real-time while you use Codex. Logs on this Mac and on added remote machines both count; the newest wins. |

**What the official API mode sends:** GET requests without a body, carrying the login token, the Codex account ID and the same User-Agent as the official clients (`claude-code`, `codex-cli`). No conversation content, usage records or other local data is uploaded. When Claude's token expires, UsageBar refreshes it the way Claude Code does and writes it back to the Keychain.

**Local Only** sends no requests and doesn't read the Keychain or `auth.json`; the Codex server statistics and reset counts are not shown then.

**On Windows and Linux** Claude Code keeps its login in `~/.claude/.credentials.json` (`%USERPROFILE%\.claude` on Windows), which is read instead of the Keychain; Local Only reads the Claude desktop app's file from `%APPDATA%\Claude` or `~/.config/Claude`. The settings are under Settings → Data Sources.

The limit endpoints are not public APIs and may stop working if Anthropic or OpenAI change them.

### Usage statistics

Usage statistics need no login; everything stays on this Mac:

- **Session logs:** `~/.claude/projects` (including Claude Code sessions in the Claude desktop app) and `~/.codex/sessions`, read incrementally. Regular chats in the Claude desktop app keep no local records, so they are not in the statistics (they do count toward the limits).
- **Remote machines:** Codex logs on machines added under General → Data Sources, read over `ssh` and filtered on the remote side (a few percent of each log is transferred). Needs password-less `ssh` (e.g. a key); for machines on your local network, allow UsageBar under System Settings → Privacy & Security → Local Network.
- **Local database:** parsed records are kept in `~/Library/Application Support/UsageBar/usage.sqlite` (Windows: `%APPDATA%\io.github.plsy1.usagebar`, Linux: `~/.local/share/io.github.plsy1.usagebar`), so statistics survive Claude Code's log cleanup.
- **Cost:** estimated from [models.dev](https://models.dev) API prices (downloaded daily), not what a subscription actually charges.

## Build from source

```bash
./install.sh          # build for this Mac, install to /Applications and launch
./release.sh          # package a universal binary as dist/UsageBar-<version>.zip
```

Windows / Linux: `cd tauri/src-tauri && cargo tauri build` (needs Rust and [Tauri's prerequisites](https://v2.tauri.app/start/prerequisites/)); CI builds the installers on every push to `tauri/`.

Print usage in Terminal: `/Applications/UsageBar.app/Contents/MacOS/UsageBar --print` (limits) or `--stats` (local token statistics)

## Uninstall

Turn off **Launch at Login** in Open UsageBar… → General, quit UsageBar, then delete `/Applications/UsageBar.app`.

Windows: uninstall UsageBar from Settings → Apps. Linux: `sudo apt remove usage-bar` for the deb, or delete the AppImage.

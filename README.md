# UsageBar

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

Shows your remaining **Claude** and **Codex** usage (5-hour and weekly limits) in the macOS menu bar and on the desktop.

- **Menu bar**: `Claude 68/79%  Codex 0/47%` — the 5-hour limit, the weekly limit, or both; click to see every limit's progress and reset time
- **Two desktop cards**: a limits card (each limit with a progress bar and reset time) and a usage card (estimated cost, requests, tokens and cache hit rate for today, since reset or the last 7 days). Both sit on the desktop layer or stay on top, are draggable, and remember their place on each display — if a display goes away the card moves to the main one and comes back when it returns
- **Usage statistics**: like CC Switch's — cost, requests, tokens and cache hit rate for any period, an hourly or daily chart, and tables by app, by model and per request (hit rate, speed, time to first token, duration, status code; resizable, reorderable columns; click a request for its details). Built from local Claude Code and Codex session logs, read incrementally; cost uses [models.dev](https://models.dev) API prices. Codex running on other machines can be added over SSH (filtered remotely, so only a few percent of the log is transferred) and viewed per machine. Your OpenAI account's daily token totals are shown separately as server statistics
- **Settings**: the menu bar and each card have their own options (which services, remaining or used, layout, size up to 250%, background, text color, opacity); plus launch at login, appearance, language, theme color and refresh intervals
- **In-app updates**: checks GitHub Releases daily; one click downloads the new version, verifies its SHA-256, replaces the app and restarts
- **Languages**: English / 简体中文 / 日本語, following the system by default
- Requires macOS 13 or later, Apple silicon and Intel
- **Windows / Linux**: a [preview](https://github.com/plsy1/UsageBar/releases/tag/tauri-v0.3.0) with the tray, both desktop cards (limits and usage), limits and settings (source in `tauri/`)

## Install

1. Download `UsageBar-x.y.z.zip` from [Releases](https://github.com/plsy1/UsageBar/releases), unzip it and drag `UsageBar.app` into Applications.
2. The app has no Apple Developer ID signature, so macOS blocks it the first time. Allow it either way:
   - after trying to open it once, go to **System Settings → Privacy & Security** and click **Open Anyway** near the bottom;
   - or run in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. Click UsageBar in the menu bar → **Open UsageBar…** → General to turn on **Launch at Login**. Updates are under **About**.

## Requirements for reading usage

- **Claude**: the Claude Code CLI must be logged in (`claude auth login`). UsageBar reads Claude Code's login from the Keychain and calls `api.anthropic.com/api/oauth/usage`. When the token expires it refreshes it and writes it back to the Keychain, the same way Claude Code does. macOS may ask once whether to allow Keychain access.
- **Codex**: Codex must be logged in (`~/.codex/auth.json` exists). UsageBar calls `chatgpt.com/backend-api/wham/usage` and falls back to the latest usage recorded in `~/.codex/sessions` if that fails.

Statistics cover session logs on this Mac plus the remote machines added under General → Data Sources (`ssh` must log in without a password, e.g. with a key; if the machine is on your local network, allow UsageBar under System Settings → Privacy & Security → Local Network). Cost is an API-price estimate, not what a subscription actually charges. Prices are downloaded from models.dev once a day.

The limit endpoints are not public APIs and may stop working if Anthropic or OpenAI change them. Data only travels between your Mac and the respective official service.

## Build from source

```bash
./install.sh          # build for this Mac, install to /Applications and launch
./release.sh          # package a universal binary as dist/UsageBar-<version>.zip
```

Print usage in Terminal: `/Applications/UsageBar.app/Contents/MacOS/UsageBar --print` (limits) or `--stats` (local token statistics)

## Uninstall

Turn off **Launch at Login** in Open UsageBar… → General, quit UsageBar, then delete `/Applications/UsageBar.app`.

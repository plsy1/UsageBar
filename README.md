# UsageBar

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

Shows your remaining **Claude** and **Codex** usage (5-hour and weekly limits) in the macOS menu bar and on the desktop.

- **Menu bar**: `Cc 61%  Cx 53%` (Claude Code / Codex), showing the tightest limit for each; click to see every limit's progress and reset time
- **Desktop card**: sits on the desktop layer, draggable; right-click to refresh, open Settings or hide it
- **Usage statistics**: a window like CC Switch's — estimated cost, requests, tokens and cache hit rate for today / 7 / 30 days, an hourly or daily chart, and per-model and per-request tables. Built from local Claude Code and Codex session logs; cost uses [models.dev](https://models.dev) API prices
- **Settings**: launch at login, language, show remaining or used, refresh interval; card background (none / dark / light frosted glass), glass strength, text color, size, opacity; short or full names in the menu bar
- **Languages**: English / 简体中文 / 日本語, following the system by default
- Requires macOS 13 or later, Apple silicon and Intel

## Install

1. Download `UsageBar-x.y.z.zip` from [Releases](https://github.com/plsy1/UsageBar/releases), unzip it and drag `UsageBar.app` into Applications.
2. The app has no Apple Developer ID signature, so macOS blocks it the first time. Allow it either way:
   - after trying to open it once, go to **System Settings → Privacy & Security** and click **Open Anyway** near the bottom;
   - or run in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/UsageBar.app
     ```
3. Click UsageBar in the menu bar → Settings… → General to turn on **Launch at Login**.

## Requirements for reading usage

- **Claude**: the Claude Code CLI must be logged in (`claude auth login`). UsageBar reads Claude Code's login from the Keychain and calls `api.anthropic.com/api/oauth/usage`. When the token expires it refreshes it and writes it back to the Keychain, the same way Claude Code does. macOS may ask once whether to allow Keychain access.
- **Codex**: Codex must be logged in (`~/.codex/auth.json` exists). UsageBar calls `chatgpt.com/backend-api/wham/usage` and falls back to the latest usage recorded in `~/.codex/sessions` if that fails.

Statistics only cover session logs on this Mac, and cost is an API-price estimate, not what a subscription actually charges. Prices are downloaded from models.dev once a day.

The limit endpoints are not public APIs and may stop working if Anthropic or OpenAI change them. Data only travels between your Mac and the respective official service.

## Build from source

```bash
./install.sh          # build for this Mac, install to /Applications and launch
./release.sh          # package a universal binary as dist/UsageBar-<version>.zip
```

Print usage in Terminal: `/Applications/UsageBar.app/Contents/MacOS/UsageBar --print` (limits) or `--stats` (local token statistics)

## Uninstall

Turn off **Launch at Login** in Settings → General, quit UsageBar, then delete `/Applications/UsageBar.app`.

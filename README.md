# Mac Mobile Dev Helper

A small native macOS utility for Android device files, mobile-development cleanup, and system diagnostics. Each feature is presented in a collapsible section.

## Install

Build from source and install into `/Applications` with one Terminal command:

```sh
curl -fsSL https://raw.githubusercontent.com/DawidMoza/mac-mobile-dev-helper/main/scripts/install.sh | bash
```

Requirements:

- macOS 13 or newer
- Xcode command-line tools with Swift 6
- Android SDK Platform-Tools for the Android filesystem feature

To install a specific tagged version:

```sh
curl -fsSL https://raw.githubusercontent.com/DawidMoza/mac-mobile-dev-helper/main/scripts/install.sh | bash -s -- v0.1.3
```

## Features

### Android filesystem browser and editor

- Detects authorized Android devices through an installed `adb`
- Browses the selected device's shared storage
- Selects files with one click, Shift-click for a range, or Command-click to toggle individual items; double-click opens a file or folder
- Clickable Name, Size, and Modified headers sort in either direction, keeping folders first and retaining the sort when refreshing or opening another folder
- Opens and safely edits UTF-8 and BOM-marked UTF-16 text files up to 1 MB
- Uploads, downloads, renames, creates folders, and permanently deletes with confirmation
- Downloads or deletes multiple selected items together; batch downloads use a destination folder and reject existing filenames

The browser is intentionally limited to shared storage (the canonical `/sdcard` location). It does not request root access or attempt to read app-private data. Access to folders such as `Android/data` and `Android/obb` can still be restricted by the Android version or phone manufacturer.

To connect a phone:

1. Install [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools).
2. Enable Developer options and USB debugging on the phone.
3. Connect it by USB, unlock it, and accept the **Allow USB debugging?** prompt.
4. Open the app and refresh devices.

ADB is discovered from `PATH`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or the default macOS Android SDK location. All browsing and editing happens locally between the Mac and the selected phone; the app has no telemetry or network service.

### Storage cleanup

- Overall disk usage with used space, free space, and total capacity; updates on refresh and after cleanup
- Xcode/CoreDevice incremental app-installation deltas
- Xcode DerivedData compilation products, module/compilation caches, and documentation indexes
- Recognized Android, iOS, and Godot artifacts directly under `/private/tmp`
- Cursor's inactive `state.vscdb.backup` file
- Compact the active Cursor `state.vscdb` after quitting Cursor: copy settings into a new smaller file, omit cached agent/chat blobs, then replace the original
- Codex log files, caches, shell snapshots, and model cache, with a separate opt-in category for session/archived transcripts and prompt history
- Claude Code debug logs and caches, with a separate opt-in category for session/subagent transcripts and prompt history
- Compact recognized Codex SQLite databases (`state`, `logs`, `thread_history`, `goals`, `memories`, and `queue`, with numeric version suffixes) using SQLite `VACUUM`, preserving records

The active Cursor database file itself, source repositories, simulators, Gradle caches, and Android SDK are never deleted. All cleanup categories are deselected by default. Clearing Xcode caches makes the next build or documentation lookup slower.

Compacting `state.vscdb` keeps settings and replaces the file in place. In-app chat history may show “Loading Chat…” afterward; transcripts remain under `~/.cursor/projects`. This only needs a little free space for the new copy, so a disk filled by the database can still be compacted. Scanning a multi-gigabyte file can take a long time.

Every cleanup requires confirmation and displays the exact paths that will be permanently removed.

Agent cleanup scans `~/.codex` and `~/.claude`, or absolute `CODEX_HOME` / `CLAUDE_CONFIG_DIR` overrides inherited by this app. `CODEX_SQLITE_HOME` can override the Codex database directory. Apps launched from Finder may not inherit shell environment variables. Quit the relevant agent, including terminal sessions and editor extensions, then refresh before deleting or compacting its files. The service checks again before acting.

Deleting conversation history permanently removes local transcripts and may prevent sessions from reopening or resuming; Codex may retain unavailable entries in its session list. Credentials, settings, skills, plugins, Claude project memory, and file-history backups are excluded from deletion. Symlinked agent storage is skipped. Claude JSONL transcripts are offered for deletion, not rewritten or compacted; see [Claude Code transcript storage](https://code.claude.com/docs/en/sessions#where-transcripts-are-stored).

Codex database compaction preserves records and only reclaims unused pages, so savings may be zero. SQLite manages its own locks and journal files; the app never deletes Codex database sidecars. Compaction checks for twice the database size (including the write-ahead log) in free space, with a 64 MB minimum, and validates database integrity before and after. See [SQLite VACUUM](https://www.sqlite.org/lang_vacuum.html).

### Ephemeral port usage

- Reads the configured macOS ephemeral TCP port range
- Counts occupied local ports and TIME_WAIT sockets
- Shows healthy, elevated, or critical pressure at a glance
- Offers a confirmed system restart only when usage reaches the critical 85% threshold

## Run from Xcode

Open `Package.swift` in Xcode and run the `MobileDevHelper` executable.

## Build a local app

```sh
./scripts/build-app.sh
open "dist/Mac Mobile Dev Helper.app"
```

The build script creates an ad-hoc signed, unsandboxed local app. It does not require administrator privileges.

## Test

```sh
swift test
```

Tests use isolated temporary directories and never scan or delete real developer files.

## Updates

The app checks GitHub for a newer release at startup and again at most once per day. If an update exists, a top-right button like **Update v0.1.4 -> v0.1.5** appears. Choosing it clones that tag, builds with Swift, replaces the running app bundle, and relaunches.

Use the top-right **Check for Updates** button (left of the version), or **Mac Mobile Dev Helper → Check for Updates…**, to check immediately. Updating requires network access plus Xcode Command Line Tools (`git` and `swift`).

## Release

Pushing a version tag such as `v0.1.4` runs tests and publishes GitHub Release notes. Distribution is source-only via the Terminal installer above — no downloadable app zip is attached.

```sh
git tag v0.1.4
git push origin v0.1.4
```

## License

MIT — see [LICENSE](LICENSE).

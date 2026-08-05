# Mac Mobile Dev Helper

A small native macOS utility for Android device files, mobile-development cleanup, and system diagnostics. Each feature is presented in a collapsible section.

## Features

### Android filesystem browser and editor

- Detects authorized Android devices through an installed `adb`
- Browses the selected device's shared storage
- Opens and safely edits UTF-8 and BOM-marked UTF-16 text files up to 1 MB
- Uploads, downloads, renames, creates folders, and permanently deletes with confirmation

The browser is intentionally limited to shared storage (the canonical `/sdcard` location). It does not request root access or attempt to read app-private data. Access to folders such as `Android/data` and `Android/obb` can still be restricted by the Android version or phone manufacturer.

To connect a phone:

1. Install [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools).
2. Enable Developer options and USB debugging on the phone.
3. Connect it by USB, unlock it, and accept the **Allow USB debugging?** prompt.
4. Open the app and refresh devices.

ADB is discovered from `PATH`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or the default macOS Android SDK location. All browsing and editing happens locally between the Mac and the selected phone; the app has no telemetry or network service.

### Storage cleanup

- Xcode/CoreDevice incremental app-installation deltas
- Recognized Android, iOS, and Godot artifacts directly under `/private/tmp`
- Cursor's inactive `state.vscdb.backup` file

The active Cursor database, source repositories, DerivedData, simulators, Gradle caches, and Android SDK are never deleted. Cursor backup cleanup is deselected by default.

Every cleanup requires confirmation and displays the exact paths that will be permanently removed.

### Ephemeral port usage

- Reads the configured macOS ephemeral TCP port range
- Counts occupied local ports and TIME_WAIT sockets
- Shows healthy, elevated, or critical pressure at a glance
- Offers a confirmed system restart only when usage reaches the critical 85% threshold

## Requirements

- macOS 13 or newer
- Xcode command-line tools with Swift 6
- Android SDK Platform-Tools for the Android filesystem feature

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

## Release

Pushing a version tag such as `v0.1.0` runs GitHub Actions, builds the ad-hoc signed app on macOS, and attaches a downloadable zip to a GitHub Release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release artifact is `Mac-Mobile-Dev-Helper-vX.Y.Z.zip` with a matching `.sha256` checksum. The app version in `Info.plist` comes from the tag.

### Opening a downloaded release

Release builds are ad-hoc signed and not Apple-notarized. After download, macOS may say it cannot verify the software and may move the app to Trash. Helper scripts inside the zip are quarantined too, so use Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/DawidMoza/mac-mobile-dev-helper/main/scripts/install-release.sh | bash
```

That downloads the latest release, clears quarantine, installs into `/Applications`, and launches the app.

If you already unpacked the zip:

```sh
xattr -dr com.apple.quarantine "Mac Mobile Dev Helper.app"
open "Mac Mobile Dev Helper.app"
```

Or open **System Settings → Privacy & Security → Open Anyway**.

Local builds from `./scripts/build-app.sh` are not quarantined and open normally.

## License

MIT — see [LICENSE](LICENSE).

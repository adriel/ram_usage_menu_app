# RAM Watch

A tiny macOS menu bar app that shows, at a glance, whether your Mac is running out of memory.

| Icon | Meaning |
| --- | --- |
| 🟢 Green | No swap in use and memory used is below the orange level |
| 🟠 Orange | Memory used is over the set % (default 80%), memory pressure is "Warning", or some swap is in use |
| 🔴 Red pill with swap amount | Swap used is over the set amount (default 1 GB), or memory pressure is "Critical" |

A drive icon on an orange badge means free disk space is low (default under 10 GB). macOS needs free disk space for swap.

Click the icon to see:
- **Overview:** a memory-over-time graph (15 min / 1 h / 6 h / 24 h, kept across restarts), a breakdown of App memory, Wired, Compressed, Cached files and Free memory (hover over any part to see what it is and, for App memory, which apps use the most), memory pressure, swap used against the red level and whether the Mac is swapping right now, and free disk space
- **Apps:** the apps using the most memory, with each app's helper processes counted under it (so every browser tab process counts toward the browser). Hover over an app to quit it.
- **Tabs:** open tabs in Safari, Chrome, Brave or Edge, with a ⊗ button to close each one. Safari tabs are sorted by how much memory each uses. Chromium browsers don't reveal which process belongs to which tab, so their tabs are listed in order with the total for all of them. The first time, macOS asks whether RAM Watch may control the browser; click **OK**.

Open **Settings…** from the dropdown to change the red and orange levels, turn notifications on or off, set the app to open at login, and control updates.

## Build

Requires macOS 27 or later on Apple Silicon, with Xcode or the Command Line Tools (Swift 6.2+) installed.

```bash
./build.sh            # builds build/RAM Watch.app and build/RAM-Watch.zip (Apple Silicon, macOS 27+)
./build.sh --install  # also copies it to /Applications and launches it
```

To check the numbers without opening the menu:

```bash
"build/RAM Watch.app/Contents/MacOS/RAMWatch" --dump
```

```bash
"build/RAM Watch.app/Contents/MacOS/RAMWatch" --tabs chrome   # safari, chrome, brave or edge
```

The app icon is a Liquid Glass icon in Icon Composer format (`Resources/AppIcon.icon`); `build.sh` compiles it with `actool`.

## How tab memory works

Safari's AppleScript dictionary has a hidden `pid` property on each tab: the WebContent process that renders it. RAM Watch reads each tab's title, URL and `pid` (through `osascript`, so a busy Safari can't freeze the menu), then measures that process's memory footprint, the same number Activity Monitor shows. Tabs on the same site sometimes share one process. When they do, the app says so and counts that memory only once in the total.

Chrome, Brave and Edge have no such property, and their renderer processes don't say which tab they draw. So for those browsers RAM Watch adds up all of their tab processes (leaving out extensions and the browser's own UI) and shows that as the total. Chrome's own **Window → Task Manager** shows per-tab memory.

Note: with an ad-hoc signed build, macOS ties the Automation permission to that exact build. After you rebuild or update, macOS may ask again.

## Updates

RAM Watch checks this repo's [latest release](https://github.com/adriel/ram_usage_menu_app/releases/latest) once a day. When there's a newer version, it downloads `RAM-Watch.zip` and checks it: the SHA-256 digest GitHub reports, the bundle id, the version number and the code signature. Then it swaps itself for the new copy and restarts, never while its menu is open. You can turn off automatic installing (or checking) in Settings, or click **Check Now**.

To publish an update:

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Commit and push.
3. Run `./release.sh "What changed"`. It builds the app and creates a GitHub release `vX.Y.Z` with `RAM-Watch.zip` attached.

## Installing on another Mac

The app is signed ad hoc, not with a paid Apple Developer ID, so macOS will block it on first launch:

1. Unzip `RAM-Watch.zip` and drag **RAM Watch** into Applications.
2. Double-click it. When macOS says it can't verify the app, click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to RAM Watch.
4. In RAM Watch's **Settings…**, turn on **Open RAM Watch at login**.

You only do this once: later updates install automatically, without the Gatekeeper prompt.

## About swap

macOS often leaves old data in swap long after memory has freed up, so a Mac can show swap in use and still be running fine. If the icon stays red when nothing feels slow, turn on **Only when memory pressure is high or the Mac is actively swapping**.

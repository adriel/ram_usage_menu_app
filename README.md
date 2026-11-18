# RAM Watch

A tiny macOS menu bar app that shows, at a glance, whether your Mac is running out of memory.

| Icon | Meaning |
| --- | --- |
| 🟢 Green | No swap in use and memory used is below the orange level |
| 🟠 Orange | Memory used is over the set % (default 80%), memory pressure is "Warning", or some swap is in use |
| 🔴 Red pill with swap amount (flashing) | Swap used is over the set amount (default 1 GB), or memory pressure is "Critical" |

A drive icon on an orange badge means free disk space is low (default under 10 GB). macOS needs free disk space for swap.

Click the icon to see:
- **Overview:** a memory-over-time graph (15 min / 1 h / 6 h / 24 h, kept across restarts), a breakdown of App memory, Wired, Compressed, Cached files and Free memory, memory pressure, swap used and whether the Mac is swapping right now, and free disk space
- **Apps:** the apps using the most memory, with each app's helper processes counted under it (so every browser tab process counts toward the browser). Hover over an app to quit it.
- **Safari Tabs:** every open Safari tab sorted by how much memory it uses, with a ⊗ button to close it. The first time, macOS asks whether RAM Watch may control Safari; click **OK**.

Open **Settings…** from the dropdown to change the red and orange levels, turn the flash or notification on or off, and set the app to open at login.

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
"build/RAM Watch.app/Contents/MacOS/RAMWatch" --tabs
```

## How Safari tab memory works

Safari's AppleScript dictionary has a hidden `pid` property on each tab: the WebContent process that renders it. RAM Watch reads each tab's title, URL and `pid` (through `osascript`, so a busy Safari can't freeze the menu), then measures that process's memory footprint, the same number Activity Monitor shows. Tabs on the same site sometimes share one process. When they do, the app says so and counts that memory only once in the total.

Note: with an ad-hoc signed build, macOS ties the Automation permission to that exact build. After you rebuild, macOS may ask again.

## Installing on another Mac

The app is signed ad hoc, not with a paid Apple Developer ID, so macOS will block it on first launch:

1. Unzip `RAM-Watch.zip` and drag **RAM Watch** into Applications.
2. Double-click it. When macOS says it can't verify the app, click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to RAM Watch.
4. In RAM Watch's **Settings…**, turn on **Open RAM Watch at login**.

## About swap

macOS often leaves old data in swap long after memory has freed up, so a Mac can show swap in use and still be running fine. If the icon stays red when nothing feels slow, turn on **Only when memory pressure is high or the Mac is actively swapping**.

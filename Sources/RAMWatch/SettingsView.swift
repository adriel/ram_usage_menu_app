import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let updater: Updater
    @AppStorage(Pref.autoCheckUpdates) private var autoCheckUpdates = true
    @AppStorage(Pref.autoInstallUpdates) private var autoInstallUpdates = true
    @AppStorage(Pref.warningEnabled) private var warningEnabled = true
    @AppStorage(Pref.swapWarningMB) private var swapWarningMB = 1024
    @AppStorage(Pref.requirePressure) private var requirePressure = false
    @AppStorage(Pref.orangeUsedPercent) private var orangeUsedPercent = 80
    @AppStorage(Pref.orangeOnAnySwap) private var orangeOnAnySwap = true
    @AppStorage(Pref.diskWarningEnabled) private var diskWarningEnabled = true
    @AppStorage(Pref.diskWarningGB) private var diskWarningGB = 10
    @AppStorage(Pref.showText) private var showText = true
    @AppStorage(Pref.refreshSeconds) private var refreshSeconds = 2.0

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var swapLabel: String {
        swapWarningMB == 0 ? "any swap at all" : formatBytes(UInt64(swapWarningMB) * 1_048_576)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Turn red when swap used is over **\(swapLabel)**")
                    Slider(
                        value: Binding(get: { Double(swapWarningMB) }, set: { swapWarningMB = Int(($0 / 256).rounded()) * 256 }),
                        in: 0...8192
                    ) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("0").font(.caption)
                    } maximumValueLabel: {
                        Text("8 GB").font(.caption)
                    }
                }
                Toggle("Only when memory pressure is high or the Mac is actively swapping", isOn: $requirePressure)
                    .help("macOS often leaves old data sitting in swap even after memory frees up. Turn this on to ignore that idle swap and only warn when it's actually slowing the Mac down.")
            } header: {
                Text("Red: swap")
            }

            Section {
                Toggle("Show a notification when it turns red", isOn: $warningEnabled)
            } header: {
                Text("Warning")
            } footer: {
                Text("Sent when it first turns red, then at most every 30 minutes while it stays red.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Turn orange when memory used reaches **\(orangeUsedPercent)%**")
                    Slider(
                        value: Binding(get: { Double(orangeUsedPercent) }, set: { orangeUsedPercent = Int($0.rounded()) }),
                        in: 50...98
                    )
                }
                Toggle("Also turn orange when any swap is in use", isOn: $orangeOnAnySwap)
            } header: {
                Text("Orange: getting full")
            } footer: {
                Text("Green means no swap and memory used below the orange level. Memory pressure “Warning” also turns it orange.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Warn when disk space is low (orange icon and a notification)", isOn: $diskWarningEnabled)
                VStack(alignment: .leading) {
                    Text("Turn orange when free space is below **\(diskWarningGB) GB**")
                    Slider(
                        value: Binding(get: { Double(diskWarningGB) }, set: { diskWarningGB = Int($0.rounded()) }),
                        in: 2...50
                    )
                }
                .disabled(!diskWarningEnabled)
            } header: {
                Text("Disk space")
            } footer: {
                Text("macOS needs free disk space to use as swap. When the disk is nearly full, a Mac that's low on memory gets much slower. Shows a drive icon in the menu bar and sends a notification (at most every 6 hours).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show memory % next to the icon (swap amount when red)", isOn: $showText)
                Picker("Update every", selection: $refreshSeconds) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
            }

            Section {
                Toggle("Open RAM Watch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Check for updates every day", isOn: $autoCheckUpdates)
                Toggle("Install updates automatically", isOn: $autoInstallUpdates)
                    .disabled(!autoCheckUpdates)
                HStack {
                    updateStatus.font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    switch updater.state {
                    case .available(let release):
                        Button("Install \(release.version)") { Task { await updater.install(release) } }
                    case .checking, .installing:
                        ProgressView().controlSize(.small)
                    default:
                        Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates come from the RAM Watch releases on GitHub. Installing one restarts RAM Watch, never while its menu is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 680)   // the form scrolls; fits a 13" laptop screen
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .checking: Text("Checking…")
        case .installing: Text("Installing the update…")
        case .upToDate: Text("RAM Watch \(updater.currentVersion) is the latest version.")
        case .available(let r): Text("Version \(r.version) is available (you have \(updater.currentVersion)).")
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .idle: Text("Version \(updater.currentVersion)")
        }
    }
}

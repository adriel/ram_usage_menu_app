import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.warningEnabled) private var warningEnabled = true
    @AppStorage(Pref.flashIcon) private var flashIcon = true
    @AppStorage(Pref.notify) private var notify = true
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
                Toggle("Warn me when it goes red", isOn: $warningEnabled)
                Toggle("Flash the menu bar icon", isOn: $flashIcon)
                    .disabled(!warningEnabled)
                Toggle("Show a notification", isOn: $notify)
                    .disabled(!warningEnabled)
            } header: {
                Text("Warning")
            } footer: {
                Text("Flashing stops when you click the icon, and starts again after 15 minutes if it's still red. Memory notifications are sent at most every 30 minutes.")
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
                Toggle("Warn when disk space is low", isOn: $diskWarningEnabled)
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

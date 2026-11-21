import Foundation

/// UserDefaults keys + defaults. Views bind with @AppStorage using these keys.
enum Pref {
    static let warningEnabled = "warningEnabled"
    static let swapWarningMB = "swapWarningMB"
    static let requirePressure = "requirePressure"
    static let orangeUsedPercent = "orangeUsedPercent"
    static let orangeOnAnySwap = "orangeOnAnySwap"
    static let diskWarningEnabled = "diskWarningEnabled"
    static let diskWarningGB = "diskWarningGB"
    static let showText = "showText"
    static let refreshSeconds = "refreshSeconds"
    static let popoverSection = "popoverSection"
    static let tabsBrowser = "tabsBrowser"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let autoInstallUpdates = "autoInstallUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let spotifyCleanEnabled = "spotifyCleanEnabled"
    static let spotifyCleanDays = "spotifyCleanDays"
    static let spotifyLastCleaned = "spotifyLastCleaned"

    static func register() {
        UserDefaults.standard.register(defaults: [
            warningEnabled: true,
            swapWarningMB: 1024,
            requirePressure: false,
            orangeUsedPercent: 80,
            orangeOnAnySwap: true,
            diskWarningEnabled: true,
            diskWarningGB: 30,
            showText: true,
            refreshSeconds: 2.0,
            autoCheckUpdates: true,
            autoInstallUpdates: true,
            spotifyCleanEnabled: false,
            spotifyCleanDays: 7,
        ])
    }
}

import Foundation

/// UserDefaults keys + defaults. Views bind with @AppStorage using these keys.
enum Pref {
    static let warningEnabled = "warningEnabled"
    static let flashIcon = "flashIcon"
    static let notify = "notify"
    static let swapWarningMB = "swapWarningMB"
    static let requirePressure = "requirePressure"
    static let orangeUsedPercent = "orangeUsedPercent"
    static let orangeOnAnySwap = "orangeOnAnySwap"
    static let diskWarningEnabled = "diskWarningEnabled"
    static let diskWarningGB = "diskWarningGB"
    static let showText = "showText"
    static let refreshSeconds = "refreshSeconds"
    static let popoverSection = "popoverSection"

    static func register() {
        UserDefaults.standard.register(defaults: [
            warningEnabled: true,
            flashIcon: true,
            notify: true,
            swapWarningMB: 1024,
            requirePressure: false,
            orangeUsedPercent: 80,
            orangeOnAnySwap: true,
            diskWarningEnabled: true,
            diskWarningGB: 10,
            showText: true,
            refreshSeconds: 2.0,
        ])
    }
}

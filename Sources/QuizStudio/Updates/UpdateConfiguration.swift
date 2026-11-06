import Foundation

enum AppVersion {
    /// Version shown in the window title; the bundle stays the single source of truth.
    static var display: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}

/// Bundle-level Sparkle settings. Kept separate from Sparkle itself so the
/// configuration can be checked without launching the updater.
struct UpdateConfiguration: Equatable {
    static let placeholderPublicKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"
    static let defaultScheduledCheckInterval: TimeInterval = 86_400

    let feedURL: URL?
    let publicKey: String
    let automaticChecksEnabled: Bool
    let scheduledCheckInterval: TimeInterval

    init(info: [String: Any]) {
        feedURL = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        publicKey = (info["SUPublicEDKey"] as? String) ?? ""
        automaticChecksEnabled = (info["SUEnableAutomaticChecks"] as? Bool) ?? false
        scheduledCheckInterval = (info["SUScheduledCheckInterval"] as? NSNumber)?.doubleValue ?? Self.defaultScheduledCheckInterval
    }

    static func load(bundle: Bundle = .main) -> UpdateConfiguration {
        UpdateConfiguration(info: bundle.infoDictionary ?? [:])
    }

    var isValidPublicKey: Bool {
        guard publicKey != Self.placeholderPublicKey, let data = Data(base64Encoded: publicKey) else { return false }
        return data.count == 32
    }

    /// Human-readable reasons the updater must stay off. Never shown as a
    /// dialog: a broken feed is not the user's problem to fix.
    var problems: [String] {
        var problems: [String] = []
        if feedURL?.scheme != "https" {
            problems.append("SUFeedURL must be a permanent HTTPS address.")
        }
        if !isValidPublicKey {
            problems.append("SUPublicEDKey is missing or is not an EdDSA public key.")
        }
        if !automaticChecksEnabled {
            problems.append("SUEnableAutomaticChecks is disabled, so updates are not checked at launch.")
        }
        return problems
    }

    var isUsable: Bool {
        feedURL?.scheme == "https" && isValidPublicKey
    }
}

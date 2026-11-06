import Foundation

@main struct UpdateChecks {
    static func goodInfo() -> [String: Any] {
        [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": true,
            "SUScheduledCheckInterval": 86_400,
        ]
    }

    static func main() {
        let good = UpdateConfiguration(info: goodInfo())
        assert(good.isUsable && good.problems.isEmpty)
        assert(good.scheduledCheckInterval == 86_400 && good.automaticChecksEnabled)
        assert(good.feedURL?.absoluteString == "https://example.com/appcast.xml")

        var http = goodInfo()
        http["SUFeedURL"] = "http://example.com/appcast.xml"
        assert(!UpdateConfiguration(info: http).isUsable)

        var shortKey = goodInfo()
        shortKey["SUPublicEDKey"] = Data(repeating: 1, count: 16).base64EncodedString()
        assert(!UpdateConfiguration(info: shortKey).isUsable)

        var missingKey = goodInfo()
        missingKey.removeValue(forKey: "SUPublicEDKey")
        assert(!UpdateConfiguration(info: missingKey).isUsable)

        var placeholder = goodInfo()
        placeholder["SUPublicEDKey"] = UpdateConfiguration.placeholderPublicKey
        assert(!UpdateConfiguration(info: placeholder).isUsable)

        var noAuto = goodInfo()
        noAuto["SUEnableAutomaticChecks"] = false
        assert(UpdateConfiguration(info: noAuto).problems.count == 1)

        let empty = UpdateConfiguration(info: [:])
        assert(empty.scheduledCheckInterval == UpdateConfiguration.defaultScheduledCheckInterval)
        assert(!empty.isUsable)

        print("PASS: updater configuration rejects http feeds, malformed keys and placeholders")
    }
}

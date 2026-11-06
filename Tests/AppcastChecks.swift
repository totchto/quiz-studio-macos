import Foundation
import CryptoKit

/// Verifies that the appcast enclosure is signed by the same EdDSA key that
/// the application embeds, without needing the private key.
@main struct AppcastChecks {
    static func elements(_ node: XMLNode, named name: String, into result: inout [XMLElement]) {
        guard let element = node as? XMLElement else { return }
        if element.name == name { result.append(element) }
        for child in element.children ?? [] {
            elements(child, named: name, into: &result)
        }
    }

    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        for attribute in element.attributes ?? [] {
            guard let attributeName = attribute.name else { continue }
            if attributeName == name || attributeName.hasSuffix(":" + name) {
                return attribute.stringValue
            }
        }
        return nil
    }

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: AppcastChecks <appcast.xml> <archive> <public-key>\n".utf8))
            exit(2)
        }
        let appcastURL = URL(fileURLWithPath: arguments[1])
        let archiveURL = URL(fileURLWithPath: arguments[2])
        guard let document = try? XMLDocument(contentsOf: appcastURL, options: []), let root = document.rootElement() else {
            print("FAIL: cannot read \(appcastURL.path)")
            exit(1)
        }
        var enclosures: [XMLElement] = []
        elements(root, named: "enclosure", into: &enclosures)
        guard let enclosure = enclosures.first(where: { URL(string: attribute($0, "url") ?? "")?.lastPathComponent == archiveURL.lastPathComponent }),
              let signatureText = attribute(enclosure, "edSignature"),
              let signature = Data(base64Encoded: signatureText),
              let publicKeyData = Data(base64Encoded: arguments[3]),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              let data = try? Data(contentsOf: archiveURL) else {
            print("FAIL: appcast has no usable signature for \(archiveURL.lastPathComponent)")
            exit(1)
        }
        guard key.isValidSignature(signature, for: data) else {
            print("FAIL: appcast signature does not match SUPublicEDKey")
            exit(1)
        }
        print("PASS: appcast signature matches SUPublicEDKey")
    }
}

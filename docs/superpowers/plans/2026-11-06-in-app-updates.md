# In-App Updates (Sparkle) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Sparkle-based updater so Quiz Studio checks for, presents, and installs signed updates from a permanent HTTPS appcast.

**Architecture:** Sparkle 2.10.1 is added as a SwiftPM binary dependency. A small `Updates/` subsystem reads and validates the Sparkle keys from `Info.plist`, owns one `SPUStandardUpdaterController`, and exposes a menu command. `build.py` embeds `Sparkle.framework`, adds the app rpath, signs nested code explicitly, optionally notarizes, and produces both the legacy ZIP and a Sparkle-signed appcast from a versioned ZIP.

**Tech Stack:** Swift 6.0 tools / language mode 5, SwiftUI + AppKit, Sparkle 2.10.1, Python 3 build and check scripts.

**Spec:** `docs/superpowers/specs/2026-11-06-in-app-updates-design.md`

## Global Constraints

- Keep `CFBundleIdentifier` = `local.quizstudio.mac`, `LSMinimumSystemVersion` = `14.0`, Apple Silicon only; keep the `.quiz` format, user data, and game behavior untouched.
- Keep `CFBundleShortVersionString` / `CFBundleVersion` present and make `CFBundleVersion` monotonically increase (current 29 → 30 for 0.21.0).
- Sparkle must never install silently: `SUAllowsAutomaticUpdates` = `false`, `SUAutomaticallyUpdate` = `false`.
- The feed URL is a permanent HTTPS URL; the default is `https://github.com/totchto/quiz-studio-macos/releases/latest/download/appcast.xml`.
- Only the public EdDSA key is embedded. The private key never enters the repository, `dist/`, or release artifacts.
- `python3 build.py` on a machine without a Developer ID identity must still produce a working ad-hoc app and ZIP (current behavior).
- Nested code (`Autoupdate`, `Updater.app`, XPC services, `Sparkle.framework`, `yt-dlp`, `deno`) is signed before the app; never rely on `codesign --deep` for Developer ID.
- Do not add entitlements unless a concrete runtime need is demonstrated.
- The legacy public download `QuizStudio-macOS.zip` must keep its name and location.

## Review Focus

- Updater configured but unusable (http feed, empty or malformed key, key not generated): the app must launch, stay silent, and never offer a broken update. Unit test in `Tests/UpdateChecks.swift` and a build-time validation.
- Feed unreachable or offline: Sparkle must not block launch and must not repeat dialogs. Verification step: launch the ad-hoc build with networking blocked and confirm the window opens.
- Update archive with a valid EdDSA signature but a code signature not matching the installed app: must be rejected. Verification is manual and requires Developer ID (documented, cannot run here).
- App bundle after embedding: `Sparkle.framework` present, `LC_RPATH` contains `@executable_path/../Frameworks`, `codesign --verify --deep --strict` passes. Automated by `Tests/check_updates.py` against `dist/`.
- Old 0.20.0 users have no updater: a one-time manual download instruction must be present in README and release notes, with no user data touched.

---

### Task 1: Updatable configuration model and its check

**Files:**
- Create: `Sources/QuizStudio/Updates/UpdateConfiguration.swift`
- Create: `Tests/UpdateChecks.swift`
- Create: `Tests/check_updates.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct UpdateConfiguration` with `init(info: [String: Any])`, `static func load(bundle: Bundle = .main) -> UpdateConfiguration`, `let feedURL: URL?`, `let publicKey: String`, `let automaticChecksEnabled: Bool`, `let scheduledCheckInterval: TimeInterval`, `var isValidPublicKey: Bool`, `var isUsable: Bool`, `var problems: [String]`.

- [x] **Step 1: Write the failing check**

`Tests/UpdateChecks.swift` (merged with `UpdateConfiguration.swift` only; no Sparkle import):

```swift
import Foundation
@main struct UpdateChecks {
    static func goodInfo() -> [String: Any] { [
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
        "SUEnableAutomaticChecks": true,
        "SUScheduledCheckInterval": 86400,
    ] }
    static func main() {
        let good = UpdateConfiguration(info: goodInfo())
        assert(good.isUsable && good.problems.isEmpty)
        assert(good.scheduledCheckInterval == 86400 && good.automaticChecksEnabled)
        var http = goodInfo(); http["SUFeedURL"] = "http://example.com/appcast.xml"
        assert(!UpdateConfiguration(info: http).isUsable)
        var shortKey = goodInfo(); shortKey["SUPublicEDKey"] = Data(repeating: 1, count: 16).base64EncodedString()
        assert(!UpdateConfiguration(info: shortKey).isUsable)
        var missing = goodInfo(); missing.removeValue(forKey: "SUPublicEDKey")
        assert(!UpdateConfiguration(info: missing).isUsable)
        var placeholder = goodInfo(); placeholder["SUPublicEDKey"] = UpdateConfiguration.placeholderPublicKey
        assert(!UpdateConfiguration(info: placeholder).isUsable)
        assert(UpdateConfiguration(info: [:]).scheduledCheckInterval == 86400)
        print("PASS: updater configuration rejects http feeds, malformed keys and placeholders")
    }
}
```

`Tests/check_updates.py` compiles `Sources/QuizStudio/Updates/UpdateConfiguration.swift` + `Tests/UpdateChecks.swift`, runs it, then asserts on `Resources/Info.plist` and `Package.swift`:

```python
# plist: SUFeedURL == default https feed, SUPublicEDKey decodes to 32 bytes and is not the placeholder,
# SUEnableAutomaticChecks is true, SUScheduledCheckInterval == 86400,
# SUAllowsAutomaticUpdates is false, CFBundleIdentifier == local.quizstudio.mac,
# int(CFBundleVersion) >= 30, LSMinimumSystemVersion == 14.0
# Package.swift: contains 'sparkle-project/Sparkle' and 'exact: "2.10.1"'
```

- [x] **Step 2: Run it to verify it fails**

Run: `python3 Tests/check_updates.py`
Expected: FAIL — `UpdateConfiguration.swift` does not exist (swiftc error).

- [x] **Step 3: Implement `UpdateConfiguration`**

`Sources/QuizStudio/Updates/UpdateConfiguration.swift`:

```swift
import Foundation

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

    var problems: [String] { ... }   // "SUFeedURL must be HTTPS", "SUPublicEDKey is missing or invalid"
    var isUsable: Bool { feedURL?.scheme == "https" && isValidPublicKey }
}
```

- [x] **Step 4: Run the check to verify it passes**

Run: `python3 Tests/check_updates.py --config-only`
Expected: `PASS: updater configuration ...` (the full run also checks `Info.plist` and fails until Task 2).

- [x] **Step 5: Commit**

```bash
git add Sources/QuizStudio/Updates/UpdateConfiguration.swift Tests/UpdateChecks.swift Tests/check_updates.py
git commit -m "Add updater configuration model and checks"
```

### Task 2: Info.plist Sparkle settings and version bump

**Files:**
- Modify: `Resources/Info.plist`
- Test: `Tests/check_updates.py`

**Interfaces:**
- Consumes: `UpdateConfiguration` keys from Task 1.
- Produces: bundle-level keys read by Sparkle at runtime.

- [x] **Step 1: Add the keys**

```xml
<key>SUFeedURL</key>
<string>https://github.com/totchto/quiz-studio-macos/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_SPARKLE_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
<key>SUAllowsAutomaticUpdates</key>
<false/>
<key>SUAutomaticallyUpdate</key>
<false/>
```

Bump `CFBundleShortVersionString` to `0.21.0` and `CFBundleVersion` to `30`.

- [x] **Step 2: Run the check**

Run: `python3 Tests/check_updates.py`
Expected: PASS for the feed URL, versions, and flags; the public-key assertion still fails on the placeholder until Task 6.

- [x] **Step 3: Commit**

```bash
git add Resources/Info.plist
git commit -m "Configure Sparkle feed and automatic check policy"
```

### Task 3: Updater controller and menu command

**Files:**
- Create: `Sources/QuizStudio/Updates/AppUpdater.swift` (imports Sparkle; the `Updates/` subdirectory keeps it out of the Swift test harnesses, which glob `Sources/QuizStudio/*.swift` non-recursively)
- Modify: `Sources/QuizStudio/main.swift` (`QuizStudioApp` only)

**Interfaces:**
- Consumes: `UpdateConfiguration.load()`.
- Produces: `@MainActor final class AppUpdater` with `func start()`, `func checkForUpdates()`, `var isConfigured: Bool`.

- [x] **Step 1: Implement the controller**

```swift
import Sparkle

@MainActor final class AppUpdater: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    func start() {
        guard controller == nil, UpdateConfiguration.load().isUsable else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }
}
```

`startingUpdater: true` lets Sparkle run its scheduled (≈daily) check; user-driver defaults present version, release notes, install/later, and never install without consent.

- [x] **Step 2: Wire it into `QuizStudioApp`**

Add `@StateObject private var appUpdater = AppUpdater()` and `appUpdater.start()` inside the existing `onAppear`. Add to `.commands`, before `.newItem`:

```swift
CommandGroup(after: .appInfo) {
    Button("Проверить обновления…") { appUpdater.checkForUpdates() }
        .disabled(!appUpdater.isConfigured)
}
```

Replace the hard-coded window version with `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"`.

- [x] **Step 3: Verify it compiles and does not disturb harnesses**

Run: `swift build -c release` → Build complete.
Run: `python3 Tests/run.py` → PASS (proves the Sparkle file stayed out of the merged harness).

- [x] **Step 4: Commit**

```bash
git add Sources/QuizStudio/Updates/AppUpdater.swift Sources/QuizStudio/main.swift
git commit -m "Add Sparkle updater and Check for Updates command"
```

### Task 4: Package dependency

**Files:**
- Modify: `Package.swift`
- Add: `Package.resolved`

**Interfaces:**
- Consumes: nothing.
- Produces: `Sparkle` product linked into the executable target.

- [x] **Step 1: Add the pinned dependency**

```swift
dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
targets: [.executableTarget(name: "QuizStudio", dependencies: [.product(name: "Sparkle", package: "Sparkle")]), ...]
```

`dependencies:` must precede `targets:` in the positional `Package(...)` call.

- [x] **Step 2: Resolve and build**

Run: `swift package resolve && swift build -c release`
Expected: Sparkle artifact downloaded, build complete.

- [x] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "Depend on Sparkle 2.10.1"
```

### Task 5: Embed, sign, notarize, and package in build.py

**Files:**
- Modify: `build.py:1-50`

**Interfaces:**
- Consumes: `swift build --show-bin-path` output containing `Sparkle.framework`; `Info.plist` version fields; env `QUIZSTUDIO_SIGN_IDENTITY` (default `-`), `QUIZSTUDIO_NOTARY_PROFILE` (optional).
- Produces: `dist/Квиз Студия.app`, `dist/QuizStudio-macOS.zip`, `dist/sparkle/QuizStudio-<version>.zip` and `.md`.

- [x] **Step 1: Embed the framework and rpath**

Copy `Sparkle.framework` into `Contents/Frameworks` with `symlinks=True`; run `install_name_tool -add_rpath @executable_path/../Frameworks Contents/MacOS/QuizStudio` only if absent.

- [x] **Step 2: Sign bottom-up**

Sign `Versions/B/XPCServices/*.xpc`, `Versions/B/Autoupdate`, `Versions/B/Updater.app`, `Sparkle.framework`, `Contents/Resources/ImportTools/{yt-dlp,deno}`, then the app. Developer ID adds `--options runtime --timestamp`; the default ad-hoc identity `-` must not pass `--timestamp`. Finish with `codesign --verify --deep --strict`.

- [x] **Step 3: Validate the updater configuration**

Read `Contents/Info.plist`; fail the build with a clear message if `SUFeedURL` is not HTTPS or `SUPublicEDKey` is the placeholder / not 32 base64 bytes. Warn (not fail) when the identity is ad-hoc: updates will be rejected by Sparkle until Developer ID signing is used.

- [x] **Step 4: Package**

Keep `dist/QuizStudio-macOS.zip` (`ditto -c -k --sequesterRsrc --keepParent`). Copy it to `dist/sparkle/QuizStudio-<version>.zip`; when `Releases/<version>.md` exists, copy it as `QuizStudio-<version>.md` so `generate_appcast` embeds release notes. If `QUIZSTUDIO_NOTARY_PROFILE` is set, submit the ZIP with `notarytool --wait`, `stapler staple` the app, then recreate both ZIPs.

- [x] **Step 5: Verify**

Run: `python3 build.py`
Expected: app and legacy ZIP built; `codesign --verify --deep --strict` passes; framework present; rpath present.

- [x] **Step 6: Commit**

```bash
git add build.py
git commit -m "Embed, sign and package Sparkle in build.py"
```

### Task 6: Key setup and appcast release tooling

**Files:**
- Create: `scripts/make_appcast.py`
- Create: `docs/superpowers/notes/sparkle-keys.md`
- Modify: `Resources/Info.plist` (real public key)

**Interfaces:**
- Consumes: `dist/sparkle/`, `Releases/<version>.md`, the Sparkle tools under `.build/artifacts/sparkle/Sparkle/bin`.
- Produces: `dist/sparkle/appcast.xml` ready to upload with `QuizStudio-<version>.zip`.

- [x] **Step 1: Document key creation (one-time, outside the repo)**

`generate_keys` stores the private key in the login Keychain; `generate_keys -x <path>` exports a backup. Record the public key, delete the exported file after storing it in the approved secret store, and never commit it. No key generation happens in an automated step.

- [x] **Step 2: Implement `scripts/make_appcast.py`**

Arguments: `--version`, `--notes` (default `Releases/<version>.md`), `--key-file` (or Keychain), `--feed-url`, `--download-prefix` (default `https://github.com/totchto/quiz-studio-macos/releases/download/v<version>/`), `--previous` (optional URL or file; downloaded into the archives dir to preserve history). Runs `generate_appcast --download-url-prefix ... -o dist/sparkle/appcast.xml dist/sparkle` and `sign_update --verify`.

- [x] **Step 3: Generate the real key (requires approval) and set `SUPublicEDKey`**

Replace the placeholder with the public key, then run `python3 Tests/check_updates.py` → PASS.

- [x] **Step 4: Commit**

```bash
git add scripts/make_appcast.py docs/superpowers/notes/sparkle-keys.md Resources/Info.plist
git commit -m "Add Sparkle key setup and appcast release tooling"
```

### Task 7: Documentation and release notes

**Files:**
- Modify: `README.md`
- Modify: `PROJECT_CONTEXT.md`
- Create: `Releases/v0.21.0.md`

- [x] **Step 1: README**

Add an "Обновления приложения" section: automatic check once a day, «Проверить обновления…» in the app menu, Developer ID + notarization requirement, release publishing steps (build → notarize → zip → appcast → upload ZIP + appcast), and the one-time manual replacement for existing 0.20.0 users with the release link.

- [x] **Step 2: PROJECT_CONTEXT**

Update the version line to 0.21.0, add the `Sources/QuizStudio/Updates/` row to the code map, and state that automatic updates are implemented but still require Developer ID signing and notarization before a release.

- [x] **Step 3: Release notes draft**

`Releases/v0.21.0.md`: what changed, the one-time manual install for 0.20.0 users, signing/notarization status, and the privacy note that the check sends only the standard Sparkle request.

- [x] **Step 4: Commit**

```bash
git add README.md PROJECT_CONTEXT.md Releases/v0.21.0.md
git commit -m "Document in-app update setup and 0.21.0 release"
```

### Task 8: Full verification

- [x] `swift build -c release`
- [x] `python3 Tests/check_updates.py`
- [x] `python3 Tests/run.py`
- [x] `python3 Tests/check_editor.py`
- [x] `python3 build.py` and `codesign --verify --deep --strict "dist/Квиз Студия.app"`
- [x] Inspect `dist/Квиз Студия.app/Contents/Frameworks/Sparkle.framework` and `otool -l` rpath
- [x] Launch the ad-hoc app with the network off; the window opens and no update dialog is shown
- [ ] Report which acceptance items remain blocked on a Developer ID certificate and a published appcast

## Verification That Requires the Release Environment

These cannot be executed on this machine (no code-signing identity installed) and must be reported as pending, never as passed:

- Developer ID signing and `notarytool`/Gatekeeper acceptance.
- A real 0.20.0 → 0.21.0 manual migration and 0.21.0 → next update install.
- EdDSA-signed archive acceptance and rejection of a tampered archive.
- macOS/hardware branch filtering from a live appcast.

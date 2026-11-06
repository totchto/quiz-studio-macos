"""Check updater configuration, Info.plist Sparkle keys and the Sparkle pin."""
from pathlib import Path
import base64
import plistlib
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
config_only = '--config-only' in sys.argv
feed = 'https://github.com/totchto/quiz-studio-macos/releases/latest/download/appcast.xml'

with tempfile.TemporaryDirectory(prefix='quiz-updates-') as folder:
    folder = Path(folder)
    binary = folder / 'checks'
    subprocess.run([
        'swiftc', '-module-cache-path', str(folder / 'cache'),
        str(root / 'Sources/QuizStudio/Updates/UpdateConfiguration.swift'),
        str(root / 'Tests/UpdateChecks.swift'),
        '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)

if config_only:
    raise SystemExit(0)

info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'local.quizstudio.mac', info['CFBundleIdentifier']
assert info['CFBundleShortVersionString'], 'missing CFBundleShortVersionString'
assert int(info['CFBundleVersion']) >= 30, info['CFBundleVersion']
assert info['LSMinimumSystemVersion'] == '14.0', info['LSMinimumSystemVersion']
assert info['SUFeedURL'] == feed, info['SUFeedURL']
assert info['SUFeedURL'].startswith('https://'), 'feed must be HTTPS'
key = info['SUPublicEDKey']
assert key != 'REPLACE_WITH_SPARKLE_PUBLIC_KEY', 'generate the Sparkle key and embed the public part'
assert len(base64.b64decode(key)) == 32, 'SUPublicEDKey must be a 32-byte EdDSA public key'
assert info['SUEnableAutomaticChecks'] is True
assert info['SUScheduledCheckInterval'] == 86_400, info['SUScheduledCheckInterval']
assert info['SUAllowsAutomaticUpdates'] is False
assert info['SUAutomaticallyUpdate'] is False

package = (root / 'Package.swift').read_text()
assert 'sparkle-project/Sparkle' in package, 'Sparkle dependency missing'
assert 'exact: "2.10.1"' in package, 'pin Sparkle to 2.10.1'

for helper, keys in (
    ('deno', ['com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory']),
    ('yt-dlp', ['com.apple.security.cs.disable-library-validation', 'com.apple.security.cs.allow-unsigned-executable-memory']),
):
    path = root / 'Resources/Entitlements' / f'{helper}.entitlements'
    assert path.exists(), f'missing hardened-runtime entitlements for {helper}'
    entitlements = plistlib.loads(path.read_bytes())
    for key in keys:
        assert entitlements.get(key) is True, f'{path.name} must grant {key}'

# These run only after python3 build.py; they prove the shipped bundle is updatable.
app = root / 'dist' / 'Квиз Студия.app'
if app.exists():
    assert (app / 'Contents/Frameworks/Sparkle.framework').is_dir(), 'Sparkle.framework not embedded'
    load_commands = subprocess.check_output(['otool', '-l', str(app / 'Contents/MacOS/QuizStudio')], text=True)
    assert '@executable_path/../Frameworks' in load_commands, 'missing app rpath for Sparkle'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    bundled = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert bundled['SUFeedURL'] == feed
    assert len(base64.b64decode(bundled['SUPublicEDKey'])) == 32

    appcast = root / 'dist/sparkle/appcast.xml'
    archive = next((root / 'dist/sparkle').glob('QuizStudio-*.zip'), None) if appcast.exists() else None
    if archive is not None:
        with tempfile.TemporaryDirectory(prefix='quiz-appcast-') as verifier_folder:
            verifier = Path(verifier_folder) / 'appcast-checks'
            subprocess.run([
                'swiftc', '-parse-as-library', '-module-cache-path', str(Path(verifier_folder) / 'cache'),
                str(root / 'Tests/AppcastChecks.swift'), '-o', str(verifier),
            ], check=True)
            subprocess.run([str(verifier), str(appcast), str(archive), bundled['SUPublicEDKey']], check=True)
        feed_text = appcast.read_text()
        assert '<description>' in feed_text, 'release notes must be embedded in the appcast'
        assert 'releaseNotesLink' not in feed_text, 'release notes should not depend on a hosted asset'
        assert 'sparkle:edSignature' in feed_text

print('PASS: Info.plist feed, key, version and update policy; Sparkle dependency pinned')
print('PASS: hardened-runtime entitlements exist for deno and yt-dlp')
if app.exists():
    print('PASS: built app embeds Sparkle, has the framework rpath and a valid signature')
if app.exists() and (root / 'dist/sparkle/appcast.xml').exists():
    print('PASS: appcast enclosure is signed by the embedded SUPublicEDKey')


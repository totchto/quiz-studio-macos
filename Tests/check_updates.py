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

print('PASS: Info.plist feed, key, version and update policy; Sparkle dependency pinned')

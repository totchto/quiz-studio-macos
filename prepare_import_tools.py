"""Fetch pinned official macOS import helpers into Resources/ImportTools."""
from pathlib import Path
import hashlib, io, json, urllib.request, zipfile
root = Path(__file__).resolve().parent
versions = json.loads((root / 'ImportTools.lock.json').read_text())
folder = root / 'Resources/ImportTools'
folder.mkdir(parents=True, exist_ok=True)
for name, spec in versions.items():
    target = folder / name
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == spec['binary_sha256']:
        continue
    request = urllib.request.Request(spec['source'], headers={'User-Agent': 'QuizStudio-build'})
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = response.read()
    assert hashlib.sha256(payload).hexdigest() == spec['download_sha256'], 'Download checksum mismatch'
    if spec['source'].endswith('.zip'):
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            payload = archive.read('deno')
    assert hashlib.sha256(payload).hexdigest() == spec['binary_sha256'], 'Executable checksum mismatch'
    target.write_bytes(payload)
    target.chmod(0o755)
(folder / 'versions.json').write_text(json.dumps(versions, indent=2))
for name, url in {
    'yt-dlp-LICENSE.txt': 'https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/LICENSE',
    'yt-dlp-THIRD-PARTY.txt': 'https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/THIRD_PARTY_LICENSES.txt',
    'deno-LICENSE.txt': 'https://raw.githubusercontent.com/denoland/deno/v2.9.7/LICENSE.md',
}.items():
    with urllib.request.urlopen(url, timeout=60) as response:
        (folder / name).write_bytes(response.read())
(folder / 'NOTICE.txt').write_text((root / 'Resources/YOUTUBE-CREDITS.txt').read_text())
print('Official import helpers prepared and checksums verified.')

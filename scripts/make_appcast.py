"""Generate and verify the Sparkle appcast for dist/sparkle."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
feed_url = 'https://github.com/totchto/quiz-studio-macos/releases/latest/download/appcast.xml'


def sparkle_tool(name):
    tool = root / '.build/artifacts/sparkle/Sparkle/bin' / name
    if not tool.exists():
        raise SystemExit(f'Missing {name}. Run swift package resolve and swift build first.')
    return tool


def fetch_previous(source, destination):
    if source.startswith(('https://', 'http://')):
        with urllib.request.urlopen(source, timeout=60) as response, destination.open('wb') as output:
            shutil.copyfileobj(response, output)
    else:
        shutil.copy2(source, destination)


def enclosure_signature(appcast, archive_name):
    namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    for item in ET.parse(appcast).getroot().iter('item'):
        enclosure = item.find('enclosure')
        if enclosure is None:
            continue
        if Path(enclosure.get('url', '')).name == archive_name:
            signature = enclosure.get(f'{{{namespace}}}edSignature')
            if signature:
                return signature
    raise SystemExit(f'No signed enclosure for {archive_name} in {appcast}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True, help='CFBundleShortVersionString, for example 0.21.0')
    parser.add_argument('--notes', help='release notes file (defaults to Releases/v<version>.md)')
    parser.add_argument('--key-file', help='private EdDSA key file; omit to read it from the Keychain')
    parser.add_argument('--download-prefix', help='URL prefix for new archives')
    parser.add_argument('--previous', help='previous appcast URL or file, to keep old releases in the feed')
    args = parser.parse_args()

    archives = root / 'dist/sparkle'
    archive = archives / f'QuizStudio-{args.version}.zip'
    if not archive.exists():
        raise SystemExit(f'Missing {archive}. Run python3 build.py first.')
    notes = Path(args.notes) if args.notes else root / 'Releases' / f'v{args.version}.md'
    if notes.exists():
        shutil.copy2(notes, archives / f'QuizStudio-{args.version}.md')
    if args.previous:
        fetch_previous(args.previous, archives / 'appcast.xml')

    command = [str(sparkle_tool('generate_appcast'))]
    if args.key_file:
        command += ['--ed-key-file', args.key_file]
    prefix = args.download_prefix or f'https://github.com/totchto/quiz-studio-macos/releases/download/v{args.version}/'
    command += [
        '--download-url-prefix',
        prefix,
        '--release-notes-url-prefix',
        prefix,
        '--link',
        'https://github.com/totchto/quiz-studio-macos/releases/latest',
        '-o',
        str(archives / 'appcast.xml'),
        str(archives),
    ]
    subprocess.run(command, check=True)

    signature = enclosure_signature(archives / 'appcast.xml', archive.name)
    verification_command = [str(sparkle_tool('sign_update')), '--verify']
    if args.key_file:
        verification_command += ['--ed-key-file', args.key_file]
    verification_command += [str(archive), signature]
    verification = subprocess.run(verification_command, capture_output=True, text=True)
    if verification.returncode != 0:
        raise SystemExit('Update signature verification failed:\n' + verification.stdout + verification.stderr)
    print(f'Appcast: {archives / "appcast.xml"}\nFeed URL: {feed_url}\nArchive: {archive.name}')


if __name__ == '__main__':
    main()

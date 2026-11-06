"""Generate and verify the Sparkle appcast for a signed build."""
from pathlib import Path
import argparse
import html
import plistlib
import re
import shutil
import subprocess
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

root = Path(__file__).resolve().parents[1]
feed_url = 'https://github.com/totchto/quiz-studio-macos/releases/latest/download/appcast.xml'
namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def sparkle_tool(name):
    tool = root / '.build/artifacts/sparkle/Sparkle/bin' / name
    if not tool.exists():
        raise SystemExit(f'Missing {name}. Run swift package resolve and swift build first.')
    return tool


def fetch_previous(source, destination):
    """Copy the previous feed so old entries survive. A missing feed is fine:
    the first Sparkle release has no appcast yet."""
    if source.startswith('http://'):
        raise SystemExit('The previous feed must be served over HTTPS.')
    if source.startswith('https://'):
        try:
            with urllib.request.urlopen(source, timeout=60) as response, destination.open('wb') as output:
                shutil.copyfileobj(response, output)
        except urllib.error.HTTPError as error:
            if error.code in (403, 404):
                print(f'No previous feed at {source}; starting a new one.')
                return False
            raise
        except urllib.error.URLError as error:
            print(f'Could not fetch the previous feed ({error.reason}); starting a new one.')
            return False
        return True
    shutil.copy2(source, destination)
    return True


def inline_markdown(text):
    text = html.escape(text)
    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'`(.+?)`', r'<code>\1</code>', text)
    return re.sub(r'\[(.+?)\]\((.+?)\)', r'<a href="\2">\1</a>', text)


def markdown_to_html(text):
    """Small converter for the release notes Sparkle embeds in the feed."""
    parts = []
    open_list = None

    def close_list():
        nonlocal open_list
        if open_list:
            parts.append(f'</{open_list}>')
            open_list = None

    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            close_list()
            continue
        heading = re.match(r'^(#{1,3})\s+(.*)$', line)
        if heading:
            close_list()
            level = len(heading.group(1))
            parts.append(f'<h{level}>{inline_markdown(heading.group(2))}</h{level}>')
            continue
        bullet = re.match(r'^\s*[-*]\s+(.*)$', line)
        numbered = re.match(r'^\s*\d+\.\s+(.*)$', line)
        if bullet or numbered:
            kind = 'ul' if bullet else 'ol'
            if open_list != kind:
                close_list()
                parts.append(f'<{kind}>')
                open_list = kind
            parts.append(f'<li>{inline_markdown((bullet or numbered).group(1))}</li>')
            continue
        close_list()
        parts.append(f'<p>{inline_markdown(line)}</p>')
    close_list()
    return '\n'.join(parts)


def archive_metadata(archive):
    with zipfile.ZipFile(archive) as bundle:
        for name in bundle.namelist():
            # Top-level app only: Sparkle's helpers are nested .app bundles too.
            if name.endswith('.app/Contents/Info.plist') and name.count('/') == 2:
                info = plistlib.loads(bundle.read(name))
                return info['CFBundleShortVersionString'], str(info['CFBundleVersion'])
    raise SystemExit(f'No application Info.plist in {archive}')


def signature_kind(app):
    result = subprocess.run(['codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True)
    return 'adhoc' if 'Signature=adhoc' in result.stderr else 'developer-id'


def enclosure_signature(appcast, archive_name):
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
    parser.add_argument('--archive', help='signed ZIP (defaults to dist/QuizStudio-macOS.zip)')
    parser.add_argument('--notes', help='release notes file (defaults to Releases/v<version>.md)')
    parser.add_argument('--key-file', help='private EdDSA key file; omit to read it from the Keychain')
    parser.add_argument('--download-prefix', help='URL prefix for new archives')
    parser.add_argument('--previous', help='previous appcast URL or file, to keep old releases in the feed')
    parser.add_argument('--allow-ad-hoc', action='store_true', help='generate a feed for local testing only')
    args = parser.parse_args()

    app = root / 'dist' / 'Квиз Студия.app'
    archive = Path(args.archive) if args.archive else root / 'dist/QuizStudio-macOS.zip'
    if not archive.exists():
        raise SystemExit(f'Missing {archive}. Run python3 build.py first.')
    version, build = archive_metadata(archive)
    if version != args.version:
        raise SystemExit(f'{archive} contains version {version}, not {args.version}.')
    if app.exists() and signature_kind(app) == 'adhoc' and not args.allow_ad_hoc:
        raise SystemExit('Ad-hoc builds cannot receive updates. Sign with QUIZSTUDIO_SIGN_IDENTITY first, '
                         'or pass --allow-ad-hoc for a local feed that will not install.')
    if args.key_file == '-':
        raise SystemExit('A stdin key file cannot be used here; pass a file path or use the Keychain.')

    sparkle = root / 'dist/sparkle'
    if sparkle.exists():
        shutil.rmtree(sparkle)
    sparkle.mkdir(parents=True)
    staged = sparkle / f'QuizStudio-{version}.zip'
    shutil.copy2(archive, staged)

    notes = Path(args.notes) if args.notes else root / 'Releases' / f'v{version}.md'
    if notes.exists():
        # An HTML fragment without DOCTYPE/body is embedded into the appcast,
        # so the update window renders it without an extra hosted asset.
        (sparkle / f'QuizStudio-{version}.html').write_text(markdown_to_html(notes.read_text()), encoding='utf-8')
    if args.previous:
        fetch_previous(args.previous, sparkle / 'appcast.xml')

    prefix = args.download_prefix or f'https://github.com/totchto/quiz-studio-macos/releases/download/v{version}/'
    command = [str(sparkle_tool('generate_appcast'))]
    if args.key_file:
        command += ['--ed-key-file', args.key_file]
    command += [
        '--download-url-prefix', prefix,
        '--link', 'https://github.com/totchto/quiz-studio-macos/releases/latest',
        '--versions', build,
        '--maximum-deltas', '0',
        '-o', str(sparkle / 'appcast.xml'),
        str(sparkle),
    ]
    subprocess.run(command, check=True)

    signature = enclosure_signature(sparkle / 'appcast.xml', staged.name)
    verification_command = [str(sparkle_tool('sign_update')), '--verify']
    if args.key_file:
        verification_command += ['--ed-key-file', args.key_file]
    verification_command += [str(staged), signature]
    verification = subprocess.run(verification_command, capture_output=True, text=True)
    if verification.returncode != 0:
        raise SystemExit('Update signature verification failed:\n' + verification.stdout + verification.stderr)
    print(f'Appcast: {sparkle / "appcast.xml"}\nFeed URL: {feed_url}\nArchive: {staged.name}')


if __name__ == '__main__':
    main()

"""Build a standalone macOS app and distributable ZIP with Xcode installed."""
from pathlib import Path
import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent
placeholder_key = 'REPLACE_WITH_SPARKLE_PUBLIC_KEY'


def run(command, **kwargs):
    subprocess.run(command, check=True, **kwargs)


def signing_identity():
    return os.environ.get('QUIZSTUDIO_SIGN_IDENTITY', '-')


def notary_profile():
    return os.environ.get('QUIZSTUDIO_NOTARY_PROFILE', '')


def sign(path, identity):
    command = ['codesign', '--force', '--sign', identity]
    if identity != '-':
        # Developer ID builds need the hardened runtime for notarization.
        command += ['--options', 'runtime', '--timestamp']
    command.append(str(path))
    run(command)


def embed_sparkle(app, bin_path):
    framework = bin_path / 'Sparkle.framework'
    if not framework.is_dir():
        raise SystemExit(f'Missing Sparkle.framework in {bin_path}. Run swift build first.')
    destination = app / 'Contents/Frameworks'
    destination.mkdir(parents=True, exist_ok=True)
    installed = destination / 'Sparkle.framework'
    if installed.exists():
        shutil.rmtree(installed)
    shutil.copytree(framework, installed, symlinks=True)
    binary = app / 'Contents/MacOS/QuizStudio'
    load_commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    if '@executable_path/../Frameworks' not in load_commands:
        run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(binary)])


def validate_updater_config(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    problems = []
    feed = info.get('SUFeedURL', '')
    if not feed.startswith('https://'):
        problems.append('SUFeedURL must be a permanent HTTPS address.')
    key = info.get('SUPublicEDKey', '')
    if key == placeholder_key:
        problems.append('SUPublicEDKey is still the placeholder; generate the Sparkle key first.')
    else:
        try:
            if len(base64.b64decode(key)) != 32:
                problems.append('SUPublicEDKey is not a 32-byte EdDSA public key.')
        except Exception:
            problems.append('SUPublicEDKey is not valid base64.')
    if not info.get('SUEnableAutomaticChecks'):
        problems.append('SUEnableAutomaticChecks must be enabled for launch checks.')
    if problems:
        raise SystemExit('Updater configuration is incomplete:\n  ' + '\n  '.join(problems))


def sign_app(app, identity):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    if framework.exists():
        version_b = framework / 'Versions/B'
        for xpc in sorted((version_b / 'XPCServices').glob('*.xpc')):
            sign(xpc, identity)
        sign(version_b / 'Autoupdate', identity)
        sign(version_b / 'Updater.app', identity)
        sign(framework, identity)
    import_tools = app / 'Contents/Resources/ImportTools'
    if import_tools.exists():
        for name in ('yt-dlp', 'deno'):
            binary = import_tools / name
            if binary.exists():
                sign(binary, identity)
    sign(app, identity)
    run(['codesign', '--verify', '--deep', '--strict', str(app)])


def notarize(app, identity):
    profile = notary_profile()
    if not profile:
        return
    if identity == '-':
        raise SystemExit('Notarization requires QUIZSTUDIO_SIGN_IDENTITY with a Developer ID identity.')
    upload = root / 'dist' / 'notarize.zip'
    run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(upload)])
    try:
        run(['xcrun', 'notarytool', 'submit', str(upload), '--keychain-profile', profile, '--wait'])
        run(['xcrun', 'stapler', 'staple', str(app)])
        run(['xcrun', 'stapler', 'validate', str(app)])
    finally:
        upload.unlink(missing_ok=True)


def package_app(app):
    dist = root / 'dist'
    archive = dist / 'QuizStudio-macOS.zip'
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)])
    version = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    sparkle = dist / 'sparkle'
    sparkle.mkdir(exist_ok=True)
    shutil.copy2(archive, sparkle / f'QuizStudio-{version}.zip')
    notes = root / 'Releases' / f'v{version}.md'
    if notes.exists():
        shutil.copy2(notes, sparkle / f'QuizStudio-{version}.md')
    return archive


def main():
    if sys.platform != 'darwin':
        raise SystemExit('Building the app requires macOS and Xcode.')
    run(['swift', 'build', '-c', 'release'], cwd=root)
    bin_path = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip())
    app = root / 'dist' / 'Квиз Студия.app'
    (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app / 'Contents/Resources').mkdir(parents=True, exist_ok=True)
    shutil.copy2(bin_path / 'QuizStudio', app / 'Contents/MacOS/QuizStudio')
    shutil.copy2(root / 'Resources/Info.plist', app / 'Contents/Info.plist')
    shutil.copy2(root / 'Resources/bleep.wav', app / 'Contents/Resources/bleep.wav')
    shutil.copy2(root / 'Resources/MUSIC-CREDITS.txt', app / 'Contents/Resources/MUSIC-CREDITS.txt')
    music = root / 'Resources/BackgroundMusic'
    installed_music = app / 'Contents/Resources/BackgroundMusic'
    if installed_music.exists():
        shutil.rmtree(installed_music)
    if music.exists():
        shutil.copytree(music, app / 'Contents/Resources/BackgroundMusic', dirs_exist_ok=True)
    # Keep helper executables local to the app; no system installation is needed.
    tools = root / 'Resources/ImportTools'
    if tools.exists():
        versions = json.loads((tools / 'versions.json').read_text())
        for name in ('yt-dlp', 'deno'):
            assert hashlib.sha256((tools / name).read_bytes()).hexdigest() == versions[name]['binary_sha256'], f'Unexpected helper contents: {name}'
        destination = app / 'Contents/Resources/ImportTools'
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(tools, destination)
    # Convert the master PNG into every macOS icon resolution.
    iconset = root / '.build' / 'AppIcon.iconset'
    iconset.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            output = iconset / f'icon_{size}x{size}{suffix}.png'
            run(['sips', '-z', str(size * scale), str(size * scale), str(root / 'Resources/AppIcon.png'), '--out', str(output)], stdout=subprocess.DEVNULL)
    run(['iconutil', '-c', 'icns', str(iconset), '-o', str(app / 'Contents/Resources/AppIcon.icns')])
    embed_sparkle(app, bin_path)
    validate_updater_config(app)
    identity = signing_identity()
    if identity == '-':
        print('Warning: ad-hoc signing. Sparkle rejects updates unless the app is signed with a Developer ID identity.')
    sign_app(app, identity)
    notarize(app, identity)
    archive = package_app(app)
    print(f'Application: {app}\nArchive: {archive}')


if __name__ == '__main__':
    main()

"""Build a standalone macOS app and distributable ZIP with Xcode installed."""
from pathlib import Path
import subprocess
import shutil
import sys
root = Path(__file__).resolve().parent
if sys.platform != 'darwin':
    raise SystemExit('Building the app requires macOS and Xcode.')
subprocess.run(['swift', 'build', '-c', 'release'], cwd=root, check=True)
bin_path = subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip()
app = root / 'dist' / 'Квиз Студия.app'
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Contents/Resources').mkdir(parents=True, exist_ok=True)
shutil.copy2(Path(bin_path) / 'QuizStudio', app / 'Contents/MacOS/QuizStudio')
shutil.copy2(root / 'Resources/Info.plist', app / 'Contents/Info.plist')
shutil.copy2(root / 'Resources/bleep.wav', app / 'Contents/Resources/bleep.wav')
shutil.copy2(root / 'Resources/MUSIC-CREDITS.txt', app / 'Contents/Resources/MUSIC-CREDITS.txt')
music = root / 'Resources/BackgroundMusic'
installed_music = app / 'Contents/Resources/BackgroundMusic'
if installed_music.exists():
    shutil.rmtree(installed_music)
if music.exists():
    shutil.copytree(music, app / 'Contents/Resources/BackgroundMusic', dirs_exist_ok=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
archive = root / 'dist' / 'QuizStudio-macOS.zip'
subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
print(f'Application: {app}\nArchive: {archive}')

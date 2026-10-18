from pathlib import Path
import subprocess, tempfile, sys
project = Path(__file__).resolve().parents[1]
source = (project/'Sources/QuizStudio/main.swift').read_text().split('struct DraggableQuestionRow: View')[0]
extras = '\n'.join(p.read_text() for p in sorted((project/'Sources/QuizStudio').glob('*.swift')) if p.name != 'main.swift')
checks = (project/'Tests/PhoneChecks.swift').read_text()
with tempfile.TemporaryDirectory(prefix='quiz-phone-checks-') as temporary:
    root=Path(temporary)
    merged=root/'PhoneChecks.swift'; merged.write_text(extras+source+checks)
    executable=root/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(root/'cache'),str(merged),'-o',str(executable)],check=True)
    subprocess.run([str(executable),*sys.argv[1:]],check=True)

from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='quiz-bank-checks-') as folder:
    folder=Path(folder)
    source=(root/'Sources/QuizStudio/main.swift').read_text().split('struct DraggableQuestionRow: View')[0]
    extras='\n'.join(p.read_text() for p in sorted((root/'Sources/QuizStudio').glob('*.swift')) if p.name!='main.swift')
    merged=folder/'Checks.swift';merged.write_text(extras+source+(root/'Tests/BankChecks.swift').read_text())
    binary=folder/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(folder/'cache'),str(merged),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(folder),*sys.argv[1:]],check=True)

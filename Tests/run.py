from pathlib import Path
import subprocess
import tempfile
project = Path(__file__).resolve().parents[1]
source = (project / 'Sources/QuizStudio/main.swift').read_text()
checks = (project / 'Tests/LogicChecks.swift').read_text()
with tempfile.TemporaryDirectory(prefix='quiz-studio-checks-') as scratch:
    scratch = Path(scratch)
    merged = scratch / 'Checks.swift'
    merged.write_text(source.split('@main struct QuizStudioApp')[0] + source[source.index('class SelectableScoreTextField:'):] + checks)
    executable = scratch / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(scratch / 'cache'), str(merged), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(project / 'Tests/legacy-quiz.json')], check=True)

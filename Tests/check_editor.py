from pathlib import Path
import subprocess,tempfile,wave,struct,math
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='quiz-editor-checks-') as folder:
    folder=Path(folder)
    with wave.open(str(folder/'tone.wav'),'w') as wav:
        wav.setparams((1,2,44100,0,'NONE','not compressed'))
        wav.writeframes(b''.join(struct.pack('<h',int(10*math.sin(2*math.pi*440*i/44100))) for i in range(44100*3)))
    source=(root/'Sources/QuizStudio/main.swift').read_text().split('struct DraggableQuestionRow: View')[0]
    extras='\n'.join(p.read_text() for p in sorted((root/'Sources/QuizStudio').glob('*.swift')) if p.name!='main.swift')
    merged=folder/'Checks.swift';merged.write_text(extras+source+(root/'Tests/EditorChecks.swift').read_text())
    binary=folder/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(folder/'cache'),str(merged),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(folder)],check=True)

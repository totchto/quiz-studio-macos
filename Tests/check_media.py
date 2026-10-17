from pathlib import Path
import subprocess, tempfile, wave, math, struct, sys
project=Path(__file__).resolve().parents[1]
source=(project/'Sources/QuizStudio/main.swift').read_text().split('struct DraggableQuestionRow: View')[0]
with tempfile.TemporaryDirectory(prefix='quiz-media-checks-') as folder:
    folder=Path(folder)
    with wave.open(str(folder/'tone.wav'),'w') as wav:
        wav.setparams((1,2,44100,0,'NONE','not compressed'))
        wav.writeframes(b''.join(struct.pack('<h',int(3000*math.sin(2*math.pi*440*i/44100))) for i in range(44100*3)))
    merged=folder/'MediaChecks.swift'; merged.write_text(source+(project/'Tests/MediaChecks.swift').read_text())
    binary=folder/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(folder/'cache'),str(merged),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(folder),*sys.argv[1:]],check=True)

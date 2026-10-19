from pathlib import Path
import tempfile,subprocess,wave,math,struct,json
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='quiz-youtube-checks-') as scratch:
    folder=Path(scratch)
    with wave.open(str(folder/'tone.wav'),'w') as wav:
        wav.setparams((1,2,22050,0,'NONE','not compressed'))
        wav.writeframes(b''.join(struct.pack('<h',int(5000*math.sin(2*math.pi*440*i/22050))) for i in range(22050*2)))
    tools=folder/'tools';tools.mkdir()
    helper='''#!/usr/bin/python3
import sys,json,shutil,time
from pathlib import Path
root=Path(__file__).resolve().parent.parent
if (root/'slow').exists():time.sleep(20)
if (root/'failure').exists():print('ERROR: Mock unavailable video',flush=True);sys.exit(1)
if '--dump-single-json' in sys.argv:
 print(json.dumps({'id':'jNQXAC9IVRw','title':'Fixture video','duration':1.8,'formats':[{'format_id':'137','ext':'mp4','vcodec':'avc1.64001f','acodec':'none','height':720},{'format_id':'140','ext':'m4a','vcodec':'none','acodec':'mp4a.40.2','abr':128}]}));sys.exit()
format_id=sys.argv[sys.argv.index('--format')+1]
output=Path(sys.argv[sys.argv.index('--output')+1])
assert '--no-playlist' in sys.argv and '--ignore-config' in sys.argv and '--no-plugin-dirs' in sys.argv
assert sys.argv[-2]=='--' and sys.argv[-1]=='https://www.youtube.com/watch?v=jNQXAC9IVRw'
print('QUIZ_PROGRESS: 50.0%',flush=True)
shutil.copyfile(root/('video.mp4' if format_id=='137' else 'audio.m4a'),output)
print('QUIZ_PROGRESS:100.0%',flush=True)
'''
    (tools/'yt-dlp').write_text(helper);(tools/'yt-dlp').chmod(0o755)
    (tools/'deno').write_text('#!/bin/sh\nexit 0\n');(tools/'deno').chmod(0o755)
    main=(root/'Sources/QuizStudio/main.swift').read_text().split('struct DraggableQuestionRow: View')[0]
    extras='\n'.join(p.read_text() for p in sorted((root/'Sources/QuizStudio').glob('*.swift')) if p.name!='main.swift')
    merged=folder/'Checks.swift';merged.write_text(extras+main+(root/'Tests/YouTubeChecks.swift').read_text())
    binary=folder/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(folder/'cache'),str(merged),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(folder)],check=True)

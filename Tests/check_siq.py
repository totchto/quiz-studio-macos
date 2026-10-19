from pathlib import Path
import subprocess,tempfile,zipfile,sys
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='quiz-siq-checks-') as scratch:
    folder=Path(scratch)
    old='''<?xml version="1.0"?><package name="Legacy" version="4" xmlns="http://vladimirkhil.com/ygpackage3.0.xsd"><rounds><round name="Round"><themes><theme name="Theme"><questions><question price="300"><type name="auction"/><scenario><atom>Question</atom><atom type="image">@a b.png</atom><atom type="marker"/><atom>Explanation</atom><atom type="image">@answer.png</atom></scenario><right><answer>Answer</answer><answer>Alternative</answer></right><info><comments>Comment</comments></info></question></questions></theme></themes></round></rounds></package>'''
    modern='''<?xml version="1.0"?><package name="Modern" version="5"><rounds><round name="Round"><themes><theme name="Theme"><questions><question price="100"><params><param name="question" type="content"><item>Choose</item></param><param name="answerType">select</param><param name="answerOptions" type="group"><param name="A" type="content"><item>One</item></param><param name="B" type="content"><item>Two</item></param><param name="C" type="content"><item>Three</item></param><param name="D" type="content"><item>Four</item></param></param></params><right><answer>C</answer></right></question><question price="200"><params><param name="question" type="content"><item type="image" isRef="True">missing.png</item><item type="audio" isRef="False">https://invalid.example/track.mp3</item><item type="html">Never execute this</item></param></params><right><answer/></right></question></questions></theme></themes></round></rounds></package>'''
    def package(name,xml,files=None):
        with zipfile.ZipFile(folder/name,'w',zipfile.ZIP_DEFLATED) as z:
            z.writestr('content.xml',xml)
            for path,data in (files or {}).items():z.writestr(path,data)
    package('legacy.siq',old,{'Images/a%20b.png':b'picture','Images/answer.png':b'answer'})
    package('modern.siq',modern)
    package('video.siq',old.replace('version="4"','version="3"').replace('type="image">@a b.png','type="video">@clip.mp4'),{'Video/clip.mp4':b'video','Images/answer.png':b'answer'})
    package('traversal.siq',modern,{'Images/%2e%2e/outside':b'bad'})
    package('absolute.siq',modern,{'/outside':b'bad'})
    package('duplicate.siq',modern,{'Images/a%20b.png':b'a','Images/a b.png':b'b'})
    package('doctype.siq','<!DOCTYPE package [<!ENTITY evil SYSTEM "file:///etc/passwd">]><package version="5"/>')
    package('badxml.siq','<package>')
    package('future.siq','<package version="6"/>')
    with zipfile.ZipFile(folder/'link.siq','w') as z:
        z.writestr('content.xml',modern)
        item=zipfile.ZipInfo('Images/link');item.create_system=3;item.external_attr=0o120777<<16;z.writestr(item,'/etc/passwd')
    source=(root/'Sources/QuizStudio/main.swift').read_text().split('struct DraggableQuestionRow: View')[0]
    extras='\n'.join(p.read_text() for p in sorted((root/'Sources/QuizStudio').glob('*.swift')) if p.name!='main.swift')
    checks=folder/'Checks.swift';checks.write_text(extras+source+(root/'Tests/SIQChecks.swift').read_text())
    binary=folder/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(folder/'cache'),str(checks),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(folder),*sys.argv[1:]],check=True)

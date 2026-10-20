# coding: utf-8
from pathlib import Path
import subprocess,tempfile,zipfile,csv,sys
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='quiz-new-features-') as folder:
    folder=Path(folder)
    with (folder/'questions.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.writer(f);writer.writerow(['Вопрос','Ответ','Объяснение','Тип','Вариант1','Вариант2','Вариант3','Вариант4','Правильные варианты','Погрешность','События'])
        writer.writerow(['Сколько?','10','Первая строка\nВторая строка','Числовой ответ','','','','','','2',''])
        writer.writerow(['Чётные','','Делятся на 2','Несколько вариантов','2','3','4','5','1,3','',''])
        writer.writerow(['Порядок','','','Порядок событий','','','','','','','Первое|Второе|Третье'])
    workbook='<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Вопросы" sheetId="1" r:id="rId1"/></sheets></workbook>'
    relations='<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>'
    shared='<sst><si><t>Вопрос</t></si><si><t>Ответ</t></si><si><t>Тип</t></si><si><t>Сколько планет?</t></si></sst>'
    sheet='''<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="inlineStr"><is><t>Вариант1</t></is></c><c r="E1" t="inlineStr"><is><t>Вариант2</t></is></c><c r="F1" t="inlineStr"><is><t>Вариант3</t></is></c><c r="G1" t="inlineStr"><is><t>Вариант4</t></is></c><c r="H1" t="inlineStr"><is><t>Правильные варианты</t></is></c></row><row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2"><v>8</v></c><c r="C2" t="inlineStr"><is><t>Числовой ответ</t></is></c></row><row r="3"><c r="A3" t="inlineStr"><is><t>Выберите</t></is></c><c r="C3" t="inlineStr"><is><t>Несколько вариантов</t></is></c><c r="D3" t="inlineStr"><is><t>2</t></is></c><c r="E3" t="inlineStr"><is><t>3</t></is></c><c r="F3" t="inlineStr"><is><t>4</t></is></c><c r="G3" t="inlineStr"><is><t>5</t></is></c><c r="H3" t="inlineStr"><is><t>1,3</t></is></c></row><row r="4"><c r="A4" t="inlineStr"><is><t>Формула</t></is></c><c r="B4"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>'''
    for name,unsafe in [('questions.xlsx',False),('unsafe.xlsx',True)]:
        with zipfile.ZipFile(folder/name,'w',zipfile.ZIP_DEFLATED) as z:
            for path,data in [('xl/workbook.xml',workbook),('xl/_rels/workbook.xml.rels',relations),('xl/sharedStrings.xml',shared),('xl/worksheets/sheet1.xml',sheet)]:z.writestr(path,data)
            if unsafe:z.writestr('../outside','bad')
    source=(root/'Sources/QuizStudio/main.swift').read_text().split('struct DraggableQuestionRow: View')[0]
    extras='\n'.join(p.read_text() for p in sorted((root/'Sources/QuizStudio').glob('*.swift')) if p.name!='main.swift')
    merged=folder/'Checks.swift';merged.write_text(extras+source+(root/'Tests/NewFeaturesChecks.swift').read_text())
    binary=folder/'checks'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(folder/'cache'),str(merged),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(folder)],check=True)

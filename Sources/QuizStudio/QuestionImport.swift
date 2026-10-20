import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import PDFKit

struct ImportedQuestionRow: Identifiable {
    var id = UUID()
    var line: Int
    var question: Question
    var warnings: [String] = []
    var selected = true
    var issues: [String] { question.issues+warnings }
}
struct QuestionImportResult { var rows: [ImportedQuestionRow]; var warnings: [String] = [] }
enum QuestionTextImport {
    static let maxRows = 5000
    static func delimited(_ text: String,separator: Character) throws -> [[String]] {
        guard text.utf8.count <= 8*1024*1024 else { throw SIQError(message:"Текст больше 8 МБ.") }
        var rows: [[String]] = []; var row: [String] = []; var cell = ""; var quoted = false; var afterQuote = false
        let chars = Array(text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")); var i = 0
        func appendCell() throws { guard cell.count <= 30000, row.count < 40 else { throw SIQError(message:"Слишком длинное поле или больше 40 столбцов.") }; row.append(cell); cell = ""; afterQuote = false }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i+1 < chars.count && chars[i+1] == "\"" { cell.append("\""); i += 1 } else { quoted = false; afterQuote = true } } else { cell.append(c) }
            } else if c == separator { try appendCell() }
            else if c == "\n" { try appendCell(); rows.append(row); row = []; guard rows.count <= maxRows+1 else { throw SIQError(message:"Не больше 5000 вопросов за один импорт.") } }
            else if c == "\"" && cell.isEmpty && !afterQuote { quoted = true }
            else if afterQuote { guard c.isWhitespace else { throw SIQError(message:"Лишние символы после закрывающей кавычки.") } }
            else { cell.append(c) }
            i += 1
        }
        guard !quoted else { throw SIQError(message:"Не закрыта кавычка в таблице.") }
        if !cell.isEmpty || !row.isEmpty || afterQuote { try appendCell(); rows.append(row) }
        return rows
    }
    static func normalized(_ text: String) -> String { text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"\u{FEFF}",with:"").lowercased().replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"_",with:"") }
    static func labeledField(_ text:String) -> String {
        if normalized(text).range(of:"^вопрос(?:№)?[0-9]+$",options:.regularExpression) != nil { return "question" }
        return field(text)
    }
    static func field(_ header: String) -> String {
        let h = normalized(header)
        let aliases: [String:[String]] = ["question":["вопрос","question","q"],"answer":["ответ","answer","правильныйответ"],"explanation":["объяснение","пояснение","explanation"],"type":["тип","type","kind"],"correct":["правильныеварианты","верныеварианты","correct","correctchoices"],"tolerance":["погрешность","tolerance"],"events":["события","порядок","events","sequence"],"pairs":["пары","соответствия","pairs"],"tags":["темы","теги","tags","тематика"],"difficulty":["сложность","difficulty"],"seconds":["время","секунды","seconds"]]
        for (key,names) in aliases where names.contains(h) { return key }
        for i in 1...8 where ["вариант\(i)","choice\(i)","a\(i)"].contains(h) { return "choice\(i)" }
        return ""
    }
    static func parse(_ text: String) throws -> QuestionImportResult {
        guard text.utf8.count <= 8*1024*1024 else { throw SIQError(message:"Текст больше 8 МБ.") }
        let text = text.replacingOccurrences(of:"\u{FEFF}",with:"").replacingOccurrences(of:"\r\n",with:"\n")
        if text.split(separator:"\n").contains(where:{ $0.range(of:"^\\s*(?:вопрос(?:\\s*№?\\s*\\d+)?|question(?:\\s*#?\\s*\\d+)?)\\s*:",options:[.regularExpression,.caseInsensitive]) != nil }) {
            var rows: [[String]] = []; var current = ["","",""]; var active = 0; var has = false
            for line in text.components(separatedBy:"\n") {
                let parts = line.split(separator:":",maxSplits:1).map(String.init); let key = labeledField(parts.first ?? "")
                if parts.count == 2 && ["question","answer","explanation"].contains(key) {
                    if key == "question" && has { rows.append(current); current = ["","",""] }
                    active = key == "question" ? 0 : key == "answer" ? 1 : 2; current[active] = parts[1].trimmingCharacters(in:.whitespaces); has = true
                } else if has { current[active] += "\n"+line }
            }
            if has { rows.append(current) }; return try convert(rows,headers:["question","answer","explanation"])
        }
        let first = text.components(separatedBy:"\n").first ?? ""
        let separators: [Character] = ["\t",";",","]
        let separator = separators.max { count($0,in:first) < count($1,in:first) } ?? "\t"
        if !first.contains(" — ") && count(separator,in:first) > 0 { return try table(delimited(text,separator:separator)) }
        let rows = text.components(separatedBy:"\n").filter { !$0.trimmingCharacters(in:.whitespaces).isEmpty }.map { $0.components(separatedBy:" — ").prefix(3).map { $0.trimmingCharacters(in:.whitespaces) } }
        return try convert(rows,headers:["question","answer","explanation"])
    }
    static func count(_ c: Character,in text: String) -> Int { text.filter { $0 == c }.count }
    static func table(_ rows: [[String]],formulaRows: Set<Int> = []) throws -> QuestionImportResult {
        guard let first = rows.first else { return QuestionImportResult(rows:[]) }
        let headers = first.map(field)
        if headers.contains("question") {
            guard Set(headers.filter { !$0.isEmpty }).count == headers.filter({ !$0.isEmpty }).count else { throw SIQError(message:"Повторяются названия столбцов.") }
            var result = try convert(Array(rows.dropFirst()),headers:headers,lineOffset:2,formulaRows:Set(formulaRows.map { $0-1 }))
            if headers.contains("") { result.warnings.append("Неизвестные столбцы пропущены. Поддерживаемые названия приведены в справке импорта.") }
            return result
        }
        return try convert(rows,headers:["question","answer","explanation"],formulaRows:formulaRows)
    }
    static func convert(_ rows: [[String]],headers: [String],lineOffset: Int = 1,formulaRows: Set<Int> = []) throws -> QuestionImportResult {
        guard rows.count <= maxRows else { throw SIQError(message:"Не больше 5000 вопросов за один импорт.") }
        var result: [ImportedQuestionRow] = []
        for (index,row) in rows.enumerated() where row.contains(where:{ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) {
            var values: [String:String] = [:]
            for (i,key) in headers.enumerated() where !key.isEmpty && row.indices.contains(i) { values[key] = row[i].trimmingCharacters(in:.whitespacesAndNewlines) }
            var q = Question(); q.text = values["question"] ?? ""; q.answer = values["answer"] ?? ""; q.explanation = values["explanation"]; q.tags = Question.cleanTags(values["tags"] ?? "")
            let options = (1...8).map { values["choice\($0)"] ?? "" }; let last = options.lastIndex { !$0.isEmpty }
            if let last { q.choices = Array(options[...last]) }
            let marked = (values["correct"] ?? "").components(separatedBy:CharacterSet(charactersIn:",;| ")).compactMap(Int.init).map { $0-1 }
            let type = normalized(values["type"] ?? "")
            let mapped: [String:String] = ["open":"Открытый вопрос","choice":"Один из четырёх","multiple":"Несколько вариантов","numeric":"Числовой ответ","number":"Числовой ответ","order":"Порядок событий","sequence":"Порядок событий"]
            q.kind = Question.kinds.first { normalized($0) == type } ?? mapped[type] ?? "Открытый вопрос"
            if type.isEmpty {
                if !(values["pairs"] ?? "").isEmpty { q.kind = "Сопоставление" }
                else if !(values["events"] ?? "").isEmpty { q.kind = "Порядок событий" }
                else if last != nil { q.kind = marked.count > 1 || q.choices.count != 4 ? "Несколько вариантов" : "Один из четырёх" }
            }
            var warnings: [String] = []
            if !type.isEmpty && !Question.kinds.contains(where:{ normalized($0) == type }) && mapped[type] == nil { warnings.append("Неизвестный тип: "+(values["type"] ?? "")) }
            if q.kind == "Числовой ответ" { q.numericAnswer = Question.number(q.answer); q.numericTolerance = (values["tolerance"] ?? "").isEmpty ? 0 : Question.number(values["tolerance"]!) ?? -1 }
            if q.kind == "Сопоставление" { q.matchPairs = (values["pairs"] ?? "").components(separatedBy:"|").map { pair in let parts = pair.split(separator:"=",maxSplits:1).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }; return MatchPair(left:parts.first ?? "",right:parts.count > 1 ? parts[1] : "") } }
            if q.kind == "Порядок событий" { q.sequenceItems = (values["events"] ?? q.answer).components(separatedBy:"|").map { SequenceItem(text:$0.trimmingCharacters(in:.whitespacesAndNewlines)) } }
            if q.kind == "Один из четырёх" || q.kind == "Несколько вариантов" {
                let selected = marked.isEmpty ? (Int(q.answer).map { [$0-1] } ?? q.choices.firstIndex(of:q.answer).map { [$0] } ?? []) : marked
                if q.kind == "Один из четырёх" { q.selectedChoice = selected.first; if selected.count > 1 { warnings.append("Для одного ответа указан набор вариантов") }; if let i = q.selectedChoice, q.choices.indices.contains(i) { q.answer = q.choices[i] } }
                else { q.correctChoices = selected }
            }
            if let difficulty = values["difficulty"], !difficulty.isEmpty {
                let names = ["лёгкий":"Лёгкий","легкий":"Лёгкий","easy":"Лёгкий","средний":"Средний","medium":"Средний","сложный":"Сложный","hard":"Сложный"]
                if let value = names[difficulty.lowercased()] { q.difficulty = value } else { warnings.append("Сложность не распознана: "+difficulty) }
            }
            if let time = values["seconds"], !time.isEmpty { if let n = Int(time), (0...3600).contains(n) { q.seconds = n } else { warnings.append("Время не распознано") } }
            if formulaRows.contains(index) { warnings.append("Строка содержит формулу: замените её значением в исходной таблице") }
            if let raw = values["correct"], !raw.isEmpty, raw.components(separatedBy:CharacterSet(charactersIn:",;| ")).filter({ !$0.isEmpty }).contains(where:{ Int($0) == nil }) { warnings.append("Номера правильных вариантов не распознаны") }
            if row.count > headers.count { warnings.append("Лишние поля пропущены; проверьте разделитель") }
            if !warnings.isEmpty { q.siqReviewRequired = true }
            var imported = ImportedQuestionRow(line:index+lineOffset,question:q,warnings:warnings); imported.selected = imported.issues.isEmpty; result.append(imported)
        }
        return QuestionImportResult(rows:result)
    }
    static func file(_ url: URL) throws -> QuestionImportResult {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 16*1024*1024 else { throw SIQError(message:"Файл больше 16 МБ.") }
        if url.pathExtension.lowercased() == "xlsx" { return try xlsx(url) }
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url:url) else { throw SIQError(message:"Не удалось открыть PDF.") }
            let text = (0..<document.pageCount).compactMap { document.page(at:$0)?.string }.joined(separator:"\n")
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw SIQError(message:"В PDF нет извлекаемого текста. Для сканов нужно распознавание OCR.") }
            var result = try parse(text)
            result.warnings.append("Текст извлечён из PDF. Проверьте порядок и распознавание вопросов; сканы без текстового слоя не поддерживаются.")
            return result
        }
        if url.pathExtension.lowercased() == "pptx" { return try pptx(url) }
        let data = try Data(contentsOf:url)
        guard let text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) ?? String(data:data,encoding:.windowsCP1251) else { throw SIQError(message:"Не удалось прочитать текстовую кодировку") }
        if url.pathExtension.lowercased() == "tsv" { return try table(delimited(text,separator:"\t")) }
        return try parse(text)
    }
    static func html(_ data: Data) throws -> QuestionImportResult {
        guard data.count <= 8*1024*1024, let html = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.windowsCP1251) else { throw SIQError(message:"Страница больше 8 МБ или имеет неподдерживаемую кодировку.") }
        var text = html
        for tag in ["script","style","noscript","svg"] {
            text = text.replacingOccurrences(of:"(?is)<\\s*\(tag)\\b[^>]*>.*?<\\s*/\\s*\(tag)\\s*>",with:" ",options:.regularExpression)
        }
        text = text.replacingOccurrences(of:"(?i)<\\s*(br|/p|/div|/li|/tr|/h[1-6])\\b[^>]*>",with:"\n",options:.regularExpression)
        text = text.replacingOccurrences(of:"<[^>]+>",with:" ",options:.regularExpression)
        let entities = ["&nbsp;":" ","&amp;":"&","&lt;":"<","&gt;":">","&quot;":"\"","&#39;":"'","&apos;":"'","&mdash;":"—","&ndash;":"–","&laquo;":"«","&raquo;":"»","&hellip;":"…"]
        for (entity,value) in entities { text = text.replacingOccurrences(of:entity,with:value,options:.caseInsensitive) }
        if let regex = try? NSRegularExpression(pattern:"&#(x[0-9a-fA-F]+|[0-9]+);",options:.caseInsensitive) {
            let nsText = text as NSString
            for match in regex.matches(in:text,range:NSRange(location:0,length:nsText.length)).reversed() {
                let raw = nsText.substring(with:match.range(at:1)); let value: UInt32?
                if raw.lowercased().hasPrefix("x") { value = UInt32(raw.dropFirst(),radix:16) }
                else { value = UInt32(raw) }
                if let value, let scalar = UnicodeScalar(value) { text = (text as NSString).replacingCharacters(in:match.range,with:String(scalar)) }
            }
        }
        text = text.replacingOccurrences(of:"[ \\t]+",with:" ",options:.regularExpression)
        var result = try parse(text)
        result.warnings.append("Импортировано из HTML-страницы. Проверьте границы вопросов и ответы перед добавлением в банк.")
        return result
    }
    static func pptx(_ url: URL) throws -> QuestionImportResult {
        let files = try SIQArchive().read(url,maxBytes:64*1024*1024)
        let paths = files.keys.filter { $0.range(of:"^ppt/slides/slide[0-9]+\\.xml$",options:.regularExpression) != nil }.sorted { a,b in
            func number(_ path:String) -> Int { Int(path.split(separator:"/").last!.dropFirst(5).dropLast(4)) ?? 0 }
            return number(a) < number(b)
        }
        guard !paths.isEmpty else { throw SIQError(message:"В презентации не найдены слайды.") }
        var slides: [String] = []
        for path in paths {
            guard let data = files[path] else { continue }
            let root = try SIQXML().parse(data,expectedRoot:"sld")
            func collect(_ node: SIQNode) -> [String] {
                if node.name == "t" { return [node.value] }
                return node.children.flatMap(collect)
            }
            slides.append(collect(root).filter { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.joined(separator:" "))
        }
        var result = try parse(slides.joined(separator:"\n"))
        result.warnings.append("Текст извлечён из PPTX по порядку слайдов. Проверьте, что вопросы и ответы не разделены изображениями или анимацией.")
        return result
    }
    static func xlsx(_ url: URL) throws -> QuestionImportResult {
        let files = try SIQArchive().read(url,maxBytes:64*1024*1024)
        guard let workbook = files["xl/workbook.xml"], let relations = files["xl/_rels/workbook.xml.rels"] else { throw SIQError(message:"Это не поддерживаемый XLSX-файл.") }
        let book = try SIQXML().parse(workbook,expectedRoot:"workbook"); let rels = try SIQXML().parse(relations,expectedRoot:"Relationships")
        guard let sheet = book.child("sheets")?.children.first(where:{ $0.attributes["state"] != "hidden" && $0.attributes["state"] != "veryHidden" }), let id = sheet.attributes["r:id"] ?? sheet.attributes["id"], let relation = rels.children.first(where:{ $0.attributes["Id"] == id }), relation.attributes["TargetMode"] != "External", let target = relation.attributes["Target"] else { throw SIQError(message:"Не найден первый видимый лист") }
        let path = try SIQArchive.key(target.hasPrefix("/") ? String(target.dropFirst()) : "xl/"+target)
        guard let sheetData = files[path] else { throw SIQError(message:"Нет данных листа") }
        func text(_ node: SIQNode) -> String { node.name == "t" ? node.text : node.children.map(text).joined() }
        var shared: [String] = []
        if let data = files["xl/sharedStrings.xml"] { shared = try SIQXML().parse(data,expectedRoot:"sst").list("si").map(text) }
        let xml = try SIQXML().parse(sheetData,expectedRoot:"worksheet")
        var rows: [[String]] = []; var formulaRows: Set<Int> = []
        for row in xml.child("sheetData")?.list("row") ?? [] {
            guard rows.count <= maxRows else { throw SIQError(message:"Не больше 5000 строк.") }
            var values: [String] = []
            for cell in row.list("c") {
                let letters = (cell.attributes["r"] ?? "").prefix { $0.isLetter }.uppercased()
                var column = 0
                for char in letters.utf8 { guard char >= 65 && char <= 90 else { throw SIQError(message:"Неверный адрес ячейки") }; column = column*26+Int(char-64); guard column <= 40 else { throw SIQError(message:"В листе больше 40 столбцов") } }
                let index = column > 0 ? column-1 : values.count
                guard index < 40 else { throw SIQError(message:"В листе больше 40 столбцов") }
                while values.count <= index { values.append("") }
                let value = cell.child("v")?.value ?? ""
                if cell.child("f") != nil { formulaRows.insert(rows.count); values[index] = ""; continue }
                if cell.attributes["t"] == "s" { guard let i = Int(value), shared.indices.contains(i) else { throw SIQError(message:"Повреждённая ссылка на строку XLSX") }; values[index] = shared[i] }
                else if cell.attributes["t"] == "inlineStr" { values[index] = cell.child("is").map(text) ?? "" }
                else { values[index] = value }
            }
            rows.append(values)
        }
        if formulaRows.contains(0) { throw SIQError(message:"В заголовке таблицы есть формула. Замените её текстом.") }
        var result = try table(rows,formulaRows:formulaRows)
        result.warnings.append("Лист: "+(sheet.attributes["name"] ?? "1")+". Читается первый видимый лист; формулы не вычисляются. Даты лучше заранее преобразовать в текст.")
        return result
    }
}
extension QuestionBank {
    func importQuestions(_ questions: [Question],origin: String) throws -> (entries:[BankEntry],added:Int) {
        var known = Dictionary(entries.compactMap { e in e.originKey.map { ($0,e) } },uniquingKeysWith:{ first,_ in first })
        var selected: [BankEntry] = []; var added = 0
        for q in questions {
            var canonical = q; canonical.id = UUID(uuidString:"00000000-0000-0000-0000-000000000000")!; canonical.bankEntryID = nil
            canonical.sequenceItems = canonical.sequenceItems?.map { item in var copy = item; copy.id = canonical.id; return copy }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let key = "bulk:"+SHA256.hash(data:try encoder.encode(canonical)).map { String(format:"%02x",$0) }.joined()
            if let old = known[key] { if !selected.contains(where:{ $0.id == old.id }) { selected.append(old) }; continue }
            let entry = try save(q,assets:[:],origin:origin,originKey:key); known[key] = entry; selected.append(entry); added += 1
        }
        return (selected,added)
    }
}

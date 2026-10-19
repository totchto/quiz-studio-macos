import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Darwin
import CryptoKit

struct SIQError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
// Read entries directly into bounded buffers: archive paths are never extracted to disk.
final class SIQArchive {
    private let library: UnsafeMutableRawPointer
    init() throws {
        guard let lib = dlopen("/usr/lib/libarchive.2.dylib",RTLD_NOW|RTLD_LOCAL) else { throw SIQError(message:"Не удалось открыть системный модуль ZIP.") }
        library = lib
    }
    deinit { dlclose(library) }
    private func symbol<T>(_ name: String,as type: T.Type) throws -> T {
        guard let address = dlsym(library,name) else { throw SIQError(message:"Недоступна функция ZIP: "+name) }
        return unsafeBitCast(address,to:T.self)
    }
    static func key(_ path: String) throws -> String {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains("\0"), !decoded.contains(":"), !decoded.split(separator:"/",omittingEmptySubsequences:false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw SIQError(message:"В архиве обнаружен недопустимый путь.") }
        return decoded.precomposedStringWithCanonicalMapping
    }
    func read(_ url: URL) throws -> [String: Data] {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 512*1024*1024 else { throw SIQError(message:"Пак пуст или больше 512 МБ.") }
        typealias New = @convention(c) () -> OpaquePointer?
        typealias Unary = @convention(c) (OpaquePointer?) -> Int32
        typealias Open = @convention(c) (OpaquePointer?,UnsafePointer<CChar>?,Int) -> Int32
        typealias Next = @convention(c) (OpaquePointer?,UnsafeMutablePointer<OpaquePointer?>?) -> Int32
        typealias Path = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        typealias Size = @convention(c) (OpaquePointer?) -> Int64
        typealias Kind = @convention(c) (OpaquePointer?) -> UInt32
        typealias Read = @convention(c) (OpaquePointer?,UnsafeMutableRawPointer?,Int) -> Int
        let create = try symbol("archive_read_new",as:New.self)
        let support = try symbol("archive_read_support_format_zip",as:Unary.self)
        let open = try symbol("archive_read_open_filename",as:Open.self)
        let next = try symbol("archive_read_next_header",as:Next.self)
        let path = try symbol("archive_entry_pathname_utf8",as:Path.self)
        let rawPath = try symbol("archive_entry_pathname",as:Path.self)
        let entrySize = try symbol("archive_entry_size",as:Size.self)
        let kind = try symbol("archive_entry_filetype",as:Kind.self)
        let link = try symbol("archive_entry_symlink",as:Path.self)
        let hardlink = try symbol("archive_entry_hardlink",as:Path.self)
        let encrypted = try symbol("archive_entry_is_encrypted",as:Unary.self)
        let read = try symbol("archive_read_data",as:Read.self)
        let free = try symbol("archive_read_free",as:Unary.self)
        guard let archive = create() else { throw SIQError(message:"Не удалось открыть ZIP.") }
        defer { _ = free(archive) }
        _ = support(archive)
        guard url.path.withCString({ open(archive,$0,64*1024) }) == 0 else { throw SIQError(message:"Файл не является читаемым паком .siq (ZIP).") }
        var result: [String: Data] = [:]; var total = 0; var count = 0
        var buffer = [UInt8](repeating:0,count:64*1024)
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = next(archive,&entry)
            if status == 1 { break }
            guard status >= -20, let entry else { throw SIQError(message:"Архив повреждён или имеет неподдерживаемое сжатие.") }
            count += 1
            guard count <= 20000, link(entry) == nil, hardlink(entry) == nil, encrypted(entry) == 0 else { throw SIQError(message:"Пак содержит ссылки, шифрование или слишком много файлов.") }
            guard let namePointer = path(entry) ?? rawPath(entry), let name = String(validatingUTF8:namePointer) else { throw SIQError(message:"Не удалось прочитать имя вложения в паке.") }
            if kind(entry) == 0o040000 { _ = try Self.key((name.hasSuffix("/") ? String(name.dropLast()) : name)); continue }
            guard kind(entry) == 0o100000 || kind(entry) == 0 else { throw SIQError(message:"В паке найден неподдерживаемый тип файла.") }
            let key = try Self.key(name)
            guard result[key] == nil else { throw SIQError(message:"Неоднозначные имена вложений: "+key) }
            let expected = entrySize(entry)
            guard expected >= 0 && expected <= 128*1024*1024 else { throw SIQError(message:"Одно из вложений больше 128 МБ.") }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let n = buffer.withUnsafeMutableBytes { read(archive,$0.baseAddress,$0.count) }
                if n == 0 { break }
                guard n > 0 else { throw SIQError(message:"Не удалось распаковать вложение: "+key) }
                total += n
                guard total <= 512*1024*1024 && data.count+n <= 128*1024*1024 else { throw SIQError(message:"Распакованный пак слишком большой.") }
                data.append(contentsOf:buffer.prefix(n))
            }
            guard data.count == expected else { throw SIQError(message:"Неполное вложение: "+key) }
            result[key] = data
        }
        return result
    }
}

final class SIQNode {
    let name: String
    let attributes: [String:String]
    var text = ""
    var children: [SIQNode] = []
    init(_ name: String,_ attributes: [String:String]) { self.name = name; self.attributes = attributes }
    func child(_ name: String) -> SIQNode? { children.first { $0.name == name } }
    func list(_ name: String) -> [SIQNode] { children.filter { $0.name == name } }
    var value: String { (text + children.map(\.value).joined(separator:"\n")).trimmingCharacters(in:.whitespacesAndNewlines) }
}
final class SIQXML: NSObject, XMLParserDelegate {
    var root: SIQNode?
    private var stack: [SIQNode] = []
    private var nodes = 0
    private var invalid = false
    func parse(_ data: Data) throws -> SIQNode {
        guard data.count <= 16*1024*1024 else { throw SIQError(message:"Описание пака слишком большое.") }
        let screen = String(decoding:data.filter { $0 != 0 },as:UTF8.self).uppercased()
        guard !screen.contains("<!DOCTYPE"), !screen.contains("<!ENTITY") else { throw SIQError(message:"XML с DTD и внешними сущностями не поддерживается.") }
        let parser = XMLParser(data:data); parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse(), !invalid, let root, root.name == "package" else { throw SIQError(message:"Не удалось прочитать content.xml: "+(parser.parserError?.localizedDescription ?? "нет описания пака")) }
        return root
    }
    func parser(_ parser: XMLParser,didStartElement elementName: String,namespaceURI: String?,qualifiedName qName: String?,attributes attributeDict: [String:String]) {
        nodes += 1
        if stack.count >= 128 || nodes > 200000 { invalid = true; parser.abortParsing(); return }
        let node = SIQNode(elementName,attributeDict)
        if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node } else { invalid = true; parser.abortParsing() }
        stack.append(node)
    }
    func parser(_ parser: XMLParser,foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser,foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding:CDATABlock,as:UTF8.self) }
    func parser(_ parser: XMLParser,didEndElement elementName: String,namespaceURI: String?,qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
}
struct SIQAttachment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var originalName: String
    var type: String
    var answer: Bool
}
extension Question {
    func images(answer: Bool) -> [String] {
        if answer, explanationImage != nil || !(explanationGallery ?? []).isEmpty { return [explanationImage].compactMap{$0}+(explanationGallery ?? []) }
        return [image].compactMap{$0}+(imageGallery ?? [])
    }
}
struct SIQImportResult {
    var quiz: Quiz
    var assets: [String:Data]
    var warnings: [String]
    var sourceFingerprint: String
    var originalRounds: Int
    var themes: Int
    var questionCount: Int { quiz.rounds.reduce(0) { $0+$1.questions.count } }
}
enum SIQImporter {
    static func load(_ url: URL,themesAsRounds: Bool = false) throws -> SIQImportResult {
        let files = try SIQArchive().read(url)
        guard let xml = files["content.xml"] else { throw SIQError(message:"В архиве нет content.xml. Это не пак SIGame.") }
        let root = try SIQXML().parse(xml)
        let version = root.attributes["version"] ?? "3"
        guard let number = Double(version), number >= 3 && number < 6 else { throw SIQError(message:"Поддерживаются паки формата 3–5. Версия этого пака: "+version) }
        var quiz = Quiz(); quiz.title = root.attributes["name"] ?? url.deletingPathExtension().lastPathComponent; quiz.rounds = []; quiz.teams = []
        var assets: [String:Data] = [:]; var mapped: [String:String] = [:]; var warnings: [String] = []
        var themesCount = 0; var count = 0
        func warn(_ text: String) { if warnings.count < 2000 { warnings.append(text) } }
        func info(_ node: SIQNode) -> String {
            guard let info = node.child("info") else { return "" }
            return info.children.compactMap { c in c.value.isEmpty ? nil : (c.name == "authors" ? "Авторы: " : c.name == "sources" ? "Источники: " : "")+c.value }.joined(separator:"\n")
        }
        func asset(_ node: SIQNode,type: String,context: String) -> SIQAttachment? {
            var reference = node.value
            let isRef = node.name == "atom" ? reference.hasPrefix("@") : node.attributes["isRef"]?.lowercased() == "true"
            guard isRef else { warn(context+": внешнее или неподдерживаемое медиа не загружено — "+reference); return nil }
            if reference.hasPrefix("@") { reference.removeFirst() }
            let category = type == "image" ? "Images" : type == "video" ? "Video" : "Audio"
            guard let key = try? SIQArchive.key(category+"/"+reference), let data = files[key] else { warn(context+": не найдено вложение "+category+"/"+reference); return nil }
            let name: String
            if let cached = mapped[key] { name = cached }
            else {
                let ext = (reference as NSString).pathExtension.lowercased()
                let safeExt = ext.range(of:"^[a-z0-9]{1,12}$",options:.regularExpression) != nil ? ext : "dat"
                name = UUID().uuidString+"."+safeExt; mapped[key] = name; assets[name] = data
            }
            return SIQAttachment(name:name,originalName:reference,type:type,answer:false)
        }
        let rounds = root.child("rounds")?.list("round") ?? []
        for (ri,original) in rounds.enumerated() {
            try Task.checkCancellation()
            let roundName = original.attributes["name"] ?? "Раунд \(ri+1)"
            let originalFinal = original.attributes["type"] == "final"
            if originalFinal { warn(roundName+": финал импортирован как обычный раунд; выбор тем и ставки не воспроизводятся.") }
            var round = Round(); round.title = roundName; round.questions = []; round.standings = true; round.hostNotes = info(original)
            let themes = original.child("themes")?.list("theme") ?? []
            for theme in themes {
                themesCount += 1
                let themeName = theme.attributes["name"] ?? "Тема \(themesCount)"
                if themesAsRounds { round = Round(); round.title = roundName+" · "+themeName; round.questions = []; round.standings = true; round.hostNotes = [info(original),info(theme)].filter{ !$0.isEmpty }.joined(separator:"\n") }
                for (qi,item) in (theme.child("questions")?.list("question") ?? []).enumerated() {
                    count += 1; guard count <= 10000 else { throw SIQError(message:"В паке больше 10 000 вопросов.") }
                    let context = roundName+" / "+themeName+" / \(qi+1)"
                    let params = item.child("params")?.list("param") ?? []
                    let right = item.child("right")?.list("answer").map(\.value).filter{ !$0.isEmpty } ?? []
                    var q = Question(); q.tags = [themeName]; q.answer = right.first ?? ""; q.acceptedAnswers = right
                    q.hostNotes = ["Импорт .siq · Тема: "+themeName,"Исходная стоимость: "+(item.attributes["price"] ?? "не указана"),info(root),info(theme),info(item)].filter{ !$0.isEmpty }.joined(separator:"\n")
                    var questionItems = params.first { $0.attributes["name"] == "question" }?.list("item") ?? []
                    var answerItems = params.first { $0.attributes["name"] == "answer" }?.list("item") ?? []
                    if let scenario = item.child("scenario") {
                        var answerPart = false
                        for atom in scenario.list("atom") {
                            if atom.attributes["type"] == "marker" { answerPart = true; continue }
                            if answerPart { answerItems.append(atom) } else { questionItems.append(atom) }
                        }
                    }
                    var texts: [String] = []; var explanations: [String] = []; var attachments: [SIQAttachment] = []
                    for (isAnswer,nodes) in [(false,questionItems),(true,answerItems)] {
                        for node in nodes {
                            let type = node.attributes["type"] ?? "text"
                            if type == "text" { if !node.value.isEmpty { if isAnswer { explanations.append(node.value) } else { texts.append(node.value) } } }
                            else if type == "say" { q.hostNotes = (q.hostNotes ?? "")+"\nРеплика ведущего: "+node.value }
                            else if ["image","audio","voice","video"].contains(type) {
                                if var attachment = asset(node,type:type == "voice" ? "audio" : type,context:context) { attachment.answer = isAnswer; attachments.append(attachment) } else { q.siqReviewRequired = true }
                                if node.attributes["duration"] != nil || node.attributes["time"] != nil || node.attributes["waitForFinish"] != nil { warn(context+": точное расписание показа медиа проверьте в редакторе.") }
                            } else { q.siqReviewRequired = true; warn(context+": неподдерживаемое содержимое "+type+" сохранено в заметках."); q.hostNotes = (q.hostNotes ?? "")+"\n"+type+": "+node.value }
                        }
                    }
                    q.text = themeName+(texts.isEmpty ? "" : "\n\n"+texts.joined(separator:"\n\n"))
                    if let comments = item.child("info")?.child("comments")?.value, !comments.isEmpty { explanations.append(comments) }
                    q.explanation = explanations.isEmpty ? nil : explanations.joined(separator:"\n\n")
                    for isAnswer in [false,true] {
                        let images = attachments.filter { $0.answer == isAnswer && $0.type == "image" }.map(\.name)
                        let media = attachments.filter { $0.answer == isAnswer && $0.type != "image" }
                        if isAnswer { q.explanationImage = images.first; q.explanationGallery = Array(images.dropFirst()); q.explanationMedia = media.first?.name }
                        else { q.image = images.first; q.imageGallery = Array(images.dropFirst()); q.media = media.first?.name; q.audioOnly = media.first?.type == "audio" }
                        if images.count > 1 { warn(context+": \(images.count) изображений будут показаны вместе в галерее, без исходной последовательности.") }
                        if media.count > 1 { q.siqReviewRequired = true; warn(context+": несколько аудио/видеофрагментов; выбран первый, остальные доступны в редакторе.") }
                    }
                    q.siqAttachments = attachments
                    let optionNode = params.first { $0.attributes["name"] == "answerOptions" }
                    let options = optionNode?.list("param") ?? []
                    if !options.isEmpty {
                        let labels = options.map { $0.list("item").map(\.value).joined(separator:"\n") }
                        if options.count == 4, right.count == 1, let selected = options.firstIndex(where:{ $0.attributes["name"] == right[0] }), labels.allSatisfy({ !$0.isEmpty }), options.allSatisfy({ $0.list("item").allSatisfy{ ($0.attributes["type"] ?? "text") == "text" } }) {
                            q.kind = "Один из четырёх"; q.choices = labels; q.selectedChoice = selected; q.answer = labels[selected]; q.acceptedAnswers = [q.answer]
                        } else {
                            q.siqReviewRequired = true
                            let resolved = right.map { answer in options.firstIndex(where:{ $0.attributes["name"] == answer }).map { labels[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? answer }
                            q.answer = resolved.first ?? ""; q.acceptedAnswers = resolved
                            q.text += "\n\n"+zip(options,labels).map { ($0.0.attributes["name"] ?? "")+": "+$0.1 }.joined(separator:"\n"); warn(context+": варианты ответа требуют проверки; вопрос оставлен открытым.") }
                    }
                    let type = item.attributes["type"] ?? item.child("type")?.attributes["name"] ?? "simple"
                    if !["simple","","default"].contains(type) { warn(context+": механика «"+type+"» заменена обычным вопросом.") }
                    if let script = item.child("script") { q.siqReviewRequired = true; warn(context+": пользовательский сценарий не исполняется."); q.hostNotes = (q.hostNotes ?? "")+"\nСценарий: "+script.value }
                    if q.answer.isEmpty { warn(context+": не указан правильный ответ. Заполните его перед игрой.") }
                    if questionItems.isEmpty { q.siqReviewRequired = true; warn(context+": отсутствует содержимое вопроса. Проверьте перед игрой.") }
                    round.questions.append(q)
                }
                if themesAsRounds && !round.questions.isEmpty { quiz.rounds.append(round) }
            }
            if !themesAsRounds && !round.questions.isEmpty { quiz.rounds.append(round) }
        }
        guard !quiz.rounds.isEmpty else { throw SIQError(message:"В паке нет вопросов для импорта.") }
        let summary = "Источник: "+url.lastPathComponent+"\nФормат .siq: "+version+"\n"+info(root)+"\nИсходные раунды: \(rounds.count), темы: \(themesCount), вопросы: \(count).\nСтоимость сохранена в заметках. Баллы начисляются по правилам Квиз Студии.\n"+warnings.joined(separator:"\n")
        quiz.importNotes = summary
        var hash = SHA256()
        for key in files.keys.sorted() { hash.update(data:Data(key.utf8)); hash.update(data:Data([0])); hash.update(data:files[key]!) }
        let fingerprint = hash.finalize().map { String(format:"%02x",$0) }.joined()
        return SIQImportResult(quiz:quiz,assets:assets,warnings:warnings,sourceFingerprint:fingerprint,originalRounds:rounds.count,themes:themesCount)
    }
}

struct SIQImageGallery: View {
    let names: [String]
    let studio: Studio
    var body: some View {
        GeometryReader { geometry in
            let columns = min(3,max(1,names.count == 2 ? 2 : Int(ceil(sqrt(Double(names.count))))))
            let rows = max(1,Int(ceil(Double(names.count)/Double(columns))))
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:columns),spacing:8) {
                ForEach(Array(names.enumerated()),id:\.offset) { _,name in
                    if let url = studio.asset(name) { AnimatedQuizImage(url:url).frame(height:max(40,(geometry.size.height-Double(rows-1)*8)/Double(rows))) }
                }
            }
        }
    }
}

extension Studio {
    func chooseSIQ(_ supplied: URL? = nil) {
        guard !playing else { status = "Сначала завершите игру"; return }
        let source: URL
        if let supplied { source = supplied }
        else {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(importedAs:"local.quizstudio.siq")]; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }; source = url
        }
        if screen == .editor {
            let alert = NSAlert(); alert.messageText = "Сохранить текущий квиз перед импортом?"
            alert.addButton(withTitle:"Сохранить"); alert.addButton(withTitle:"Отмена"); alert.addButton(withTitle:"Импортировать без сохранения")
            let answer = alert.runModal()
            if answer == .alertSecondButtonReturn { return }
            if answer == .alertFirstButtonReturn && !save() { return }
        }
        siqSource = source; showSIQImport = true
    }
    func saveSIQImport(_ result: SIQImportResult,to url: URL) throws {
        guard url.pathExtension.lowercased() == "quiz" else { throw SIQError(message:"Сохраните импортированный квиз с расширением .quiz.") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let added = try questionBank.importSIQ(result)
        var quiz = result.quiz; quiz.bankHistoryID = UUID()
        var entries: [String:UUID] = [:]
        for entry in questionBank.entries { if let key = entry.originKey { entries[key] = entry.id } }
        var ordinal = 0
        for ri in quiz.rounds.indices { for qi in quiz.rounds[ri].questions.indices {
            quiz.rounds[ri].questions[qi].bankEntryID = entries[result.sourceFingerprint+"/\(ordinal)"]; ordinal += 1
        } }
        try JSONEncoder().encode(QuizFile(quiz:quiz,assets:result.assets)).write(to:url,options:.atomic)
        guard load(url) else { throw SIQError(message:status) }
        screen = .editor; recordBankUsage(played:false); autosave()
        status = "Импортировано \(result.questionCount) вопросов из .siq; в банк добавлено: \(added)"

    }
}
struct SIQImportView: View {
    @ObservedObject var studio: Studio
    let source: URL
    @Environment(\.dismiss) var dismiss
    @State private var themesAsRounds = false
    @State private var result: SIQImportResult?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Импорт пака «Своя игра»").font(.title2.bold())
            Text(source.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            Picker("Структура",selection:$themesAsRounds) { Text("Раунды как в паке").tag(false); Text("Каждая тема — отдельный раунд").tag(true) }.pickerStyle(.segmented)
            if busy { ProgressView("Читаем вопросы и вложения…") }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if let result {
                Text(result.quiz.title).font(.title3.bold())
                Text("Раундов: \(result.quiz.rounds.count) · Тем: \(result.themes) · Вопросов: \(result.questionCount) · Медиафайлов: \(result.assets.count)")
                Text("Вопросы идут по порядку тем. Стоимость сохраняется в заметках, баллы начисляются по правилам Квиз Студии. Ставки, выбор клеток и специальные сценарии «Своей игры» не воспроизводятся.").font(.callout)
                if result.warnings.isEmpty { Label("Вопросы и вложения прочитаны без замечаний",systemImage:"checkmark.circle").foregroundStyle(.green) }
                else {
                    Text("Замечания к импорту: \(result.warnings.count)").bold().foregroundStyle(.orange)
                    ScrollView { VStack(alignment:.leading,spacing:7) { ForEach(Array(result.warnings.enumerated()),id:\.offset) { _,text in Text("• "+text).font(.caption).frame(maxWidth:.infinity,alignment:.leading) } }.textSelection(.enabled) }.frame(height:220)
                }
                Text("Вопросы также сохранятся в локальном банке. Повторный импорт не создаёт копии. Создастся новый редактируемый файл .quiz. Исходный пак останется без изменений. Отчёт импорта сохраняется в квизе.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Только в банк вопросов") {
                    guard let result else { return }
                    do { let count = try studio.questionBank.importSIQ(result); studio.status = "В банк добавлено вопросов: \(count)"; dismiss() } catch { failure = error.localizedDescription }
                }.disabled(busy || result == nil)
                Spacer()
                Button("Сохранить .quiz и открыть редактор") {
                    guard let result else { return }
                    let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs:"local.quizstudio.quiz",conformingTo:.data)]; panel.nameFieldStringValue = result.quiz.title.replacingOccurrences(of:"/",with:"-")+".quiz"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { try studio.saveSIQImport(result,to:url); dismiss() } catch { failure = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(busy || result == nil)
            }
        }.padding(26).frame(width:760)
        .task(id:themesAsRounds) {
            busy = true; failure = nil; result = nil
            let url = source; let split = themesAsRounds
            do {
                let task = Task.detached(priority:.userInitiated) { try SIQImporter.load(url,themesAsRounds:split) }
                let value = try await withTaskCancellationHandler(operation:{ try await task.value },onCancel:{ task.cancel() })
                guard !Task.isCancelled else { return }; result = value; busy = false
            } catch { if !Task.isCancelled { failure = error.localizedDescription; busy = false } }
        }
    }
}

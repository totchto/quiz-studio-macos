import SwiftUI
import CryptoKit

extension Question {
    var bankAssets: [String] {
        Array(Set([image,media,explanationImage,explanationMedia].compactMap { $0 } + (imageGallery ?? []) + (explanationGallery ?? []) + (siqAttachments ?? []).map(\.name))).sorted()
    }
    var bankCategories: [String] {
        var result = [kind == "Один из четырёх" ? "4 варианта" : kind == "Сопоставление" ? "Сопоставление" : "Открытые вопросы"]
        if media != nil || explanationMedia != nil || (siqAttachments ?? []).contains(where: { $0.type == "audio" || $0.type == "video" }) { result.insert("Аудио / видео",at:0) }
        return result
    }
}
struct BankEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: Question
    var origin: String?
    var originKey: String?
    var updated = Date()
    var archived = false
    var history: [BankUse]? = nil
}
struct BankRecord: Codable { var entry: BankEntry; var assets: [String:Data] }
@MainActor final class QuestionBank: ObservableObject {
    let root: URL
    @Published var entries: [BankEntry] = []
    @Published var message = ""
    init(root: URL) {
        self.root = root
        do {
            guard FileManager.default.fileExists(atPath:root.path) else { return }
            for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where url.pathExtension == "bankitem" {
                do {
                    var entry = try JSONDecoder().decode(BankRecord.self,from:Data(contentsOf:url)).entry
                    if entry.question.tags == nil, let theme = entry.question.hostNotes?.components(separatedBy:"\n").first(where:{ $0.hasPrefix("Импорт .siq · Тема: ") }) { entry.question.tags = [String(theme.dropFirst("Импорт .siq · Тема: ".count))] }
                    entries.append(entry)
                }
                catch { message = "Не удалось прочитать некоторые записи банка. Файлы сохранены: " + error.localizedDescription }
            }
            entries.sort { $0.updated > $1.updated }
        } catch { message = error.localizedDescription }
    }
    func record(_ entry: BankEntry) throws -> BankRecord {
        try JSONDecoder().decode(BankRecord.self,from:Data(contentsOf:root.appendingPathComponent(entry.id.uuidString+".bankitem")))
    }
    @discardableResult func save(_ question: Question,assets: [String:Data],existing: BankEntry? = nil,origin: String? = nil,originKey: String? = nil) throws -> BankEntry {
        let names = question.bankAssets
        guard names.allSatisfy({ assets[$0] != nil && $0 == ($0 as NSString).lastPathComponent && !$0.contains("\\") && $0 != "." && $0 != ".." }) else { throw SIQError(message:"Не удалось сохранить вопрос: отсутствует медиафайл.") }
        var entry = existing ?? BankEntry(question:question,origin:origin,originKey:originKey)
        entry.question = question; entry.updated = Date()
        let record = BankRecord(entry:entry,assets:assets.filter { names.contains($0.key) })
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(record).write(to:root.appendingPathComponent(entry.id.uuidString+".bankitem"),options:.atomic)
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry } else { entries.append(entry) }
        entries.sort { $0.updated > $1.updated }
        return entry
    }
    func setArchived(_ entry: BankEntry,_ value: Bool) throws {
        var updated = entry; updated.archived = value
        let record = try record(entry)
        _ = try save(entry.question,assets:record.assets,existing:updated)
    }
    @discardableResult func importSIQ(_ result: SIQImportResult) throws -> Int {
        var added = 0
        let known = Set(entries.compactMap(\.originKey))
        var ordinal = 0
        for round in result.quiz.rounds { for q in round.questions {
            let key = result.sourceFingerprint+"/\(ordinal)"; ordinal += 1
            guard !known.contains(key) else { continue }
            _ = try save(q,assets:result.assets,origin:result.quiz.title+" · "+round.title,originKey:key); added += 1
        } }
        message = "Добавлено в банк: \(added). Уже сохранённые вопросы пропущены."
        return added
    }
}
extension Studio {
    func bankQuestionAssets(_ q: Question) throws -> [String:Data] {
        var assets: [String:Data] = [:]
        for name in q.bankAssets { guard let url = asset(name) else { throw CocoaError(.fileNoSuchFile) }; assets[name] = try Data(contentsOf:url) }
        return assets
    }
    func saveSelectedToBank() {
        guard let q = selectedQuestion else { return }
        do { let entry = try questionBank.save(q,assets:bankQuestionAssets(q),origin:quiz.title); questionBinding(q.id).wrappedValue.bankEntryID = entry.id; status = "Вопрос сохранён в банк" }
        catch { status = "Ошибка банка: "+error.localizedDescription }
    }
    func insertBankQuestions(_ entries: [BankEntry]) throws {
        guard quiz.rounds.indices.contains(roundIndex) else { throw SIQError(message:"Сначала создайте раунд.") }
        // Validate and copy everything before changing the quiz. Each insertion gets independent IDs and media names.
        var questions: [Question] = []
        let workspace = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("QuizStudio-Bank-"+UUID().uuidString)
        let mediaFolder = workspace.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:mediaFolder,withIntermediateDirectories:true)
        for entry in entries {
            let record = try questionBank.record(entry)
            var mapping: [String:String] = [:]
            for name in record.entry.question.bankAssets {
                guard let data = record.assets[name] else { throw CocoaError(.fileNoSuchFile) }
                let ext = (name as NSString).pathExtension
                let newName = UUID().uuidString+(ext.isEmpty ? "" : "."+ext)
                try data.write(to:mediaFolder.appendingPathComponent(newName),options:.atomic); mapping[name] = newName
            }
            var q = record.entry.question
            q.image = q.image.map { mapping[$0] ?? $0 }; q.media = q.media.map { mapping[$0] ?? $0 }
            q.explanationImage = q.explanationImage.map { mapping[$0] ?? $0 }; q.explanationMedia = q.explanationMedia.map { mapping[$0] ?? $0 }
            q.imageGallery = q.imageGallery?.map { mapping[$0] ?? $0 }; q.explanationGallery = q.explanationGallery?.map { mapping[$0] ?? $0 }
            q.siqAttachments = q.siqAttachments?.map { item in var copy = item; copy.name = mapping[item.name] ?? item.name; return copy }
            q.id = UUID(); q.bankEntryID = entry.id
            q.matchPairs = q.matchPairs?.map { pair in var copy = pair; copy.id = UUID(); return copy }
            q.siqAttachments = q.siqAttachments?.map { item in var copy = item; copy.id = UUID(); return copy }
            questions.append(q)
        }
        folder = workspace
        let target = min(max(0,questionIndex+1),quiz.rounds[roundIndex].questions.count)
        quiz.rounds[roundIndex].questions.insert(contentsOf:questions,at:target)
        questionIndex = target; autosave(); status = "Добавлено вопросов из банка: \(questions.count)"
    }
}

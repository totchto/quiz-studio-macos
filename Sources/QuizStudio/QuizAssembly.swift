import SwiftUI
import UniformTypeIdentifiers

struct QuizAssemblyRules {
    var rounds = 3
    var perRound = 10
    var tags: [String] = []
    var kind = "Любой тип"
    var difficulty = "Любая сложность"
    var unusedOnly = true
    func candidates(_ entries: [BankEntry]) -> [BankEntry] {
        entries.filter { entry in
            !entry.archived && entry.question.issues.isEmpty && (kind == "Любой тип" || entry.question.kind == kind) && (difficulty == "Любая сложность" || entry.question.difficulty == difficulty) && (!unusedOnly || (entry.history ?? []).isEmpty) && (tags.isEmpty || tags.contains { tag in (entry.question.tags ?? []).contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } })
        }
    }
    func select(_ entries: [BankEntry]) throws -> [BankEntry] {
        guard (1...20).contains(rounds), (1...50).contains(perRound) else { throw SIQError(message:"Выберите 1–20 раундов по 1–50 вопросов.") }
        let needed = rounds*perRound; let eligible = candidates(entries)
        guard eligible.count >= needed else { throw SIQError(message:"Подходит вопросов: \(eligible.count), нужно: \(needed). Ослабьте условия или уменьшите число вопросов.") }
        return Array(eligible.shuffled().prefix(needed))
    }
}
extension Studio {
    func assembleQuiz(_ selected: [BankEntry],rules: QuizAssemblyRules,title: String) throws {
        guard (1...20).contains(rules.rounds), (1...50).contains(rules.perRound), selected.count == rules.rounds*rules.perRound, Set(selected.map(\.id)).count == selected.count, selected.allSatisfy({ !$0.archived && $0.question.issues.isEmpty }) else { throw SIQError(message:"Подборка не заполнена или содержит повторные/незавершённые вопросы.") }
        let copied = try copyBankQuestions(selected)
        var result = Quiz(); result.title = title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "Квиз из банка" : title; result.rounds = []
        for ri in 0..<rules.rounds {
            var round = Round(); round.title = "Раунд \(ri+1)"; round.questions = Array(copied.questions[(ri*rules.perRound)..<((ri+1)*rules.perRound)])
            result.rounds.append(round)
        }
        quiz = result; folder = copied.folder; documentURL = nil; registeredFontName = nil; screen = .editor; roundIndex = 0; questionIndex = 0; undoHistory = []; editorSelection = []; autosave()
        status = "Квиз собран из банка: \(rules.rounds) раундов, \(selected.count) вопросов. Сохраните его в .quiz."
    }
    func confirmReplaceForAssembly() -> Bool {
        let hasDraft = documentURL == nil && quiz.rounds.flatMap(\.questions).contains { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        guard screen == .editor || hasDraft else { return true }
        let alert = NSAlert(); alert.messageText = "Сохранить текущий квиз перед созданием нового?"
        alert.addButton(withTitle:"Сохранить"); alert.addButton(withTitle:"Отмена"); alert.addButton(withTitle:"Создать без сохранения")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertThirdButtonReturn: return true; default: return false }
    }
}
struct QuizAssemblyView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var bank: QuestionBank
    @Environment(\.dismiss) var dismiss
    @State private var rules = QuizAssemblyRules()
    @State private var title = "Квиз из банка"
    @State private var tags = ""
    @State private var chosen: [BankEntry] = []
    @State private var error: String?
    init(studio: Studio) { self.studio = studio; bank = studio.questionBank }
    var effective: QuizAssemblyRules { var copy = rules; copy.tags = Question.cleanTags(tags); return copy }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("Собрать квиз из банка").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            TextField("Название квиза",text:$title)
            HStack { Stepper("Раундов: \(rules.rounds)",value:$rules.rounds,in:1...20); Stepper("Вопросов в раунде: \(rules.perRound)",value:$rules.perRound,in:1...50) }
            TextField("Темы через запятую (подойдёт любая из указанных)",text:$tags)
            HStack {
                Picker("Тип",selection:$rules.kind) { ForEach(["Любой тип"]+Question.kinds,id:\.self) { Text($0) } }
                Picker("Сложность",selection:$rules.difficulty) { ForEach(["Любая сложность","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) } }
            }
            Toggle("Исключить вопросы, уже использованные в сохранённых квизах или играх",isOn:$rules.unusedOnly)
            Text("Подходит: \(effective.candidates(bank.entries).count) · Нужно: \(rules.rounds*rules.perRound). Архивные и незавершённые записи исключены. Повторений одной записи внутри подборки не будет.").font(.caption).foregroundStyle(.secondary)
            HStack { Button(chosen.isEmpty ? "Подобрать вопросы" : "Переподобрать") { do { chosen = try effective.select(bank.entries); error = nil } catch { chosen = []; self.error = error.localizedDescription } }.buttonStyle(.borderedProminent); Spacer() }
            if let error { Text(error).foregroundStyle(.red) }
            List(Array(chosen.enumerated()),id:\.element.id) { index,entry in
                HStack {
                    VStack(alignment:.leading,spacing:4) { Text("Раунд \(index/rules.perRound+1) · Вопрос \(index%rules.perRound+1)").font(.caption).foregroundStyle(.secondary); Text(entry.question.text).lineLimit(3); Text(entry.question.correctAnswer).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Заменить") {
                        if let replacement = effective.candidates(bank.entries).filter({ candidate in !chosen.contains { $0.id == candidate.id } }).randomElement() { chosen[index] = replacement; error = nil } else { error = "Других вопросов по этим условиям нет." }
                    }
                }
            }
            HStack { Text("Предпросмотр подборки не отмечает вопросы использованными. Медиа и ответы переносятся вместе с вопросами.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Создать квиз") {
                guard studio.confirmReplaceForAssembly() else { return }
                do { try studio.assembleQuiz(chosen,rules:effective,title:title); studio.showQuestionBank = false; dismiss() } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(chosen.count != rules.rounds*rules.perRound) }
        }.padding(24).frame(width:880,height:710)
        .onChange(of:rules.rounds) { _,_ in chosen = [] }.onChange(of:rules.perRound) { _,_ in chosen = [] }.onChange(of:rules.kind) { _,_ in chosen = [] }.onChange(of:rules.difficulty) { _,_ in chosen = [] }.onChange(of:rules.unusedOnly) { _,_ in chosen = [] }.onChange(of:tags) { _,_ in chosen = [] }
    }
}
struct BulkQuestionImportView: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var rows: [ImportedQuestionRow] = []
    @State private var warnings: [String] = []
    @State private var error: String?
    @State private var source = "Вставленный текст"
    @State private var busy = false
    @State private var intoQuiz = false
    @State private var importTask: Task<Void,Never>?
    var selected: [Question] { rows.filter(\.selected).map(\.question) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("Массовый импорт вопросов").font(.title2.bold()); Spacer(); Button("Закрыть") { importTask?.cancel(); dismiss() } }
            HStack { Button("Открыть XLSX / CSV / TSV / TXT…") {
                let panel = NSOpenPanel(); panel.allowedContentTypes = ["xlsx","csv","tsv","txt"].compactMap { UTType(filenameExtension:$0) }; panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }; source = url.lastPathComponent
                load { try QuestionTextImport.file(url) }
            }; Button("Шаблон CSV…") { saveTemplate() }; if busy { ProgressView().controlSize(.small) } }
            DisclosureGroup("Формат и ограничения") {
                Text("Таблица: заголовки Вопрос, Ответ, Объяснение, Тип, Вариант1…Вариант8, Правильные варианты (номера через запятую), Погрешность, События (через | в верном порядке), Темы, Сложность, Время. XLSX: первый видимый лист; формулы не вычисляются. Для сопоставления: столбец Пары, например Франция=Париж|Италия=Рим. Из Numbers экспортируйте XLSX/CSV.").font(.caption)
                Text("Текст: по строке «вопрос — ответ — объяснение» либо блоки с метками «Вопрос:», «Ответ:», «Объяснение:». До 5000 вопросов за импорт. Перед сохранением проверьте распознавание.").font(.caption)
            }
            HStack { Text("Или вставьте текст").bold(); Spacer(); Button("Распознать текст") { let input = text; source = "Вставленный текст"; load { try QuestionTextImport.parse(input) } }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || busy) }
            TextEditor(text:$text).frame(height:95).border(.quaternary)
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            HStack { Text("Распознано: \(rows.count), выбрано: \(selected.count)").font(.caption); Spacer(); Button("Выбрать заполненные") { for i in rows.indices { rows[i].selected = rows[i].issues.isEmpty } }; Button("Снять выбор") { for i in rows.indices { rows[i].selected = false } } }
            List($rows) { $row in
                HStack(alignment:.top) {
                    Toggle("Импортировать",isOn:$row.selected).labelsHidden()
                    VStack(alignment:.leading,spacing:4) {
                        Text("Строка \(row.line) · "+row.question.kind).font(.caption).foregroundStyle(.secondary)
                        TextField("Вопрос",text:$row.question.text)
                        Text("Ответ: "+row.question.correctAnswer).font(.caption).textSelection(.enabled)
                        if let explanation = row.question.explanation, !explanation.isEmpty { Text(explanation).font(.caption).foregroundStyle(.secondary) }
                        if !row.issues.isEmpty { Text(row.issues.joined(separator:"; ")).font(.caption).foregroundStyle(.orange) }
                    }
                }.padding(.vertical,4)
            }
            if studio.screen == .editor { Toggle("Также вставить выбранные вопросы в текущий раунд",isOn:$intoQuiz) }
            HStack {
                Text("Неполные выбранные записи сохранятся как черновики. Точные повторы импорта пропускаются.").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Добавить в банк (\(selected.count))") {
                    do {
                        let result = try studio.questionBank.importQuestions(selected,origin:source)
                        if intoQuiz && studio.screen == .editor { try studio.insertBankQuestions(result.entries) }
                        studio.status = "Импортировано в банк: \(result.added), повторов пропущено: \(selected.count-result.added)"; studio.questionBank.message = studio.status; dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || busy)
            }
        }.padding(22).frame(width:920,height:760).onDisappear { importTask?.cancel() }
    }
    func load(_ operation: @escaping @Sendable () throws -> QuestionImportResult) {
        importTask?.cancel(); busy = true; error = nil; rows = []; warnings = []
        importTask = Task {
            do {
                let worker = Task.detached(priority:.userInitiated) { try operation() }
                let result = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
                guard !Task.isCancelled else { return }; rows = result.rows; warnings = result.warnings; busy = false
                if rows.isEmpty { error = "Вопросы не найдены. Проверьте формат." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; busy = false } }
        }
    }
    func saveTemplate() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Шаблон вопросов.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sample = [["Вопрос","Ответ","Объяснение","Тип","Вариант1","Вариант2","Вариант3","Вариант4","Правильные варианты","Погрешность","События","Темы","Сложность","Время"],["Сколько планет в Солнечной системе?","8","Плутон относится к карликовым планетам.","Числовой ответ","","","","","","0","","космос","Лёгкий","30"],["Выберите чётные числа","","Делятся на два.","Несколько вариантов","2","3","4","5","1,3","","","математика","Лёгкий","30"],["Расположите события по времени","","","Порядок событий","","","","","","","Первый спутник|Первый человек в космосе|Высадка на Луну","космос","Средний","60"]]
        do { try ("\u{FEFF}"+GameArchive.csv(sample)).write(to:url,atomically:true,encoding:.utf8) } catch { self.error = error.localizedDescription }
    }
}

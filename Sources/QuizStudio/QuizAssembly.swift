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
struct QuizAssemblyRound: Identifiable {
    var id = UUID()
    var title: String
    var count: Int
    var tags: [String] = []
    var kind = "Любой тип"
    var difficulty = "Любая сложность"
    var questions: [BankEntry] = []
    func candidates(_ entries: [BankEntry],excluding: Set<UUID> = [],unusedOnly: Bool = false) -> [BankEntry] {
        entries.filter { entry in !excluding.contains(entry.id) && !entry.archived && entry.question.issues.isEmpty && (!unusedOnly || (entry.history ?? []).isEmpty) && (kind == "Любой тип" || entry.question.kind == kind) && (difficulty == "Любая сложность" || entry.question.difficulty == difficulty) && (tags.isEmpty || tags.contains { tag in (entry.question.tags ?? []).contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }) }
    }
    func accepts(_ entry: BankEntry,unusedOnly: Bool) -> Bool {
        !entry.archived && (!unusedOnly || (entry.history ?? []).isEmpty) && entry.question.issues.isEmpty && (kind == "Любой тип" || entry.question.kind == kind) && (difficulty == "Любая сложность" || entry.question.difficulty == difficulty) && (tags.isEmpty || tags.contains { tag in (entry.question.tags ?? []).contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } })
    }
}
extension Studio {
    func confirmReplaceForAssembly() -> Bool {
        let hasDraft = documentURL == nil && quiz.rounds.flatMap(\.questions).contains { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        guard screen == .editor || hasDraft else { return true }
        let alert = NSAlert(); alert.messageText = "Сохранить текущий квиз перед созданием нового?"
        alert.addButton(withTitle:"Сохранить"); alert.addButton(withTitle:"Отмена"); alert.addButton(withTitle:"Создать без сохранения")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertThirdButtonReturn: return true; default: return false }
    }
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
    func assembleQuiz(_ rounds: [QuizAssemblyRound],title: String) throws {
        guard (1...20).contains(rounds.count), rounds.allSatisfy({ round in (1...50).contains(round.count) && round.questions.count == round.count && Set(round.questions.map(\.id)).count == round.questions.count && round.questions.allSatisfy({ round.accepts($0,unusedOnly:false) }) }), Set(rounds.flatMap(\.questions).map(\.id)).count == rounds.reduce(0,{$0+$1.questions.count}) else { throw SIQError(message:"Заполните раунды без повторных, архивных или неподходящих вопросов.") }
        let selected = rounds.flatMap(\.questions)
        let copied = try copyBankQuestions(selected)
        var result = Quiz(); result.title = title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "Квиз из банка" : title; result.rounds = []
        var offset = 0
        for draft in rounds { var round = Round(); round.title = draft.title; round.questions = Array(copied.questions[offset..<offset+draft.questions.count]); offset += draft.questions.count; result.rounds.append(round) }
        quiz = result; folder = copied.folder; documentURL = nil; registeredFontName = nil; screen = .editor; roundIndex = 0; questionIndex = 0; undoHistory = []; editorSelection = []; autosave()
        status = "Квиз собран из банка: \(rounds.count) раундов, \(selected.count) вопросов. Сохраните его в .quiz."
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
    @State private var rounds: [QuizAssemblyRound] = [QuizAssemblyRound(title:"Раунд 1",count:5)]
    @State private var randomMode = false
    init(studio: Studio) { self.studio = studio; bank = studio.questionBank }
    var effective: QuizAssemblyRules { var copy = rules; copy.tags = Question.cleanTags(tags); return copy }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("Собрать квиз из банка").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            TextField("Название квиза",text:$title)
            Toggle("Быстрый случайный подбор с общими условиями",isOn:$randomMode)
            if randomMode {
                HStack { Stepper("Раундов: \(rules.rounds)",value:$rules.rounds,in:1...20); Stepper("Вопросов в раунде: \(rules.perRound)",value:$rules.perRound,in:1...50) }
                TextField("Общие темы через запятую",text:$tags)
                HStack { Picker("Тип",selection:$rules.kind) { ForEach(["Любой тип"]+Question.kinds,id:\.self) { Text($0) } }; Picker("Сложность",selection:$rules.difficulty) { ForEach(["Любая сложность","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) } } }
            Toggle("Исключить вопросы, уже использованные в сохранённых квизах или играх",isOn:$rules.unusedOnly)
                Button("Случайно распределить вопросы") { do { chosen = try effective.select(bank.entries); rounds = (0..<rules.rounds).map { i in QuizAssemblyRound(title:"Раунд \(i+1)",count:rules.perRound,questions:Array(chosen[(i*rules.perRound)..<((i+1)*rules.perRound)])) }; error=nil } catch { self.error=error.localizedDescription } }.buttonStyle(.borderedProminent)
            } else {
                HStack { Button("Добавить раунд") { guard rounds.count < 20 else { return }; rounds.append(QuizAssemblyRound(title:"Раунд \(rounds.count+1)",count:5)) }; Button("Убрать последний") { if rounds.count>1 { rounds.removeLast() } } }
                Toggle("Исключить вопросы, уже использованные в сохранённых квизах или играх",isOn:$rules.unusedOnly)
            }
            Text("Архивные и незавершённые записи исключены. Предпросмотр не меняет историю банка.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            List { ForEach(rounds.indices,id:\.self) { ri in
                Section {
                    HStack { TextField("Название раунда",text:$rounds[ri].title); Stepper("Вопросов: \(rounds[ri].count)",value:$rounds[ri].count,in:1...50) }
                    TextField("Темы через запятую",text:Binding(get:{rounds[ri].tags.joined(separator:", ")},set:{rounds[ri].tags=Question.cleanTags($0)}))
                    HStack { Picker("Тип",selection:$rounds[ri].kind) { ForEach(["Любой тип"]+Question.kinds,id:\.self) { Text($0) } }; Picker("Сложность",selection:$rounds[ri].difficulty) { ForEach(["Любая сложность","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) } } }
                    let excluded=Set(rounds.flatMap{$0.questions}.map(\.id))
                    let eligible=rounds[ri].candidates(bank.entries,excluding:excluded,unusedOnly:rules.unusedOnly)
                    let incomplete=max(0,rounds[ri].count-rounds[ri].questions.count)
                    let shortage=max(0,rounds[ri].count-min(rounds[ri].questions.count+eligible.count,rounds[ri].count))
                    Text("Подобрано: \(rounds[ri].questions.count)/\(rounds[ri].count) · осталось подобрать: \(incomplete) · кандидатов ещё: \(eligible.count) · дефицит: \(shortage)").font(.caption).foregroundStyle(shortage > 0 ? .orange:.secondary)
                    Button("Подобрать недостающие вопросы") {
                        let excluded=Set(rounds.flatMap{$0.questions}.map(\.id))
                        let candidates=rounds[ri].candidates(bank.entries,excluding:excluded,unusedOnly:rules.unusedOnly).shuffled()
                        rounds[ri].questions += Array(candidates.prefix(incomplete)); chosen=rounds.flatMap(\.questions)
                    }
                    ForEach(Array(rounds[ri].questions.enumerated()),id:\.element.id) { qi,entry in
                        VStack(alignment:.leading) {
                            HStack {
                                Text("\(qi+1). \(entry.question.text)").lineLimit(2); Spacer()
                                Button("↑") { if qi>0 { rounds[ri].questions.swapAt(qi,qi-1) } }.disabled(qi==0)
                                Button("↓") { if qi+1<rounds[ri].questions.count { rounds[ri].questions.swapAt(qi,qi+1) } }.disabled(qi+1>=rounds[ri].questions.count)
                                Menu("Перенести") { ForEach(rounds.indices.filter{$0 != ri},id:\.self) { target in Button(rounds[target].title.isEmpty ? "Раунд \(target+1)" : rounds[target].title) {
                                    guard rounds[target].accepts(entry,unusedOnly:rules.unusedOnly) else { error="Вопрос не соответствует условиям раунда «\(rounds[target].title)»."; return }
                                    guard rounds[target].questions.count < rounds[target].count else { error="Сначала освободите место в целевом раунде."; return }
                                    rounds[target].questions.append(entry); rounds[ri].questions.remove(at:qi); chosen=rounds.flatMap(\.questions)
                                } } }.disabled(rounds.count<2)
                                Button("Заменить") {
                                    let excluded=Set(rounds.flatMap(\.questions).filter{$0.id != entry.id}.map(\.id))
                                    if let replacement=rounds[ri].candidates(bank.entries,excluding:excluded,unusedOnly:rules.unusedOnly).randomElement() { rounds[ri].questions[qi]=replacement; chosen=rounds.flatMap(\.questions); error=nil }
                                    else { error="Для этого раунда нет доступной замены." }
                                }
                                Button("Удалить",role:.destructive) { rounds[ri].questions.remove(at:qi); chosen=rounds.flatMap(\.questions) }
                            }
                            Text("\(entry.question.tags?.joined(separator:", ") ?? "Без темы") · \(entry.question.kind) · \(entry.question.difficulty ?? "Не указана") · \(entry.question.media == nil && entry.question.explanationMedia == nil ? "Без медиа":"Есть медиа")").font(.caption).foregroundStyle(.secondary)
                            Text("Ответ: \(entry.question.correctAnswer)").font(.caption).foregroundStyle(.secondary)
                        }.onDrag { NSItemProvider(object:entry.id.uuidString as NSString) }
                         .onDrop(of:[UTType.text],isTargeted:nil) { providers in
                            guard let provider=providers.first else { return false }
                            _=provider.loadObject(ofClass:NSString.self) { value,_ in
                                guard let id=UUID(uuidString:value as? String ?? "") else { return }
                                DispatchQueue.main.async {
                                    guard let source=rounds[ri].questions.firstIndex(where:{$0.id==id}),source != qi else { return }
                                    rounds[ri].questions.swapAt(source,qi); chosen=rounds.flatMap(\.questions)
                                }
                            }; return true
                         }
                    }
                } header: { Text("Раунд \(ri+1) · \(rounds[ri].title)") }
            } }

            ScrollView(.horizontal) {
                HStack(alignment:.top,spacing:14) {
                    ForEach(Array(rounds.enumerated()),id:\.element.id) { index,round in
                        let isIncomplete = round.questions.count < round.count
                        let warning = round.questions.isEmpty ? " · пустой" : (isIncomplete ? " · неполный" : "")
                        let countSummary = "\(round.questions.count)/\(round.count) вопросов" + warning
                        VStack(alignment:.leading,spacing:3) {
                            Text("Раунд \(index+1) · \(round.title)").font(.caption.bold())
                            Text(countSummary).font(.caption).foregroundStyle(isIncomplete ? .orange:.secondary)
                            ForEach(round.questions) { item in
                                Text(item.question.text).font(.caption).lineLimit(1).frame(maxWidth:180,alignment:.leading)
                            }
                        }.padding(7).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
                    }
                    let totalQuestions = rounds.map(\.questions.count).reduce(0,+)
                    VStack(alignment:.leading) {
                        Text("Всего").font(.caption.bold())
                        Text("\(totalQuestions) вопросов").font(.caption)
                    }.padding(7)
                }
            }.frame(height:80)
            HStack { Spacer(); Button("Создать квиз") {
                guard studio.confirmReplaceForAssembly() else { return }
                do { try studio.assembleQuiz(rounds,title:title); studio.showQuestionBank = false; dismiss() } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(rounds.contains{$0.questions.count != $0.count}) }
        }.padding(24).frame(width:1000,height:780)
    }
}
struct BulkQuestionImportView: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var pageURL = ""
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
            HStack { Button("Открыть XLSX / CSV / TSV / TXT / PDF / PPTX…") {
                let panel = NSOpenPanel(); panel.allowedContentTypes = ["xlsx","csv","tsv","txt","pdf","pptx"].compactMap { UTType(filenameExtension:$0) }; panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }; source = url.lastPathComponent
                load { try QuestionTextImport.file(url) }
            }; Button("Шаблон CSV…") { saveTemplate() }; if busy { ProgressView().controlSize(.small) } }
            HStack {
                TextField("Ссылка на открытую страницу с пакетом вопросов",text:$pageURL).textFieldStyle(.roundedBorder)
                Button("Загрузить страницу") { importPage() }.disabled(pageURL.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || busy)
            }
            DisclosureGroup("Формат и ограничения") {
                Text("Таблица: заголовки Вопрос, Ответ, Объяснение, Тип, Вариант1…Вариант8, Правильные варианты (номера через запятую), Погрешность, События (через | в верном порядке), Темы, Сложность, Время. XLSX: первый видимый лист; формулы не вычисляются. Для сопоставления: столбец Пары, например Франция=Париж|Италия=Рим. Из Numbers экспортируйте XLSX/CSV.").font(.caption)
                Text("Текст, извлечённый из PDF/PPTX, и открытые веб-страницы разбираются автоматически. Для PDF нужен текстовый слой; сканы без OCR не читаются. В презентациях берётся текст слайдов, картинки и анимация не разбираются. До 5000 вопросов за импорт. Перед сохранением проверьте распознавание.").font(.caption)
                Text("Текст: по строке «вопрос — ответ — объяснение» либо блоки с метками «Вопрос:», «Вопрос 1:», «Ответ:», «Объяснение:». ").font(.caption)
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
    func load(_ operation: @escaping @Sendable () async throws -> QuestionImportResult) {
        importTask?.cancel(); busy = true; error = nil; rows = []; warnings = []
        importTask = Task {
            do {
                let worker = Task.detached(priority:.userInitiated) { try await operation() }
                let result = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
                guard !Task.isCancelled else { return }; rows = result.rows; warnings = result.warnings; busy = false
                if rows.isEmpty { error = "Вопросы не найдены. Проверьте формат." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; busy = false } }
        }
    }
    func importPage() {
        guard let url = URL(string:pageURL.trimmingCharacters(in:.whitespacesAndNewlines)),
              ["https","http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              host != "localhost", !host.hasSuffix(".local") else { error = "Введите публичную ссылку, начинающуюся с http:// или https://."; return }
        source = url.absoluteString
        load {
            var request = URLRequest(url:url); request.timeoutInterval = 25; request.setValue("text/html, text/plain;q=0.9, */*;q=0.5",forHTTPHeaderField:"Accept")
            let (data,response) = try await URLSession.shared.data(for:request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SIQError(message:"Сайт не отдал страницу (проверьте ссылку и доступность сайта).") }
            guard let final = response.url, final.host != "localhost", !(final.host?.hasSuffix(".local") ?? false) else { throw SIQError(message:"Ссылка перенаправила на локальный адрес.") }
            return try QuestionTextImport.html(data)
        }
    }
    func saveTemplate() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Шаблон вопросов.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sample = [["Вопрос","Ответ","Объяснение","Тип","Вариант1","Вариант2","Вариант3","Вариант4","Правильные варианты","Погрешность","События","Темы","Сложность","Время"],["Сколько планет в Солнечной системе?","8","Плутон относится к карликовым планетам.","Числовой ответ","","","","","","0","","космос","Лёгкий","30"],["Выберите чётные числа","","Делятся на два.","Несколько вариантов","2","3","4","5","1,3","","","математика","Лёгкий","30"],["Расположите события по времени","","","Порядок событий","","","","","","","Первый спутник|Первый человек в космосе|Высадка на Луну","космос","Средний","60"]]
        do { try ("\u{FEFF}"+GameArchive.csv(sample)).write(to:url,atomically:true,encoding:.utf8) } catch { self.error = error.localizedDescription }
    }
}

import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

struct ArchiveRunState: Codable {
    var id = UUID()
    var started = Date()
    var shown: Set<UUID> = []
    var closed: Set<UUID> = []
    var activeQuestion: UUID?
}
struct ArchivedQuestion: Codable, Identifiable {
    var id: UUID
    var roundID: UUID
    var roundTitle: String
    var text: String
    var answer: String
    var kind: String
    var analysisKey: String
    var tags: [String]
    init(_ q: Question,round: Round) {
        id = q.id; roundID = round.id; roundTitle = round.title; text = q.text; kind = q.kind; tags = q.tags ?? []
        answer = q.kind == "Сопоставление" ? (q.matchPairs ?? []).map { $0.left+" — "+$0.right }.joined(separator:"; ") : q.correctAnswer
        let content = [q.kind,q.text,answer,q.choices.joined(separator:"\n")].joined(separator:"\u{0}")
        analysisKey = (q.bankEntryID ?? q.id).uuidString+":"+SHA256.hash(data:Data(content.utf8)).map { String(format:"%02x",$0) }.joined()
    }
}
struct ArchivedAnswer: Codable, Identifiable {
    var teamID: UUID
    var questionID: UUID
    var display: String
    var points: Double?
    var outcome: String? = nil
    var id: String { teamID.uuidString+":"+questionID.uuidString }
    var resolvedOutcome: String? { outcome ?? points.map { $0 == 1 ? "correct":"wrong" } }
}
struct ArchivedRound: Codable, Identifiable { var id: UUID; var title: String }
struct ArchivedGame: Codable, Identifiable {
    var version = 1
    var id: UUID
    var quizID: UUID?
    var title: String
    var started: Date
    var updated: Date
    var ended: Date?
    var status: String
    var phone: Bool
    var teams: [Team]
    var rounds: [ArchivedRound]
    var questions: [ArchivedQuestion]
    var shown: Set<UUID>
    var closed: Set<UUID>
    var answers: [ArchivedAnswer]
    var statusText: String { switch status { case "completed": return "Завершена"; case "paused": return "Сохранена для продолжения"; case "stopped": return "Прервана"; default: return "Незавершена" } }
    var sortedTeams: [Team] { teams.sorted { $0.total == $1.total ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.total > $1.total } }
    var pending: Int { answers.filter { $0.points == nil }.count }
    func stats(for q: ArchivedQuestion) -> QuestionStatistics {
        let received = answers.filter { answer in answer.questionID == q.id && teams.contains(where:{ $0.id == answer.teamID }) }
        return QuestionStatistics(question:q,shown:shown.contains(q.id),closed:closed.contains(q.id),participants:teams.count,answers:received)
    }
}
struct QuestionStatistics: Identifiable {
    var question: ArchivedQuestion
    var shown: Bool
    var closed: Bool
    var participants: Int
    var answers: [ArchivedAnswer]
    var id: UUID { question.id }
    var correct: Int { answers.filter { $0.resolvedOutcome == "correct" }.count }
    var wrong: Int { answers.filter { $0.resolvedOutcome == "wrong" }.count }
    var partial: Int { answers.filter { $0.outcome == "partial" }.count }
    var pending: Int { answers.filter { $0.points == nil }.count }
    var missing: Int { max(0,participants-answers.count) }
    var percent: Double? { closed && participants > 0 ? Double(correct)*100/Double(participants) : nil }
    var graded: Int { correct+wrong+partial }
    var gradedPercent: Double? { closed && graded > 0 ? Double(correct)*100/Double(graded) : nil }
    var responsePercent: Double? { closed && participants > 0 ? Double(answers.count)*100/Double(participants) : nil }
    var responseDistribution: [AnswerDistribution] {
        let groups = Dictionary(grouping:answers,by:{ PhoneRoom.normalize($0.display) })
        return groups.values.map { group in
            let text = group.first?.display.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            return AnswerDistribution(text:text.isEmpty ? "Пустой ответ" : text,count:group.count,correct:group.filter { $0.resolvedOutcome == "correct" }.count,partial:group.filter { $0.resolvedOutcome == "partial" }.count,wrong:group.filter { $0.resolvedOutcome == "wrong" }.count,pending:group.filter { $0.points == nil }.count)
        }.sorted { $0.count == $1.count ? $0.text.localizedStandardCompare($1.text) == .orderedAscending : $0.count > $1.count }
    }
    var errors: [(text:String,count:Int)] {
        Dictionary(grouping:answers.filter { $0.resolvedOutcome == "wrong" },by:{ PhoneRoom.normalize($0.display) }).values.map { (text:$0.first!.display,count:$0.count) }.sorted { $0.count == $1.count ? $0.text < $1.text : $0.count > $1.count }
    }
}
struct AnswerDistribution: Identifiable {
    var text: String
    var count: Int
    var correct: Int
    var partial: Int
    var wrong: Int
    var pending: Int
    var id: String { PhoneRoom.normalize(text) }
}
struct AggregatedQuestion: Identifiable {
    var key: String
    var question: ArchivedQuestion
    var runIDs: Set<UUID> = []
    var games: Int { runIDs.count }
    var participants = 0
    var correct = 0
    var wrong = 0
    var partial = 0
    var pending = 0
    var missing = 0
    var id: String { key }
    var percent: Double { participants > 0 ? Double(correct)*100/Double(participants) : 0 }
    var graded: Int { correct+wrong+partial }
    var gradedPercent: Double? { graded > 0 ? Double(correct)*100/Double(graded) : nil }
    var answered: Int { correct+wrong+partial+pending }
    var responsePercent: Double { participants > 0 ? Double(answered)*100/Double(participants) : 0 }
}
@MainActor final class GameArchive: ObservableObject {
    let root: URL
    @Published var games: [ArchivedGame] = []
    @Published var error = ""
    init(root: URL) {
        self.root = root
        do {
            guard FileManager.default.fileExists(atPath:root.path) else { return }
            for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where url.pathExtension == "game" {
                do {
                    let game = try JSONDecoder().decode(ArchivedGame.self,from:Data(contentsOf:url))
                    guard game.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                    games.append(game)
                } catch { self.error = "Часть записей не прочитана. Исходные файлы сохранены: "+error.localizedDescription }
            }
            games.sort { $0.started > $1.started }
        } catch { self.error = error.localizedDescription }
    }
    func save(_ game: ArchivedGame) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(game).write(to:root.appendingPathComponent(game.id.uuidString+".game"),options:.atomic)
        if let i = games.firstIndex(where:{ $0.id == game.id }) { games[i] = game } else { games.append(game) }
        games.sort { $0.started > $1.started }; error = ""
    }
    static func aggregate(_ games: [ArchivedGame]) -> [AggregatedQuestion] {
        var rows: [String:AggregatedQuestion] = [:]
        for game in games where game.phone && game.status == "completed" {
            // A repeated copy in a single game is still a distinct opportunity to answer.
            for q in game.questions where game.closed.contains(q.id) {
                let stats = game.stats(for:q)
                var row = rows[q.analysisKey] ?? AggregatedQuestion(key:q.analysisKey,question:q)
                row.runIDs.insert(game.id); row.participants += stats.participants; row.correct += stats.correct; row.wrong += stats.wrong; row.partial += stats.partial; row.pending += stats.pending; row.missing += stats.missing
                rows[q.analysisKey] = row
            }
        }
        return rows.values.sorted {
            let left = $0.gradedPercent ?? .infinity
            let right = $1.gradedPercent ?? .infinity
            return left == right ? $0.question.text.localizedStandardCompare($1.question.text) == .orderedAscending : left < right
        }
    }
    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in row.map { text in
            let first = text.trimmingCharacters(in:.whitespacesAndNewlines).first
            let numeric = Double(text) != nil
            let safe = !numeric && first.map({ "=+-@".contains($0) }) == true ? "'"+text : text
            return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""
        }.joined(separator:",") }.joined(separator:"\r\n")
    }
    static func scoresCSV(_ game: ArchivedGame) -> String {
        var rows = [["Место","Команда"]+game.rounds.map(\.title)+["Всего"]]
        for team in game.sortedTeams { rows.append([String(1+game.teams.filter { $0.total > team.total }.count),team.name]+game.rounds.map { scoreText(team.scores[$0.id.uuidString] ?? 0) }+[scoreText(team.total)]) }
        return csv(rows)
    }
    static func questionsCSV(_ game: ArchivedGame) -> String {
        var rows = [["Раунд","Вопрос","Правильный ответ","Статус","Команд","Верно","Частично","Неверно","Нужна проверка","Нет ответа","Верно от всех команд (%)","Верно среди оценённых (%)","Ответили (%)"]]
        for q in game.questions {
            let s = game.stats(for:q)
            rows.append([q.roundTitle,q.text,q.answer,!s.shown ? "Не показан" : s.closed ? "Приём завершён" : "Приём не завершён",String(s.participants),String(s.correct),String(s.partial),String(s.wrong),String(s.pending),s.shown ? String(s.missing) : "",s.percent.map { String(format:"%.1f",$0) } ?? "",s.gradedPercent.map { String(format:"%.1f",$0) } ?? "",s.responsePercent.map { String(format:"%.1f",$0) } ?? ""])
        }
        return csv(rows)
    }
}
extension Studio {
    func beginArchiveRun() {
        guard !isEditorPreview else { return }
        archiveRun = ArchiveRunState()
    }
    func archiveEnteredStep() {
        guard !isEditorPreview, var run = archiveRun else { return }
        let nextID = step?.kind == .question ? currentQuestion?.id : nil
        if let old = run.activeQuestion, old != nextID { run.closed.insert(old) }
        run.activeQuestion = nextID
        if let nextID { run.shown.insert(nextID) }
        archiveRun = run
        if step?.kind == .finish { persistArchive(status:"completed") }
    }
    func persistArchive(status requested: String? = nil) {
        guard !isEditorPreview, let run = archiveRun else { return }
        let existing = gameArchive.games.first { $0.id == run.id }
        let status = requested ?? (step?.kind == .finish ? "completed" : "running")
        let ended = status == "completed" || status == "stopped" ? (existing?.ended ?? Date()) : nil
        let questions = quiz.rounds.flatMap { r in r.questions.map { ArchivedQuestion($0,round:r) } }
        let ids = Set(questions.map(\.id)); let teams = Set(quiz.teams.map(\.id))
        let answers = phoneMode ? phoneRoom.answers.filter { ids.contains($0.questionID) && teams.contains($0.teamID) }.map { ArchivedAnswer(teamID:$0.teamID,questionID:$0.questionID,display:$0.display,points:$0.points,outcome:$0.outcome) } : []
        let game = ArchivedGame(id:run.id,quizID:quiz.bankHistoryID,title:quiz.title,started:run.started,updated:Date(),ended:ended,status:status,phone:phoneMode,teams:quiz.teams,rounds:quiz.rounds.map { ArchivedRound(id:$0.id,title:$0.title) },questions:questions,shown:run.shown,closed:run.closed,answers:answers)
        do { try gameArchive.save(game) } catch { gameArchive.error = "Ошибка архива: "+error.localizedDescription }
    }
}

struct GameArchiveView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var archive: GameArchive
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var selected: UUID?
    @State private var tab = 0
    @State private var onlyCompleted = false
    @State private var exportError: String?
    init(studio: Studio) { self.studio = studio; self.archive = studio.gameArchive; _selected = State(initialValue:studio.archiveRun?.id) }
    var visible: [ArchivedGame] { archive.games.filter { (!onlyCompleted || $0.status == "completed") && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.teams.contains { $0.name.localizedCaseInsensitiveContains(search) }) } }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("Архив игр и статистика").font(.title.bold()); Spacer(); Button("Назад") { studio.showGameArchive=false } }
            Text("Каждый запуск сохраняется отдельно на этом Mac. Файл квиза можно менять — результаты прошлых игр сохранятся.").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("Квиз или команда",text:$search); Toggle("Только завершённые",isOn:$onlyCompleted) }
            Picker("Раздел",selection:$tab) { Text("Проведённые игры").tag(0); Text("Статистика вопросов").tag(1) }.pickerStyle(.segmented)
            if !archive.error.isEmpty { Text(archive.error).foregroundStyle(.red) }
            if let exportError { Text(exportError).foregroundStyle(.red) }
            if tab == 0 {
                HSplitView {
                    List(visible,selection:$selected) { game in
                        VStack(alignment:.leading,spacing:5) {
                            Text(game.title).font(.headline)
                            Text(game.started.formatted(date:.abbreviated,time:.shortened)).font(.caption)
                            Text("\(game.statusText) · \(game.phone ? "Телефоны" : "Бланки") · Команд: \(game.teams.count)").font(.caption).foregroundStyle(.secondary)
                            if game.pending > 0 { Text("Ответов без оценки: \(game.pending)").font(.caption).foregroundStyle(.orange) }
                        }.padding(.vertical,6).tag(game.id)
                    }.frame(minWidth:210,idealWidth:270,maxWidth:360)
                    if let game = visible.first(where:{ $0.id == selected }) {
                        ScrollView { ArchivedGameDetail(game:game,export:{ type in export(game,type:type) }).frame(maxWidth:.infinity,alignment:.leading) }
                    } else { ContentUnavailableView("Выберите игру",systemImage:"chart.bar.doc.horizontal",description:Text(visible.isEmpty ? "Результаты появятся после запуска квиза. Старые игры автоматически восстановить нельзя." : "Слева — отдельные проведения квизов." )).frame(maxWidth:.infinity) }
                }
            } else {
                let rows = GameArchive.aggregate(visible)
                Text("Сводка включает завершённые игры с телефонами и вопросы с закрытым приёмом ответов. Сложность считается как доля верных среди оценённых; частичные и непроверенные ответы показаны отдельно. Доля ответивших и пропуски помогают отличить сложный вопрос от вопроса, который команды пропускали. Исправления оценок учитываются автоматически.").font(.caption).foregroundStyle(.secondary)
                if !rows.isEmpty { ReportOverview(rows:rows) }
                if rows.isEmpty { ContentUnavailableView("Пока нет статистики",systemImage:"chart.bar",description:Text("Проведите игру с телефонов и завершите её. Для бланков приложение знает баллы по раундам, но не ответы на отдельные вопросы.")) }
                List(rows) { row in
                    VStack(alignment:.leading,spacing:6) {
                        HStack(alignment:.top) { Text(row.question.text).font(.headline).lineLimit(2); Spacer(minLength:8); Text("\(row.gradedPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—")% верно среди оценённых").bold().fixedSize(horizontal:true,vertical:false) }
                        Text("Игр: \(row.games) · Верно: \(row.correct) из \(row.graded) оценённых · Ответили: \(row.responsePercent.formatted(.number.precision(.fractionLength(0...1))))% · Частично: \(row.partial) · Без оценки: \(row.pending) · Нет ответа: \(row.missing)").font(.caption).foregroundStyle(.secondary)
                        Text("Ответ: "+row.question.answer).font(.caption)
                    }.padding(.vertical,6)
                }
            }
        }.padding(22).frame(minWidth:900,idealWidth:1050,minHeight:600,idealHeight:700)
        .onAppear { if selected == nil { selected = visible.first?.id } }
        .onChange(of:visible.map(\.id)) { _,ids in if selected.map({ !ids.contains($0) }) ?? true { selected = ids.first } }
    }
    func export(_ game: ArchivedGame,type: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = game.title.replacingOccurrences(of:"/",with:"-")+" — "+type+".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let text = type == "результаты" ? GameArchive.scoresCSV(game) : GameArchive.questionsCSV(game); try ("\u{FEFF}"+text).write(to:url,atomically:true,encoding:.utf8); exportError = nil } catch { exportError = error.localizedDescription }
    }
}
struct ArchivedGameDetail: View {
    let game: ArchivedGame
    let export: (String) -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(game.title).font(.title2.bold())
            Text("Начало: "+game.started.formatted(date:.abbreviated,time:.shortened)+" · "+game.statusText).font(.caption).foregroundStyle(.secondary)
            HStack { Button("Результаты CSV") { export("результаты") }; if game.phone { Button("Статистика вопросов CSV") { export("вопросы") } } }
            Text("Команды и баллы по раундам").font(.headline)
            ScrollView(.horizontal) {
                Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:10) {
                    GridRow { Text("Место").bold(); Text("Команда").bold(); ForEach(game.rounds) { Text($0.title).bold() }; Text("Всего").bold() }
                    ForEach(game.sortedTeams) { team in
                        GridRow {
                            Text(String(1+game.teams.filter { $0.total > team.total }.count))
                            Text(team.name)
                            ForEach(game.rounds) { round in Text(scoreText(team.scores[round.id.uuidString] ?? 0)) }
                            Text(scoreText(team.total)).bold()
                        }
                    }
                }.padding(.vertical,8)
            }
            if game.phone {
                Text("Вопросы").font(.headline)
                Text("Процент считается от всех команд только после закрытия приёма ответа. Непроверенный ответ не считается автоматически неправильным. Статистика промежуточная, пока такие ответы не оценены.").font(.caption).foregroundStyle(.secondary)
                ForEach(game.questions) { q in
                    let stats = game.stats(for:q)
                    DisclosureGroup {
                        VStack(alignment:.leading,spacing:8) {
                            Text("Правильный ответ: "+q.answer)
                            if !stats.shown { Text("Вопрос не показывался и не учитывается в статистике.") }
                            else {
                                Text("Верно: \(stats.correct) · Неверно: \(stats.wrong) · Частично: \(stats.partial) · Без оценки: \(stats.pending) · Нет ответа: \(stats.missing)")
                                if let rate = stats.gradedPercent {
                                    let answered = stats.responsePercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—"
                                    Text("Верно среди оценённых: \(rate.formatted(.number.precision(.fractionLength(0...1))))% · Ответили: \(answered)%")
                                }
                                if !stats.closed { Text("Приём ответа не завершён; процент пока не рассчитывается.").foregroundStyle(.orange) }
                                if !stats.responseDistribution.isEmpty {
                                    Text("Распределение ответов").bold()
                                    ForEach(stats.responseDistribution.prefix(8)) { response in
                                        VStack(alignment:.leading,spacing:2) {
                                            Text("\(response.count) × \(response.text)").textSelection(.enabled)
                                            Text("Верно: \(response.correct) · Частично: \(response.partial) · Неверно: \(response.wrong) · Без оценки: \(response.pending)").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if !stats.errors.isEmpty {
                                    Text("Частые неверные ответы").bold()
                                    ForEach(Array(stats.errors.enumerated()),id:\.offset) { _,error in Text("\(error.text) — \(error.count)") }
                                }
                                ForEach(stats.answers) { answer in
                                    HStack(alignment:.top) { Text(game.teams.first { $0.id == answer.teamID }?.name ?? "Команда").bold(); Text(answer.display).textSelection(.enabled); Spacer(); Text(answer.resolvedOutcome == "correct" ? "Верно" : answer.resolvedOutcome == "partial" ? "Частично" : answer.resolvedOutcome == "wrong" ? "Неверно" : "Без оценки").foregroundStyle(answer.points == nil ? .orange : .secondary) }
                                }
                            }
                        }.font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
                    } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text(q.roundTitle+" · "+q.text).lineLimit(3)
                            Text(!stats.shown ? "Не показан" : stats.percent.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))% верно" } ?? "Приём не завершён").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(10).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:10))
                }
            } else { Text("Игра с бланками: сохранены результаты команд по раундам. Статистика отдельных ответов недоступна.").font(.callout).foregroundStyle(.secondary) }
        }.padding(.trailing,8)
    }
}
struct ReportOverview: View {
    let rows: [AggregatedQuestion]
    private var graded: Int { rows.reduce(0) { $0+$1.graded } }
    private var correct: Int { rows.reduce(0) { $0+$1.correct } }
    private var answered: Int { rows.reduce(0) { $0+$1.answered } }
    private var opportunities: Int { rows.reduce(0) { $0+$1.participants } }
    private var hardest: AggregatedQuestion? { rows.filter { $0.graded > 0 }.min { ($0.gradedPercent ?? 100) < ($1.gradedPercent ?? 100) } }
    private var easiest: AggregatedQuestion? { rows.filter { $0.graded > 0 }.max { ($0.gradedPercent ?? 0) < ($1.gradedPercent ?? 0) } }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:20) {
                metric("Вопросов",String(rows.count))
                metric("Верно среди оценённых",graded > 0 ? "\((Double(correct)*100/Double(graded)).formatted(.number.precision(.fractionLength(0...1))))%" : "—")
                metric("Ответили",opportunities > 0 ? "\((Double(answered)*100/Double(opportunities)).formatted(.number.precision(.fractionLength(0...1))))%" : "—")
                metric("Пропусков",String(rows.reduce(0) { $0+$1.missing }))
            }
            HStack(alignment:.top,spacing:24) {
                if let hardest { insight("Сложнее всего",hardest) }
                if let easiest, easiest.id != hardest?.id { insight("Легче всего",easiest) }
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
    }
    private func metric(_ title:String,_ value:String) -> some View {
        VStack(alignment:.leading,spacing:3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }
    }
    private func insight(_ title:String,_ row:AggregatedQuestion) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(row.question.text).font(.callout).lineLimit(2)
            Text("\((row.gradedPercent ?? 0).formatted(.number.precision(.fractionLength(0...1))))% верно · \(row.graded) оценённых · \(row.games) игр").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

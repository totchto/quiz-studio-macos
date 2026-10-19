import SwiftUI

struct BankUse: Codable, Equatable, Identifiable {
    var quizID: UUID
    var title: String
    var date: Date
    var played: Bool
    var id: UUID { quizID }
}
extension Question {
    var topicTags: [String] {
        get { tags ?? [] }
        set { tags = Self.cleanTags(newValue.joined(separator:",")) }
    }
    static func cleanTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy:CharacterSet(charactersIn:",;\n")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
struct RoundTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var seconds: Int
    var afterMedia: Bool
    var audioOnly: Bool? = nil
    var answerSeconds: Int
    var repeatQuestions: Bool
    var repeatSeconds: Int
    var repeatIntroSeconds: Int
    var breakSeconds: Int
    var showAnswers: Bool
    var standings: Bool
    var muteBackground: Bool
    init(name: String,round: Round) {
        self.name = name; audioOnly = round.defaultAudioOnly; seconds = round.defaultSeconds; afterMedia = round.defaultAfterMedia; answerSeconds = round.defaultAnswerSeconds ?? 20
        repeatQuestions = round.repeatQuestions; repeatSeconds = round.repeatSeconds; repeatIntroSeconds = round.repeatIntroSeconds ?? 5
        breakSeconds = round.breakSeconds; showAnswers = round.showAnswers; standings = round.standings; muteBackground = round.muteBackground ?? false
    }
    static let builtins: [RoundTemplate] = {
        var classic = Round(); classic.repeatQuestions = true
        var music = Round(); music.defaultSeconds = 30; music.defaultAfterMedia = true; music.defaultAnswerSeconds = 30; music.defaultAudioOnly = true
        var blitz = Round(); blitz.defaultSeconds = 15; blitz.defaultAfterMedia = false; blitz.defaultAnswerSeconds = 10
        return [RoundTemplate(name:"Обычный раунд",round:classic),RoundTemplate(name:"Музыкальный раунд",round:music),RoundTemplate(name:"Блиц",round:blitz)]
    }()
    func applying(to original: Round) -> Round {
        var round = original
        round.defaultAudioOnly = audioOnly; round.defaultSeconds = seconds; round.defaultAfterMedia = afterMedia; round.defaultAnswerSeconds = answerSeconds
        round.repeatQuestions = repeatQuestions; round.repeatSeconds = repeatSeconds; round.repeatIntroSeconds = repeatIntroSeconds
        round.breakSeconds = breakSeconds; round.showAnswers = showAnswers; round.standings = standings; round.muteBackground = muteBackground
        for i in round.questions.indices { round.questions[i].seconds = seconds; round.questions[i].afterMedia = afterMedia; round.questions[i].answerSeconds = answerSeconds; if let audioOnly { round.questions[i].audioOnly = audioOnly } }
        return round
    }
}
@MainActor final class RoundTemplateStore: ObservableObject {
    let url: URL
    @Published var custom: [RoundTemplate] = []
    @Published var error = ""
    init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath:url.path) { do { custom = try JSONDecoder().decode([RoundTemplate].self,from:Data(contentsOf:url)) } catch { self.error = "Не удалось прочитать шаблоны: "+error.localizedDescription } }
    }
    var all: [RoundTemplate] { RoundTemplate.builtins+custom }
    func save(name: String,round: Round) throws {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { throw SIQError(message:"Введите название шаблона.") }
        var updated = custom
        if let i = updated.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            var value = RoundTemplate(name:name,round:round); value.id = updated[i].id; updated[i] = value
        } else { updated.append(RoundTemplate(name:name,round:round)) }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(updated).write(to:url,options:.atomic); custom = updated; error = ""
    }
}
enum EditorPreviewMode: String, Identifiable { case question, answer, round; var id: String { rawValue } }
extension QuestionBank {
    func recordUse(questionIDs: Set<UUID>,quizID: UUID,title: String,played: Bool) throws {
        for entry in entries.filter({ questionIDs.contains($0.id) }) {
            var updated = entry
            var history = updated.history ?? []
            if let i = history.firstIndex(where: { $0.quizID == quizID }) {
                history[i].title = title
                if played { history[i].date = Date(); history[i].played = true }
            } else { history.append(BankUse(quizID:quizID,title:title,date:Date(),played:played)) }
            updated.history = history.sorted { $0.date > $1.date }
            let record = try record(entry)
            _ = try save(entry.question,assets:record.assets,existing:updated)
        }
    }
}
extension Studio {
    func recordBankUsage(played: Bool) {
        guard !isEditorPreview else { return }
        let ids = Set(quiz.rounds.flatMap(\.questions).compactMap(\.bankEntryID))
        guard !ids.isEmpty else { return }
        if quiz.bankHistoryID == nil { quiz.bankHistoryID = UUID() }
        do { try questionBank.recordUse(questionIDs:ids,quizID:quiz.bankHistoryID!,title:quiz.title,played:played) }
        catch { status = "Квиз сохранён, но историю банка обновить не удалось: "+error.localizedDescription }
    }
    func applyBulk(ids: Set<UUID>,seconds: Int?,afterMedia: Bool?,answerSeconds: Int?) {
        var copy = quiz
        for ri in copy.rounds.indices { for qi in copy.rounds[ri].questions.indices where ids.contains(copy.rounds[ri].questions[qi].id) {
            if let seconds { copy.rounds[ri].questions[qi].seconds = max(0,min(3600,seconds)) }
            if let afterMedia { copy.rounds[ri].questions[qi].afterMedia = afterMedia }
            if let answerSeconds { copy.rounds[ri].questions[qi].answerSeconds = max(1,min(600,answerSeconds)) }
        } }
        quiz = copy; autosave(); status = "Обновлены настройки выбранных вопросов"
    }
    func applyTemplate(_ template: RoundTemplate,roundID: UUID) {
        guard let i = quiz.rounds.firstIndex(where:{ $0.id == roundID }) else { return }
        var copy = quiz; copy.rounds[i] = template.applying(to:copy.rounds[i]); quiz = copy; autosave(); status = "Применён шаблон: "+template.name
    }
    func beginEditorPreview(from source: Studio,mode: EditorPreviewMode) {
        isEditorPreview = true; rememberRecent = false
        var copy = source.quiz; copy.teams = []
        guard source.quiz.rounds.indices.contains(source.roundIndex) else { return }
        var round = source.quiz.rounds[source.roundIndex]
        if mode != .round { guard let q = source.selectedQuestion else { return }; round.questions = [q] }
        copy.rounds = [round]; quiz = copy; folder = source.folder; registeredFontName = source.registeredFontName
        readBeforeTimer = source.readBeforeTimer; automaticAdvance = true; signalsEnabled = false
        matchLayouts = [:]
        for q in round.questions { if let pairs = q.matchPairs { matchLayouts[q.id] = MatchLayout.make(pairs) } }
        steps = []
        if mode == .round {
            if let intro = round.intro { steps.append(Step(kind:.roundIntro,round:0,duration:intro.seconds)) }
            for (i,q) in round.questions.enumerated() { steps.append(Step(kind:.question,round:0,question:i,duration:q.seconds)) }
            if round.repeatQuestions { steps.append(Step(kind:.repeatIntro,round:0,duration:round.repeatIntroSeconds ?? 5)); for i in round.questions.indices { steps.append(Step(kind:.repeated,round:0,question:i,duration:round.repeatSeconds)) } }
            steps.append(Step(kind:.pause,round:0,duration:round.breakSeconds))
            if round.showAnswers { for (i,q) in round.questions.enumerated() { steps.append(Step(kind:.answerPrompt,round:0,question:i,duration:4)); steps.append(Step(kind:.answer,round:0,question:i,duration:q.answerSeconds)) } }
        } else if let q = round.questions.first { steps.append(Step(kind:mode == .answer ? .answer : .question,round:0,duration:mode == .answer ? q.answerSeconds : q.seconds)) }
        steps.append(Step(kind:.finish,round:0,duration:0))
        index = 0; playing = true; paused = false; enter()
    }
    func endEditorPreview() {
        playing = false; playback.stop(); background.stop(); timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }
}

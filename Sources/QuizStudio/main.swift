import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

struct MatchPair: Codable, Identifiable, Equatable {
    var id = UUID()
    var left = ""
    var right = ""
}
struct MatchLayout {
    var left: [UUID]
    var right: [UUID]
    static func make(_ pairs: [MatchPair]) -> MatchLayout {
        let left = pairs.map(\.id).shuffled()
        var right = pairs.map(\.id).shuffled()
        if right.count > 1 && right == left { right.append(right.removeFirst()) }
        return MatchLayout(left: left,right: right)
    }
    static func letter(_ index: Int) -> String {
        let letters = Array("АБВГДЕЖЗИКЛМНОПРСТУФХЦЧШЩЭЮЯ")
        return index < letters.count ? String(letters[index]) : "Б\(index+1)"
    }
}
struct Question: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var kind = "Открытый вопрос"
    var choices = ["", "", "", ""]
    var answer = ""
    var seconds = 60
    var afterMedia = true
    var image: String? = nil
    var media: String? = nil
    var start: Double = 0
    var end: Double = 0
    var audioOnly = false
    var answerVideo = true
    var answerSeconds = 20
    var bleepRanges = ""
    var selectedChoice: Int? = nil
    var matchPairs: [MatchPair]? = nil
    var explanation: String? = nil
    var explanationImage: String? = nil
    var explanationMedia: String? = nil
    var correctAnswer: String {
        if kind == "Один из четырёх", let selectedChoice, choices.indices.contains(selectedChoice) { return choices[selectedChoice] }
        return answer
    }
    var issues: [String] {
        var result: [String] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("Не заполнен вопрос") }
        if kind == "Сопоставление", let pairs = matchPairs {
            if pairs.count < 2 { result.append("Добавьте минимум две пары") }
            if pairs.contains(where: { $0.left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { result.append("Не заполнены обе части правильных пар") }
        } else {
            if correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("Не указан правильный ответ") }
            if kind == "Один из четырёх" && (choices.count != 4 || choices.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { result.append("Заполните четыре варианта ответа") }
        }
        return result
    }
}
struct RoundIntro: Codable, Equatable {
    var text = ""
    var image: String? = nil
    var media: String? = nil
    var seconds = 20
}
struct Round: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Раунд 1"
    var questions = [Question()]
    var repeatQuestions = false
    var repeatSeconds = 10
    var breakSeconds = 30
    var showAnswers = true
    var standings = false
    var defaultSeconds = 60
    var defaultAfterMedia = true
    var intro: RoundIntro? = nil
}
struct Team: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Новая команда"
    var scores: [String: Int] = [:]
    var total: Int { scores.values.reduce(0,+) }
}
struct Quiz: Codable, Equatable {
    var title = "Новый квиз"
    var rounds = [Round()]
    var teams: [Team] = []
}
struct QuizFile: Codable {
    var version = 1
    var quiz: Quiz
    var assets: [String: Data]
}
struct Step {
    enum Kind { case introduction, roundIntro, question, repeated, answerPrompt, answer, pause, standings, finish }
    var kind: Kind
    var round: Int
    var question: Int = 0
    var duration: Int
    var showsTimer: Bool { [.question,.repeated,.pause].contains(kind) }
}
@MainActor final class Studio: ObservableObject {
    enum Screen { case home, library, createLibrary, editor, teams }
    @Published var screen: Screen = .home
    @Published var introductionSeconds = 6
    @Published var resetScores = true
    @Published var recentQuizzes: [URL] = []
    var rememberRecent = true
    var hiddenQuizzes: Set<String> = []
    let libraryDefaults: UserDefaults
    @Published var quiz = Quiz()
    @Published var roundIndex = 0
    @Published var questionIndex = 0
    @Published var playing = false
    @Published var paused = false
    @Published var remaining = 0
    @Published var index = 0
    @Published var status = ""
    @Published var publishedScores = false
    @Published var player: AVPlayer? = nil
    var steps: [Step] = []
    var matchLayouts: [UUID: MatchLayout] = [:]
    var folder: URL?
    var documentURL: URL?
    var keyMonitor: Any?
    var mediaDone = true
    var waitingForMedia = false
    var elapsed: Double = 0
    var bleep: AVAudioPlayer?
    var transitionElapsed: Double = 0
    var timer: Timer?
    var tv: NSWindow?
    let draft: URL
    var step: Step? { steps.indices.contains(index) ? steps[index] : nil }
    var currentQuestion: Question? {
        guard let s = step, quiz.rounds.indices.contains(s.round), quiz.rounds[s.round].questions.indices.contains(s.question) else { return nil }
        return quiz.rounds[s.round].questions[s.question]
    }
    init(draftURL: URL? = nil, libraryDefaults: UserDefaults? = nil, nearbyFolder: URL? = nil) {
        self.libraryDefaults = libraryDefaults ?? .standard
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuizStudio")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        rememberRecent = draftURL == nil || libraryDefaults != nil
        draft = draftURL ?? support.appendingPathComponent("Draft.workspace")
        if draftURL == nil, !FileManager.default.fileExists(atPath: draft.path) {
            let legacyDraft = support.appendingPathComponent("Draft.quiz")
            if FileManager.default.fileExists(atPath: legacyDraft.path) { try? FileManager.default.copyItem(at: legacyDraft,to: draft) }
        }
        if rememberRecent {
            hiddenQuizzes = Set(self.libraryDefaults.stringArray(forKey: "HiddenQuizzes") ?? [])
            let saved = (self.libraryDefaults.stringArray(forKey: "RecentQuizzes") ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL }
            let nearby = nearbyFolder ?? Bundle.main.bundleURL.deletingLastPathComponent()
            let discovered = ((try? FileManager.default.contentsOfDirectory(at: nearby,includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "quiz" }.map(\.standardizedFileURL)
            var seen: Set<String> = []
            recentQuizzes = (saved + discovered).filter { url in
                !hiddenQuizzes.contains(url.path) && FileManager.default.fileExists(atPath: url.path) && seen.insert(url.path).inserted
            }
        }
        if FileManager.default.fileExists(atPath: draft.path) { load(draft) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.playing, event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return event }
            // Do not steal navigation or spaces from the score table's field editor.
            if event.window is NSPanel || NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if event.isARepeat { return [49,123,124].contains(event.keyCode) ? nil : event }
            return self.handleKey(event.keyCode) ? nil : event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func autosave() { do { try writeDirectory(to: draft)
        if playing || screen == .teams { try persistResults() }
    } catch { status = "Ошибка автосохранения: \(error.localizedDescription)" } }
    func persistResults() throws {
        guard let documentURL else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: documentURL.path,isDirectory: &isDirectory), isDirectory.boolValue {
            try JSONEncoder().encode(quiz.teams).write(to: documentURL.appendingPathComponent("game-results.json"),options: .atomic)
        } else { try write(to: documentURL) }
    }
    @discardableResult func handleKey(_ key: UInt16) -> Bool {
        guard playing else { return false }
        switch key { case 49: togglePause(); case 123: back(); case 124: next(); default: return false }
        return true
    }
    func persistLibrary() {
        guard rememberRecent else { return }
        libraryDefaults.set(recentQuizzes.map(\.path),forKey: "RecentQuizzes")
        libraryDefaults.set(hiddenQuizzes.sorted(),forKey: "HiddenQuizzes")
    }
    func remember(_ url: URL) {
        guard rememberRecent, url.standardizedFileURL != draft.standardizedFileURL else { return }
        let canonical = url.standardizedFileURL
        hiddenQuizzes.remove(canonical.path)
        recentQuizzes.removeAll { $0.standardizedFileURL == canonical }
        recentQuizzes.insert(canonical,at: 0)
        persistLibrary()
    }
    func removeFromLibrary(_ url: URL) {
        let canonical = url.standardizedFileURL
        recentQuizzes.removeAll { $0.standardizedFileURL == canonical }
        hiddenQuizzes.insert(canonical.path)
        persistLibrary()
        status = "Квиз убран из списка. Файл остался на Mac; его можно снова добавить через «Открыть квиз на Mac…»."
    }
    func showLibrary(editing: Bool) { status = ""; screen = editing ? .createLibrary : .library }
    func editQuiz(_ url: URL) {
        autosave()
        if load(url) { screen = .editor }
    }
    func prepareGame() { resetScores = true; status = ""; screen = .teams }
    func beginGame() {
        let names = quiz.teams.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else { status = "Добавьте команды и заполните их названия"; return }
        guard Set(names.map { $0.lowercased() }).count == names.count else { status = "Названия команд должны различаться"; return }
        for i in quiz.teams.indices { quiz.teams[i].name = names[i] }
        // Do not discard a previous game's scores unless the quiz can actually start.
        start()
        if playing {
            if resetScores { for i in quiz.teams.indices { quiz.teams[i].scores = [:] } }
            autosave()
        }
    }
    func writeDirectory(to url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let assets = url.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        if let folder, folder.standardizedFileURL != url.standardizedFileURL {
            for name in referencedAssets {
                guard let source = asset(name) else { throw CocoaError(.fileReadCorruptFile) }
                let dest = assets.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: source,to: dest) }
            }
        }
        try JSONEncoder().encode(quiz).write(to: url.appendingPathComponent("quiz.json"), options: .atomic)
        try JSONEncoder().encode(quiz.teams).write(to: url.appendingPathComponent("game-results.json"),options: .atomic)
    }
    var referencedAssets: [String] {
        Array(Set(quiz.rounds.flatMap { r in
            [r.intro?.image,r.intro?.media].compactMap({$0}) + r.questions.flatMap { q in [q.image,q.media,q.explanationImage,q.explanationMedia].compactMap({$0}) }
        })).sorted()
    }
    func write(to url: URL) throws {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path,isDirectory: &directory), directory.boolValue {
            throw NSError(domain: "QuizStudio",code: 1,userInfo: [NSLocalizedDescriptionKey: "По этому пути находится папка старого квиза. Выберите другое имя для нового файла .quiz."])
        }
        var assets: [String: Data] = [:]
        for name in referencedAssets {
            guard let source = asset(name) else { throw CocoaError(.fileNoSuchFile) }
            assets[name] = try Data(contentsOf: source)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
        try JSONEncoder().encode(QuizFile(quiz: quiz,assets: assets)).write(to: url,options: .atomic)
        var createdDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,isDirectory: &createdDirectory), !createdDirectory.boolValue else { throw CocoaError(.fileWriteUnknown) }
    }
    func leaveEditor() {
        let alert = NSAlert(); alert.messageText = "Сохранить квиз перед выходом в меню?"
        alert.informativeText = "Сохраните отдельный файл .quiz, чтобы продолжить работу позже или перенести игру. Черновик также сохраняется автоматически."
        alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Выйти с черновиком")
        switch alert.runModal() {
        case .alertFirstButtonReturn: if save() { screen = .home }
        case .alertThirdButtonReturn: autosave(); screen = .home
        default: break
        }
    }
    var incompleteQuestions: [String] {
        quiz.rounds.flatMap { r in r.questions.enumerated().compactMap { i,q in q.issues.isEmpty ? nil : "\(r.title), вопрос \(i+1): \(q.issues.joined(separator: "; "))" } }
    }
    @discardableResult func save() -> Bool {
        let issues = incompleteQuestions
        if !issues.isEmpty {
            let alert = NSAlert(); alert.messageText = "Не все вопросы заполнены"
            alert.informativeText = issues.prefix(12).joined(separator: "\n") + (issues.count > 12 ? "\nИ ещё \(issues.count-12)…" : "")
            alert.alertStyle = .warning; alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Всё равно продолжить")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        let panel = NSSavePanel(); panel.title = "Сохранить квиз"; panel.nameFieldStringValue = quiz.title + ".quiz";
        if let documentURL, (try? documentURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { panel.directoryURL = documentURL.deletingLastPathComponent(); panel.nameFieldStringValue = documentURL.lastPathComponent }; panel.allowedContentTypes = [UTType(exportedAs: "local.quizstudio.quiz",conformingTo: .data)]; panel.allowsOtherFileTypes = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try write(to: url); documentURL = url; remember(url); status = "Сохранён файл: \(url.path)"; return true } catch { status = error.localizedDescription; let alert = NSAlert(); alert.messageText = "Не удалось сохранить файл"; alert.informativeText = error.localizedDescription; alert.runModal(); return false }
        }
        return false
    }
    func open(forPlay: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = true; panel.title = "Выберите файл квиза .quiz (или папку старой версии)"
        if panel.runModal() == .OK, let url = panel.url, load(url) { if forPlay { prepareGame() } else { screen = .editor } }
    }
    @discardableResult func load(_ url: URL) -> Bool {
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path,isDirectory: &isDirectory) else { throw CocoaError(.fileNoSuchFile) }
            var decoded: Quiz
            let mediaFolder: URL
            if isDirectory.boolValue {
                decoded = try JSONDecoder().decode(Quiz.self,from: Data(contentsOf: url.appendingPathComponent("quiz.json")))
                let results = url.appendingPathComponent("game-results.json")
                if FileManager.default.fileExists(atPath: results.path) { decoded.teams = try JSONDecoder().decode([Team].self,from: Data(contentsOf: results)) }
                mediaFolder = url
            } else {
                let archive = try JSONDecoder().decode(QuizFile.self,from: Data(contentsOf: url))
                guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                decoded = archive.quiz
                mediaFolder = FileManager.default.temporaryDirectory.appendingPathComponent("QuizStudio-" + UUID().uuidString)
                let media = mediaFolder.appendingPathComponent("Media")
                try FileManager.default.createDirectory(at: media,withIntermediateDirectories: true)
                for (name,data) in archive.assets {
                    guard name == (name as NSString).lastPathComponent, !name.contains("\\"), name != ".", name != ".." else { throw CocoaError(.fileReadCorruptFile) }
                    try data.write(to: media.appendingPathComponent(name),options: .atomic)
                }
            }
            guard !decoded.rounds.isEmpty, decoded.rounds.allSatisfy({ !$0.questions.isEmpty && $0.questions.allSatisfy { $0.choices.count == 4 } }) else { throw CocoaError(.fileReadCorruptFile) }
            quiz = decoded; folder = mediaFolder; documentURL = url.standardizedFileURL == draft.standardizedFileURL ? nil : url
            roundIndex = 0; questionIndex = 0; remember(url); status = ""; return true
        } catch { status = "Не удалось открыть квиз: \(error.localizedDescription)"; return false }
    }
    func newQuiz() { autosave(); screen = .editor; quiz = Quiz(); folder = nil; documentURL = nil; roundIndex = 0; questionIndex = 0; status = "Создан новый квиз" }
    func attach(image: Bool, explanation: Bool = false, roundIntro: Bool = false) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = image ? [.image] : [.audio,.movie]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let root = folder ?? draft
                let dir = root.appendingPathComponent("Media")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = UUID().uuidString + "." + url.pathExtension
                try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
                folder = root
                if roundIntro {
                    if image { quiz.rounds[roundIndex].intro?.image = name } else { quiz.rounds[roundIndex].intro?.media = name }
                } else if explanation {
                    if image { quiz.rounds[roundIndex].questions[questionIndex].explanationImage = name }
                    else { quiz.rounds[roundIndex].questions[questionIndex].explanationMedia = name }
                } else if image { quiz.rounds[roundIndex].questions[questionIndex].image = name }
                else { quiz.rounds[roundIndex].questions[questionIndex].media = name }
            } catch { status = error.localizedDescription }
        }
    }
    func asset(_ name: String?) -> URL? { guard let name, let folder, name == (name as NSString).lastPathComponent, !name.contains("\\"), name != ".", name != ".." else { return nil }; return folder.appendingPathComponent("Media").appendingPathComponent(name) }
    func addRound() { quiz.rounds.append(Round(title: "Раунд \(quiz.rounds.count + 1)")); roundIndex = quiz.rounds.count-1; questionIndex = 0 }
    func applyTime() {
        let q = quiz.rounds[roundIndex].questions[questionIndex]
        quiz.rounds[roundIndex].defaultSeconds = q.seconds
        quiz.rounds[roundIndex].defaultAfterMedia = q.afterMedia
        for i in quiz.rounds[roundIndex].questions.indices { quiz.rounds[roundIndex].questions[i].seconds = q.seconds; quiz.rounds[roundIndex].questions[i].afterMedia = q.afterMedia }
    }
    func addQuestion() {
        let round = quiz.rounds[roundIndex]
        var q = Question(); q.seconds = round.defaultSeconds; q.afterMedia = round.defaultAfterMedia
        quiz.rounds[roundIndex].questions.append(q); questionIndex = quiz.rounds[roundIndex].questions.count-1
    }
    func start() {
        for name in referencedAssets { guard let url = asset(name), FileManager.default.fileExists(atPath: url.path) else { status = "Не найден медиафайл"; return } }
        for r in quiz.rounds { for q in r.questions {
            if !q.issues.isEmpty { status = "\(r.title): \(q.issues.joined(separator: "; "))"; return }
            for name in [q.image,q.media,q.explanationImage,q.explanationMedia].compactMap({$0}) { if let url = asset(name), !FileManager.default.fileExists(atPath: url.path) { status = "Не найден медиафайл"; return } }
            if q.start < 0 || q.end < 0 || (q.end > 0 && q.end <= q.start) { status = "Конец фрагмента должен быть позже начала"; return }
        } }
        autosave(); steps = []; matchLayouts = [:]
        for r in quiz.rounds { for q in r.questions { if let pairs = q.matchPairs { matchLayouts[q.id] = MatchLayout.make(pairs) } } }
        for i in quiz.teams.indices { steps.append(Step(kind: .introduction,round: 0,question: i,duration: introductionSeconds)) }
        for (ri,r) in quiz.rounds.enumerated() {
            if let intro = r.intro { steps.append(Step(kind: .roundIntro,round: ri,duration: intro.seconds)) }
            for (qi,q) in r.questions.enumerated() { steps.append(Step(kind: .question,round: ri,question: qi,duration: q.seconds)) }
            if r.repeatQuestions { for qi in r.questions.indices { steps.append(Step(kind: .repeated,round: ri,question: qi,duration: r.repeatSeconds)) } }
            steps.append(Step(kind: .pause,round: ri,duration: r.breakSeconds))
            if r.showAnswers { for (qi,q) in r.questions.enumerated() { steps.append(Step(kind: .answerPrompt,round: ri,question: qi,duration: 4)); steps.append(Step(kind: .answer,round: ri,question: qi,duration: q.answerSeconds)) } }
            if r.standings { steps.append(Step(kind: .standings,round: ri,duration: 0)) }
        }
        steps.append(Step(kind: .finish,round: max(0,quiz.rounds.count-1),duration: 0))
        playing = true; paused = false; index = 0; enter()
    }
    func enter() {
        player?.pause(); bleep?.stop(); player = nil; transitionElapsed = 0; publishedScores = false; mediaDone = true; waitingForMedia = false; elapsed = 0
        guard let s = step else { return }; remaining = s.duration
        if s.kind == .roundIntro, let url = asset(quiz.rounds[s.round].intro?.media) {
            let p = AVPlayer(url: url); player = p; mediaDone = false; if !paused { p.play() }; return
        }
        if [.question,.repeated,.answer].contains(s.kind), let q = currentQuestion, let url = asset(s.kind == .answer ? (q.explanationMedia ?? q.media) : q.media) {
            mediaDone = false; waitingForMedia = s.kind == .question && q.afterMedia
            let p = AVPlayer(url: url); player = p
            p.seek(to: CMTime(seconds: s.kind == .answer && q.explanationMedia != nil ? 0 : q.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if !paused { p.play() }
        }
    }
    func tick() {
        guard playing, !paused, let s = step else { return }
        if s.kind == .roundIntro, !mediaDone, let p = player {
            let duration = p.currentItem?.duration.seconds ?? .nan
            if (duration.isFinite && p.currentTime().seconds >= duration-0.15) || p.currentItem?.status == .failed { p.pause(); mediaDone = true }
        }
        if s.kind != .roundIntro, !mediaDone, let p = player, let q = currentQuestion {
            let t = p.currentTime().seconds
            let censored = s.kind != .answer && q.bleepRanges.split(separator: ",").contains { range in
                let parts = range.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return parts.count == 2 && t >= parts[0] && t < parts[1]
            }
            p.volume = censored ? 0 : 1
            if censored { if bleep == nil { bleep = try? AVAudioPlayer(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bleep.wav")); bleep?.numberOfLoops = -1 }; if bleep?.isPlaying != true { bleep?.play() } } else { bleep?.stop() }
            let duration = p.currentItem?.duration.seconds ?? .nan
            let fragmentEnd = s.kind == .answer && q.explanationMedia != nil ? 0 : q.end
            if (fragmentEnd > 0 && t >= fragmentEnd) || (duration.isFinite && t >= duration-0.15) || p.currentItem?.status == .failed {
                p.pause(); bleep?.stop(); mediaDone = true; waitingForMedia = false
            }
        }
        guard ![.standings,.finish].contains(s.kind), s.duration > 0, !waitingForMedia else { return }
        elapsed += 0.2
        if elapsed >= 1 { remaining = max(0, remaining-1); elapsed -= 1 }
        if remaining == 0 && mediaDone { transitionElapsed += 0.2; if [.introduction,.answerPrompt,.repeated].contains(s.kind) || transitionElapsed >= 2 { next() } }
    }
    func togglePause() { paused.toggle(); if paused { player?.pause(); bleep?.stop() } else if !mediaDone { player?.play() } }
    func next() { if index+1 < steps.count { index += 1; enter() } }
    func back() { if index > 0 { index -= 1; enter() } }
    func stop() { autosave(); player?.pause(); bleep?.stop(); player = nil; playing = false; screen = .editor; tv?.close(); tv = nil }
    func returnToMenu() { stop(); screen = .home }
    func showTV() {
        if tv != nil { tv?.makeKeyAndOrderFront(nil); return }
        let screen = NSScreen.screens.dropFirst().first ?? NSScreen.main!
        let window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Квиз — экран участников"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Stage(studio: self, audience: true))
        window.makeKeyAndOrderFront(nil); tv = window
        if NSScreen.screens.count > 1 { window.toggleFullScreen(nil) }
    }
}

@main struct QuizStudioApp: App {
    @StateObject var studio = Studio()
    var body: some Scene {
        WindowGroup("Квиз Студия · 0.6.0") { Content(studio: studio).frame(minWidth: 1050,minHeight: 720).onChange(of: studio.quiz) { _,_ in studio.autosave() }.onOpenURL { url in if !studio.playing && studio.load(url) { studio.prepareGame() } } }
        .commands { CommandGroup(replacing: .newItem) { Button("Создать квиз") { studio.newQuiz() }.keyboardShortcut("n").disabled(studio.playing); Button("Открыть квиз…") { studio.open() }.keyboardShortcut("o").disabled(studio.playing); Button("Сохранить квиз…") { studio.save() }.keyboardShortcut("s") } }
    }
}
struct Content: View {
    @ObservedObject var studio: Studio
    var body: some View {
        Group {
            if studio.playing { PlayerView(studio: studio) }
            else { switch studio.screen {
                case .home: Welcome(studio: studio)
                case .library: QuizLibrary(studio: studio)
                case .createLibrary: QuizLibrary(studio: studio,editing: true)
                case .teams: TeamSetup(studio: studio)
                case .editor: Editor(studio: studio)
            } }
        }
        .tint(.indigo)
    }
}
struct Editor: View {
    @ObservedObject var studio: Studio
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading,spacing: 16) {
                Text("КВИЗ СТУДИЯ").font(.headline).foregroundStyle(.secondary).padding(.horizontal)
                List {
                    ForEach(Array(studio.quiz.rounds.enumerated()),id: \.element.id) { ri,r in
                        Section(r.title) {
                            ForEach(Array(r.questions.enumerated()),id: \.element.id) { qi,q in
                                Button { studio.roundIndex = ri; studio.questionIndex = qi } label: {
                                    HStack { Image(systemName: !q.issues.isEmpty ? "exclamationmark.triangle.fill" : q.media == nil ? "text.bubble" : "play.rectangle"); Text(q.text.isEmpty ? "Вопрос \(qi+1)" : q.text).lineLimit(1) }
                                    .padding(6).frame(maxWidth: .infinity,alignment: .leading)
                                    .background(studio.roundIndex == ri && studio.questionIndex == qi ? Color.indigo.opacity(0.15) : .clear,in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                                .foregroundStyle(q.issues.isEmpty ? Color.primary : Color.orange)
                                .help(q.issues.isEmpty ? "Вопрос заполнен" : q.issues.joined(separator: "\n"))
                            }
                        }
                    }
                }
                Button("Следующий раунд",systemImage: "plus.rectangle.on.rectangle") { studio.addRound() }.padding()
            }.padding(.top)
            .navigationSplitViewColumnWidth(min: 220,ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    TextField("Название квиза",text: $studio.quiz.title).font(.title2.bold()).textFieldStyle(.plain)
                    Button("Главная") { studio.leaveEditor() }; Button("Создать") { studio.newQuiz() }; Button("Открыть") { studio.open() }
                    Button("Завершить и сохранить") { studio.save() }
                    Button("Старт",systemImage: "play.fill") { studio.prepareGame() }.buttonStyle(.borderedProminent)
                }.padding(22)
                Divider()
                ScrollView { VStack(alignment: .leading,spacing: 24) {
                    RoundSettings(studio: studio, round: $studio.quiz.rounds[studio.roundIndex])
                    QuestionEditor(studio: studio,question: $studio.quiz.rounds[studio.roundIndex].questions[studio.questionIndex])
                    HStack {
                        Button("Добавить вопрос",systemImage: "plus") { studio.addQuestion() }.buttonStyle(.borderedProminent)
                        if studio.quiz.rounds[studio.roundIndex].questions.count > 1 {
                            Button("Удалить вопрос",role: .destructive) { studio.quiz.rounds[studio.roundIndex].questions.remove(at: studio.questionIndex); studio.questionIndex = 0 }
                        }
                    }
                }.padding(24) }
                Text(studio.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading).padding(10)
            }
        }
    }
}
struct RoundSettings: View {
    @ObservedObject var studio: Studio
    @Binding var round: Round
    @State var editingIntro = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading,spacing: 12) {
                TextField("Название раунда",text: $round.title).font(.title3.bold())
                HStack { Toggle("Повтор вопросов",isOn: $round.repeatQuestions); if round.repeatQuestions { Stepper("По \(round.repeatSeconds) сек",value: $round.repeatSeconds,in: 1...300) } }
                Stepper("Сдача бланков: \(round.breakSeconds == 0 ? "до команды ведущего" : "\(round.breakSeconds) сек")",value: $round.breakSeconds,in: 0...600,step: 5)
                Toggle("Показать ответы после раунда",isOn: $round.showAnswers)
                Toggle("Промежуточные итоги после раунда",isOn: $round.standings)
                HStack {
                    Button(round.intro == nil ? "Добавить объяснение раунда" : "Редактировать объяснение раунда",systemImage: "info.bubble") {
                        if round.intro == nil { round.intro = RoundIntro() }; editingIntro = true
                    }
                    if round.intro != nil { Button("Убрать объяснение",role: .destructive) { round.intro = nil } }
                }
            }.padding(8)
        } label: { Label("Настройки раунда",systemImage: "rectangle.stack") }
        .sheet(isPresented: $editingIntro) {
            RoundIntroEditor(studio: studio,intro: Binding(get: { round.intro ?? RoundIntro() },set: { round.intro = $0 }))
        }
    }
}
struct QuestionEditor: View {
    @ObservedObject var studio: Studio
    @Binding var question: Question
    @State var preview: AVPlayer?
    @State var explanationPreview: AVPlayer?
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack { Text("Вопрос \(studio.questionIndex+1)").font(.title.bold()); Spacer(); Picker("Тип",selection: $question.kind) { ForEach(["Открытый вопрос","Один из четырёх","Сопоставление"],id: \.self) { Text($0) } }.frame(width: 300) }
            TextEditor(text: $question.text).font(.title3).frame(height: 100).padding(8).background(.background,in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            if question.kind == "Один из четырёх" {
                Text("Нажмите кружок рядом с правильным вариантом").font(.caption).foregroundStyle(.secondary)
                ForEach(0..<4,id: \.self) { i in
                    HStack {
                        Button { question.selectedChoice = i; question.answer = question.choices[i] } label: {
                            Image(systemName: (question.selectedChoice == i || (question.selectedChoice == nil && !question.answer.isEmpty && question.answer == question.choices[i])) ? "checkmark.circle.fill" : "circle").foregroundStyle(.indigo).font(.title2)
                        }.buttonStyle(.plain).help("Выбрать правильный ответ")
                        TextField("\(i+1). Вариант ответа",text: $question.choices[i])
                    }
                }
            } else if question.kind == "Сопоставление" {
                MatchingEditor(question: $question)
            } else { TextField("Правильный ответ",text: $question.answer) }
            HStack { Stepper("Время: \(question.seconds == 0 ? "без таймера" : "\(question.seconds) сек")",value: $question.seconds,in: 0...600,step: 5); Button("Применить время и запуск таймера ко всему раунду") { studio.applyTime() } }
            HStack { Button("Добавить картинку",systemImage: "photo") { studio.attach(image: true) }; Button("Добавить аудио / видео",systemImage: "film") { studio.attach(image: false) } }
            if let url = studio.asset(question.image), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                Button("Убрать картинку") { question.image = nil }
            }
            if question.media != nil {
                GroupBox("Фрагмент аудио / видео") {
                    VStack(alignment: .leading,spacing: 12) {
                        HStack { Text("Начало, сек"); TextField("0",value: $question.start,format: .number).frame(width: 80); Text("Конец, сек (0 — до конца)"); TextField("0",value: $question.end,format: .number).frame(width: 80) }
                        Toggle("В вопросе — только звук",isOn: $question.audioOnly)
                        Picker("Запуск таймера",selection: $question.afterMedia) { Text("Вместе с фрагментом").tag(false); Text("После фрагмента").tag(true) }.pickerStyle(.segmented)
                        Toggle("Показывать видео при ответе",isOn: $question.answerVideo)
                        TextField("Запикать интервалы, например 12-14, 20-22 (секунды исходного файла)",text: $question.bleepRanges)
                        Text("При показе ответа звучит оригинал. Предпросмотр ниже воспроизводит исходный фрагмент.").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("Просмотреть фрагмент") {
                            guard let url = studio.asset(question.media) else { return }
                            preview?.pause(); let p = AVPlayer(url: url); p.seek(to: CMTime(seconds: max(0,question.start),preferredTimescale: 600)); if question.end > 0 { p.currentItem?.forwardPlaybackEndTime = CMTime(seconds: question.end,preferredTimescale: 600) }; preview = p; p.play()
                        }; Button("Убрать медиа") { preview?.pause(); preview = nil; question.media = nil } }
                        if let preview { VideoPlayer(player: preview).frame(height: 200) }
                    }.padding(8)
                }
            }
            GroupBox("Объяснение ответа — по желанию") {
                VStack(alignment: .leading,spacing: 12) {
                    TextEditor(text: Binding(get: { question.explanation ?? "" },set: { question.explanation = $0 })).frame(height: 80)
                    HStack {
                        Button("Добавить картинку") { studio.attach(image: true,explanation: true) }
                        Button("Добавить аудио / видео") { studio.attach(image: false,explanation: true) }
                    }
                    if let url = studio.asset(question.explanationImage), let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                        Button("Убрать картинку объяснения") { question.explanationImage = nil }
                    }
                    if let url = studio.asset(question.explanationMedia) {
                        HStack {
                            Button("Предпросмотр объяснения") { explanationPreview?.pause(); preview?.pause(); explanationPreview = AVPlayer(url: url); explanationPreview?.play() }
                            Button("Убрать медиа объяснения") { explanationPreview?.pause(); explanationPreview = nil; question.explanationMedia = nil }
                        }
                        if let explanationPreview { VideoPlayer(player: explanationPreview).frame(height: 180) }
                        Text("При показе ответа этот файл воспроизводится вместо медиа вопроса и до конца.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            HStack { Stepper("Показ ответа: \(question.answerSeconds) сек",value: $question.answerSeconds,in: 5...600,step: 5); Button("Применить ко всем ответам раунда") { let seconds = question.answerSeconds; for i in studio.quiz.rounds[studio.roundIndex].questions.indices { studio.quiz.rounds[studio.roundIndex].questions[i].answerSeconds = seconds } } }
        }.textFieldStyle(.roundedBorder)
        .onChange(of: question.kind) { _,kind in
            if kind == "Сопоставление" && question.matchPairs == nil { question.matchPairs = [MatchPair(),MatchPair()] }
        }
        .onChange(of: question.id) { _,_ in preview?.pause(); preview = nil; explanationPreview?.pause(); explanationPreview = nil }
        .onDisappear { preview?.pause(); explanationPreview?.pause() }
    }
}
struct PlayerView: View {
    @ObservedObject var studio: Studio
    @State var controls = true
    @State var hideTask: Task<Void,Never>?
    var body: some View {
        VStack(spacing: 0) {
            if studio.step?.kind == .standings && !studio.publishedScores {
                ScoreEditor(studio: studio)
            } else { Stage(studio: studio,audience: false) }
        }
        .overlay(alignment: .bottom) {
            if studio.step?.kind == .finish {
                Button("Вернуться в меню") { studio.returnToMenu() }.buttonStyle(.borderedProminent).controlSize(.large).padding(28)
            } else if controls || studio.paused {
                HStack(spacing: 18) {
                    Button("Редактор") { studio.stop() }
                    Button("Назад") { studio.back() }
                    Button(studio.paused ? "Продолжить" : "Пауза") { studio.togglePause() }
                    Button("Вперёд") { studio.next() }
                    Button("+30 сек") { studio.remaining += 30 }
                    Button("Заново") { studio.enter() }
                    Button("Экран ТВ") { studio.showTV() }
                    Button("На весь экран") { NSApp.keyWindow?.toggleFullScreen(nil) }
                }.buttonStyle(.bordered).padding().background(.regularMaterial,in: Capsule()).padding(20)
            }
        }.onAppear {
            hideTask = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled && !studio.paused { controls = false } }
        }.onDisappear { hideTask?.cancel() }
        .onChange(of: studio.paused) { _,paused in
            hideTask?.cancel()
            if paused { controls = true }
            else { hideTask = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled && !studio.paused { controls = false } } }
        }.onContinuousHover { phase in
            if case .active = phase { controls = true; hideTask?.cancel(); hideTask = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled && !studio.paused { controls = false } } }
        }
    }
}
struct Stage: View {
    @ObservedObject var studio: Studio
    var audience: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.06,green: 0.07,blue: 0.17),Color(red: 0.18,green: 0.12,blue: 0.35)],startPoint: .topLeading,endPoint: .bottomTrailing)
                if let s = studio.step {
                    VStack(spacing: 24) {
                        Text(studio.quiz.title.uppercased()).font(.system(size: 18,weight: .semibold)).tracking(4).foregroundStyle(.white.opacity(0.5))
                        switch s.kind {
                        case .introduction:
                            if studio.quiz.teams.indices.contains(s.question) {
                                Text("Встречаем команду!").font(.title).foregroundStyle(.white.opacity(0.7))
                                Text(studio.quiz.teams[s.question].name).font(.system(size: 64,weight: .bold)).multilineTextAlignment(.center)
                                Text("Ваши аплодисменты").font(.title2).foregroundStyle(.orange)
                            }
                        case .roundIntro:
                            if let intro = studio.quiz.rounds[s.round].intro {
                                Text(studio.quiz.rounds[s.round].title).font(.system(size: 46,weight: .bold))
                                Text(intro.text).font(.title).multilineTextAlignment(.center)
                                if let player = studio.player { VideoPlayer(player: player).disabled(true).frame(height: geometry.size.height*0.35) }
                                if let url = studio.asset(intro.image), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: geometry.size.height*0.3) }
                            }
                        case .pause: Text("Сдаём бланки").font(.system(size: 52,weight: .bold)); Text("Спасибо! Скоро продолжим").font(.title)
                        case .finish: Text("Спасибо за игру!").font(.system(size: 56,weight: .bold))
                        case .standings:
                            if studio.publishedScores { Scores(studio: studio) } else { Text("Подводим итоги").font(.system(size: 52,weight: .bold)); Text("Небольшой перерыв").font(.title) }
                        default:
                            if let q = studio.currentQuestion {
                                Text("\(studio.quiz.rounds[s.round].title) · \(s.kind == .answer ? "Ответ" : s.kind == .answerPrompt ? "Ответ" : s.kind == .repeated ? "Повтор" : "Вопрос") \(s.question+1)").font(.title3).foregroundStyle(.white.opacity(0.65))
                                Text(q.text).font(.system(size: min(48,geometry.size.width/22),weight: .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false,vertical: true)
                                if s.kind == .answer || s.kind == .answerPrompt {
                                    Group {
                                        if s.kind == .answer && !(q.kind == "Сопоставление" && q.matchPairs != nil) {
                                            Text(q.correctAnswer).font(.system(size: 38,weight: .bold)).foregroundStyle(.green).multilineTextAlignment(.center)
                                        } else if s.kind == .answerPrompt { Text(" ").font(.system(size: 38,weight: .bold)) }
                                    }.frame(maxWidth: .infinity,minHeight: 70).padding(12).background(.white.opacity(s.kind == .answer ? 0.07 : 0),in: RoundedRectangle(cornerRadius: 12))
                                }
                                if q.kind == "Сопоставление", let pairs = q.matchPairs {
                                    MatchingBoard(pairs: pairs,layout: studio.matchLayouts[q.id] ?? MatchLayout(left: pairs.map(\.id),right: pairs.map(\.id)),reveal: s.kind == .answer)
                                }
                                if s.kind == .answer, let explanation = q.explanation, !explanation.isEmpty { Text(explanation).font(.title2).multilineTextAlignment(.center) }
                                if s.kind != .answer && q.kind == "Один из четырёх" { LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())],spacing: 12) { ForEach(0..<4,id: \.self) { i in Text("\(i+1). \(q.choices[i])").font(.title2).padding().frame(maxWidth: .infinity,alignment: .leading).background(.white.opacity(0.08),in: RoundedRectangle(cornerRadius: 12)) } } }
                                if let p = studio.player {
                                    if s.kind == .answer ? (q.explanationMedia != nil || q.answerVideo) : !q.audioOnly { VideoPlayer(player: p).disabled(true).frame(height: geometry.size.height*0.38) }
                                    else { Label("Аудиофрагмент",systemImage: "waveform").font(.title).padding(30) }
                                }
                                if let url = studio.asset(s.kind == .answer ? (q.explanationImage ?? q.image) : q.image), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: geometry.size.height*(studio.player == nil ? 0.4 : 0.2)) }
                            }
                        }
                        if s.showsTimer { Text(studio.waitingForMedia ? "Слушаем и смотрим…" : (s.duration == 0 ? "Продолжит ведущий" : (studio.remaining == 0 ? (s.kind == .repeated ? "" : "Время вышло") : "\(studio.remaining / 60):\(String(format: "%02d",studio.remaining % 60))"))).font(.system(size: 36,weight: .medium,design: .monospaced)).foregroundStyle(studio.remaining <= 10 && !studio.waitingForMedia ? .orange : .white) }
                        if studio.paused { Text("ПАУЗА").font(.headline).tracking(4).foregroundStyle(.orange) }
                    }.padding(40).padding(.bottom,50).frame(maxWidth: 1100).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: [.answerPrompt,.answer].contains(s.kind) ? .top : .center)
                }
            }.foregroundStyle(.white)
        }
    }
}
struct ScoreEditor: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment: .leading,spacing: 20) {
            Text("Промежуточные итоги").font(.largeTitle.bold())
            Text("На отдельном экране ТВ остаётся заставка. В режиме дублирования экрана таблица ввода будет видна всем.").foregroundStyle(.secondary)
            ScrollView([.horizontal,.vertical]) {
                VStack(alignment: .leading) {
                    HStack { Text("Команда").frame(width: 200); ForEach(studio.quiz.rounds) { r in Text(r.title).frame(width: 100) }; Text("Всего").frame(width: 70) }
                    ForEach($studio.quiz.teams) { $team in
                        HStack {
                            Text(team.name).frame(width: 200,alignment: .leading)
                            ForEach(studio.quiz.rounds) { r in ScoreField(value: Binding(get: { team.scores[r.id.uuidString] ?? 0 },set: { team.scores[r.id.uuidString] = $0 })).frame(width: 100) }
                            Text("\(team.total)").frame(width: 70)
                        }
                    }
                }.textFieldStyle(.roundedBorder)
            }
            HStack { Button("Показать итоги") { studio.publishedScores = true }.buttonStyle(.borderedProminent) }
            Spacer()
        }.padding(40).padding(.bottom,70)
    }
}
struct Scores: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 12) {
            Text("Результаты игры").font(.system(size: 44,weight: .bold))
            ForEach(studio.quiz.teams.sorted { $0.total == $1.total ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.total > $1.total }) { team in
                HStack { Text("\(1 + studio.quiz.teams.filter { $0.total > team.total }.count)").foregroundStyle(.orange).frame(width: 50); Text(team.name); Spacer(); Text("\(team.total)").bold() }.font(.title).padding(10).background(.white.opacity(0.07),in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct Welcome: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "sparkles.tv").font(.system(size: 72)).foregroundStyle(.indigo)
            Text("Квиз Студия").font(.system(size: 46,weight: .bold))
            Text("Создайте игру или проведите готовый квиз").font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button { studio.showLibrary(editing: true) } label: { entry("Создать квиз","Новый квиз или редактирование готового","square.and.pencil") }
                Button { studio.showLibrary(editing: false) } label: { entry("Запустить квиз","Выбрать игру и представить команды","play.rectangle") }
            }.buttonStyle(.plain)
            Button("Продолжить редактирование черновика") { studio.screen = .editor }
            Text(studio.status).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: .infinity,maxHeight: .infinity).background(Color.indigo.opacity(0.04))
    }
    func entry(_ title: String,_ subtitle: String,_ icon: String) -> some View {
        VStack(alignment: .leading,spacing: 18) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.indigo)
            Text(title).font(.title2.bold()); Text(subtitle).foregroundStyle(.secondary)
        }.padding(30).frame(width: 340,height: 170,alignment: .leading).background(.background,in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.quaternary))
    }
}
struct QuizLibrary: View {
    @ObservedObject var studio: Studio
    var editing = false
    @State var search = ""
    var visibleQuizzes: [URL] {
        studio.recentQuizzes.filter { search.isEmpty || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 24) {
            HStack {
                Button("Главная") { studio.screen = .home }
                Spacer()
                Button("Открыть квиз на Mac…") { studio.open(forPlay: !editing) }
                if editing { Button("Создать с нуля",systemImage: "plus") { studio.newQuiz() }.buttonStyle(.borderedProminent) }
            }
            Text(editing ? "Создать или редактировать квиз" : "Запустить квиз").font(.largeTitle.bold())
            Text(editing ? "Откройте сохранённый квиз для правок или начните новый с нуля." : "Выберите квиз для проведения. Его также можно открыть для редактирования.").foregroundStyle(.secondary)
            TextField("Найти квиз по названию",text: $search).textFieldStyle(.roundedBorder)
            if studio.recentQuizzes.isEmpty {
                ContentUnavailableView("Пока нет сохранённых квизов",systemImage: "rectangle.stack",description: Text(editing ? "Создайте квиз с нуля или откройте файл на Mac." : "Нажмите «Открыть квиз на Mac…» и укажите файл .quiz"))
            } else if visibleQuizzes.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(visibleQuizzes,id: \.path) { url in
                    HStack(spacing: 16) {
                        Image(systemName: "doc.text").font(.title2).foregroundStyle(.indigo)
                        VStack(alignment: .leading,spacing: 5) {
                            Text(url.deletingPathExtension().lastPathComponent).font(.headline)
                            Text(((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "Папка старого формата · " : "Файл .quiz · ") + url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Редактировать",systemImage: "square.and.pencil") { studio.editQuiz(url) }
                        if !editing { Button("Запустить",systemImage: "play.fill") { if studio.load(url) { studio.prepareGame() } }.buttonStyle(.borderedProminent) }
                        Button { studio.removeFromLibrary(url) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Убрать из списка. Файл останется на Mac.").accessibilityLabel("Убрать из списка: " + url.deletingPathExtension().lastPathComponent)
                    }.padding(10)
                }
            }
            Text(studio.status).foregroundStyle(.secondary)
            Text("Удаление из списка не удаляет файл. Чтобы вернуть квиз, откройте его на Mac заново.").font(.caption).foregroundStyle(.secondary)
        }.padding(36)
    }
}
struct TeamSetup: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment: .leading,spacing: 20) {
            HStack { Button("Назад") { studio.screen = .library }; Spacer(); Button("Открыть редактор") { studio.screen = .editor } }
            Text("Команды на игру").font(.largeTitle.bold())
            Text(studio.quiz.title).font(.title2).foregroundStyle(.secondary)
            Text("Введите команды один раз. Перед первым раундом каждая появится на экране, а в итогах останется только заполнить баллы.")
            List {
                ForEach($studio.quiz.teams) { $team in
                    HStack {
                        Image(systemName: "person.3.fill").foregroundStyle(.indigo)
                        TextField("Название команды",text: $team.name).textFieldStyle(.roundedBorder)
                        if team.total != 0 { Text("\(team.total) баллов").foregroundStyle(.secondary) }
                        Button("Удалить",role: .destructive) { studio.quiz.teams.removeAll { $0.id == team.id } }
                    }.padding(6)
                }
            }
            Button("Добавить команду",systemImage: "plus") { studio.quiz.teams.append(Team(name: "")) }
            Stepper("Представление каждой команды: \(studio.introductionSeconds) сек",value: $studio.introductionSeconds,in: 3...30)
            Toggle("Начать новую игру — обнулить прошлые баллы",isOn: $studio.resetScores)
            Text("Снимите галочку, чтобы сохранить уже введённые результаты. Названия команд сохраняются в обоих случаях.").font(.caption).foregroundStyle(.secondary)
            HStack { Text(studio.status).foregroundStyle(.secondary); Spacer(); Button("Начать игру",systemImage: "play.fill") { studio.beginGame() }.buttonStyle(.borderedProminent).disabled(studio.quiz.teams.isEmpty) }
        }.padding(36)
    }
}

struct MatchingEditor: View {
    @Binding var question: Question
    var pairs: Binding<[MatchPair]> { Binding(get: { question.matchPairs ?? [] },set: { question.matchPairs = $0 }) }
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("Введите правильные пары в одной строке. В игре столбцы перемешаются, а при повторе порядок сохранится.").font(.caption).foregroundStyle(.secondary)
            if question.matchPairs == nil {
                Text("Это вопрос старого формата. Заполните пары, чтобы перейти к двум столбцам.").font(.caption)
                Button("Создать столбцы") { question.matchPairs = [MatchPair(),MatchPair()] }
                TextField("Ответ старого формата",text: $question.answer)
            } else {
                HStack { Text("Левая часть").frame(maxWidth: .infinity,alignment: .leading); Text("Правильное соответствие").frame(maxWidth: .infinity,alignment: .leading); Spacer().frame(width: 30) }.font(.headline)
                ForEach(pairs) { $pair in
                    HStack {
                        TextField("Например: Франция",text: $pair.left)
                        TextField("Например: Париж",text: $pair.right)
                        Button { question.matchPairs?.removeAll { $0.id == pair.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Добавить пару",systemImage: "plus") { question.matchPairs?.append(MatchPair()) }.disabled((question.matchPairs?.count ?? 0) >= 20)
            }
        }.onChange(of: question.kind) { _,kind in if kind == "Сопоставление" && question.matchPairs == nil { question.matchPairs = [MatchPair(),MatchPair()] } }
    }
}
struct MatchingBoard: View {
    let pairs: [MatchPair]
    let layout: MatchLayout
    let reveal: Bool
    var body: some View {
        HStack(alignment: .top,spacing: 35) {
            VStack(alignment: .leading,spacing: 14) {
                ForEach(Array(layout.left.enumerated()),id: \.element) { i,id in
                    if let pair = pairs.first(where: { $0.id == id }) {
                        HStack(alignment: .top) { Text("\(i+1).").foregroundStyle(.orange); Text(pair.left); if reveal, let right = layout.right.firstIndex(of: id) { Text("→ \(MatchLayout.letter(right))").bold().foregroundStyle(.green) } }.frame(maxWidth: .infinity,alignment: .leading)
                    }
                }
            }
            VStack(alignment: .leading,spacing: 14) {
                ForEach(Array(layout.right.enumerated()),id: \.element) { i,id in
                    if let pair = pairs.first(where: { $0.id == id }) { HStack(alignment: .top) { Text("\(MatchLayout.letter(i)).").foregroundStyle(.orange); Text(pair.right) }.frame(maxWidth: .infinity,alignment: .leading) }
                }
            }
        }.font(.title2).padding(20).background(.white.opacity(0.06),in: RoundedRectangle(cornerRadius: 14))
    }
}
class SelectableScoreTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        selectZero()
    }
    func selectZero() {
        guard stringValue == "0", let editor = currentEditor() else { return }
        editor.string = ""
        editor.selectedRange = NSRange(location: 0,length: 0)
    }
    override func becomeFirstResponder() -> Bool {
        let success = super.becomeFirstResponder()
        if success { DispatchQueue.main.async { [weak self] in guard let self, let editor = self.currentEditor() else { return }; if self.stringValue == "0" { editor.string = ""; editor.selectedRange = NSRange(location: 0,length: 0) } else { editor.selectedRange = NSRange(location: 0,length: (self.stringValue as NSString).length) } } }
        return success
    }
}
struct ScoreField: NSViewRepresentable {
    @Binding var value: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SelectableScoreTextField {
        let field = SelectableScoreTextField(); field.delegate = context.coordinator; field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.stringValue = String(value); field.alignment = .right; field.setContentHuggingPriority(.defaultLow,for: .horizontal)
        return field
    }
    func updateNSView(_ field: SelectableScoreTextField,context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil { field.stringValue = String(value) }
    }
    final class Coordinator: NSObject,NSTextFieldDelegate {
        var parent: ScoreField
        init(_ parent: ScoreField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? SelectableScoreTextField else { return }
            field.selectZero()
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let number = Int(field.stringValue) { parent.value = number }
            else if field.stringValue.isEmpty { parent.value = 0 }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }; field.stringValue = String(parent.value)
        }
    }
}

struct RoundIntroEditor: View {
    @ObservedObject var studio: Studio
    @Binding var intro: RoundIntro
    @Environment(\.dismiss) var dismiss
    @State var preview: AVPlayer?
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("Объяснение раунда").font(.largeTitle.bold())
            Text("Этот экран появится перед первым вопросом раунда.").foregroundStyle(.secondary)
            TextEditor(text: $intro.text).font(.title3).frame(height: 140).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Button("Добавить картинку") { studio.attach(image: true,roundIntro: true) }
                Button("Добавить аудио / видео") { studio.attach(image: false,roundIntro: true) }
            }
            if let url = studio.asset(intro.image), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                Button("Убрать картинку") { intro.image = nil }
            }
            if let url = studio.asset(intro.media) {
                HStack { Button("Предпросмотр") { preview?.pause(); preview = AVPlayer(url: url); preview?.play() }; Button("Убрать медиа") { preview?.pause(); preview = nil; intro.media = nil } }
                if let preview { VideoPlayer(player: preview).frame(height: 160) }
            }
            Stepper("Показ: \(intro.seconds == 0 ? "до команды ведущего" : "\(intro.seconds) сек")",value: $intro.seconds,in: 0...300,step: 5)
            Text("Если есть медиа, переход дождётся окончания записи. Таймер зрителям не показывается.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Готово") { dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 650).onDisappear { preview?.pause() }
    }
}

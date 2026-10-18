import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import CoreText
import Combine
import CoreAudio

struct MatchPair: Codable, Identifiable, Equatable {
    var id = UUID()
    var left = ""
    var right = ""
}
struct MatchLayout: Codable {
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
    var hostNotes: String? = nil
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
    var repeatIntroSeconds: Int? = nil
    var breakSeconds = 30
    var showAnswers = true
    var standings = false
    var defaultSeconds = 60
    var defaultAfterMedia = true
    var intro: RoundIntro? = nil
    var muteBackground: Bool? = nil
    var tieBreaker: Bool? = nil
    var hostNotes: String? = nil
}
func scoreText(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
struct Team: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Новая команда"
    var scores: [String: Double] = [:]
    var total: Double { (scores.values.reduce(0,+) * 100).rounded() / 100 }
}
struct QuizAppearance: Codable, Equatable {
    var fontName: String? = nil
    var fontFile: String? = nil
    var background = "Стандартный"
    var backgroundImage: String? = nil
    var imageDimming = 0.55
}
struct Quiz: Codable, Equatable {
    var title = "Новый квиз"
    var rounds = [Round()]
    var teams: [Team] = []
    var appearance: QuizAppearance? = nil
    var scoreRevealSeconds: Int? = nil
}
struct QuizFile: Codable {
    var version = 1
    var quiz: Quiz
    var assets: [String: Data]
}
struct Step: Codable {
    enum Kind: String, Codable { case introduction, roundIntro, question, repeatIntro, repeated, answerPrompt, answer, pause, standings, finish }
    var kind: Kind
    var round: Int
    var question: Int = 0
    var duration: Int
    var showsTimer: Bool { [.question,.repeated,.pause].contains(kind) }
}

struct MediaRange: Equatable {
    let start: Double
    let end: Double
    static func resolve(start: Double,end: Double,duration: Double) throws -> MediaRange {
        guard start.isFinite, end.isFinite, start >= 0, end >= 0, duration.isFinite, duration > 0, start < duration else {
            throw NSError(domain: "QuizMedia",code: 1,userInfo: [NSLocalizedDescriptionKey: "Начало фрагмента должно находиться внутри записи."])
        }
        let stop = end == 0 ? duration : min(end,duration)
        guard stop > start else { throw NSError(domain: "QuizMedia",code: 2,userInfo: [NSLocalizedDescriptionKey: "Конец фрагмента должен быть позже начала."]) }
        return MediaRange(start: start,end: stop)
    }
}
@MainActor final class MediaSession: ObservableObject {
    var outputDevice: String? { didSet { player?.audioOutputDeviceUniqueID = outputDevice } }
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var finished = true
    @Published var error: String?
    @Published var hasVideo = false
    @Published var position: Double = 0
    @Published var clip: MediaRange?
    private var task: Task<Void,Never>?
    private var observation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var nativePlayer: AVPlayer?
    private var generation = UUID()
    private var wantsPlayback = true
    private var seekStarted = false
    private var prepared = false
    func start(url: URL,start: Double = 0,end: Double = 0,autoplay: Bool = true,initialVolume: Float = 1) {
        stop()
        let token = generation
        wantsPlayback = autoplay; loading = true; finished = false; error = nil
        task = Task { [weak self] in
            do {
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else { throw NSError(domain: "QuizMedia",code: 3,userInfo: [NSLocalizedDescriptionKey: "Этот файл не поддерживается проигрывателем macOS."]) }
                let duration = try await asset.load(.duration).seconds
                let range = try MediaRange.resolve(start: start,end: end,duration: duration)
                let video = try await asset.loadTracks(withMediaType: .video)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.clip = range; self.hasVideo = !video.isEmpty; self.position = range.start
                let item = AVPlayerItem(asset: asset)
                item.forwardPlaybackEndTime = CMTime(seconds: range.end,preferredTimescale: 600)
                let p = AVPlayer(playerItem: item)
                p.audioOutputDeviceUniqueID = self.outputDevice
                p.volume = min(1,max(0,initialVolume)); p.isMuted = false
                self.player = p; self.nativePlayer = p
                self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,object: item,queue: .main) { [weak self] _ in
                    Task { @MainActor in guard self?.generation == token else { return }; self?.finish() }
                }
                self.failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,object: item,queue: .main) { [weak self] note in
                    let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Не удалось воспроизвести запись."
                    Task { @MainActor in guard self?.generation == token else { return }; self?.finish(message) }
                }
                self.timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2,preferredTimescale: 600),queue: .main) { [weak self] time in
                    Task { @MainActor in guard let self, self.generation == token else { return }; if time.seconds.isFinite { self.position = time.seconds }; if self.prepared && !self.finished && time.seconds >= range.end { self.finish() } }
                }
                self.observation = item.observe(\.status,options: [.initial,.new]) { [weak self] item,_ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if item.status == .failed { self.finish(item.error?.localizedDescription ?? "Ошибка открытия записи.") }
                        else if item.status == .readyToPlay { self.seekAndPlay(token: token) }
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.finish(error.localizedDescription)
            }
        }
    }
    private func seekAndPlay(token: UUID) {
        guard !seekStarted, let player, let clip else { return }
        seekStarted = true
        player.seek(to: CMTime(seconds: clip.start,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero) { [weak self] success in
            Task { @MainActor in
                guard let self, self.generation == token, !self.finished else { return }
                guard success else { self.finish("Не удалось перейти к началу фрагмента."); return }
                self.prepared = true; self.loading = false
                if self.wantsPlayback { self.player?.play() }
            }
        }
    }
    func setPaused(_ paused: Bool) {
        wantsPlayback = !paused
        if paused { player?.pause() } else if prepared && !finished { player?.play() }
    }
    func finish(_ message: String? = nil) {
        player?.pause(); loading = false; finished = true; error = message
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        observation?.invalidate(); observation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        player?.pause(); player = nil; nativePlayer = nil; loading = false; finished = true; error = nil; hasVideo = false; clip = nil; position = 0; seekStarted = false; prepared = false
    }
    deinit {
        task?.cancel(); observation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let timeObserver, let nativePlayer { nativePlayer.removeTimeObserver(timeObserver) }
        nativePlayer?.pause()
    }
}
// Use AppKit directly: SwiftUI's VideoPlayer crashes in _AVKit_SwiftUI on this host.
struct NativeMediaView: NSViewRepresentable {
    let player: AVPlayer
    var controls = true
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = controls ? .inline : .none
        view.videoGravity = .resizeAspect; view.showsFullScreenToggleButton = false
        return view
    }
    func updateNSView(_ view: AVPlayerView,context: Context) {
        if view.player !== player { view.player = player }
        view.controlsStyle = controls ? .inline : .none
    }
    static func dismantleNSView(_ view: AVPlayerView,coordinator: ()) { view.player = nil }
}
struct MediaPreview: View {
    @ObservedObject var session: MediaSession
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            if session.loading { ProgressView("Открываем запись…") }
            if let error = session.error { Text(error).foregroundStyle(.red).font(.caption) }
            if let player = session.player {
                if !session.hasVideo { Label("Аудиофрагмент",systemImage: "waveform") }
                NativeMediaView(player: player).frame(height: session.hasVideo ? 200 : 60)
                HStack { Text("\(session.position, specifier: "%.1f") сек").font(.caption.monospacedDigit()); Button("Остановить") { session.stop() } }
            }
        }
    }
}

struct BackgroundTrack: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var filename: String
    var supplied: Bool
}
@MainActor final class BackgroundMusic: ObservableObject {
    @Published var enabled = false { didSet { defaults.set(enabled,forKey: "MusicEnabled") } }
    @Published var volume: Double = 0.2 { didSet { defaults.set(volume,forKey: "MusicVolume") } }
    @Published var shuffle = true { didSet { defaults.set(shuffle,forKey: "MusicShuffle") } }
    @Published var selected: Set<String> = [] { didSet { defaults.set(Array(selected),forKey: "MusicSelected") } }
    @Published var tracks: [BackgroundTrack] = []
    @Published var currentID: String?
    @Published var message = ""
    @Published var importing = false
    @Published var muted = false
    @Published var speaking = false
    let session = MediaSession()
    let defaults: UserDefaults
    let localFolder: URL
    let suppliedFolder: URL
    private var subscription: AnyCancellable?
    private var gameActive = false
    private var previewing = false
    private var failed: Set<String> = []
    private var level: Float = 0
    init(localFolder: URL? = nil,suppliedFolder: URL? = nil,defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.localFolder = localFolder ?? FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("QuizStudio/BackgroundMusic")
        self.suppliedFolder = suppliedFolder ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BackgroundMusic")
        enabled = defaults.bool(forKey: "MusicEnabled")
        volume = defaults.object(forKey: "MusicVolume") == nil ? 0.2 : min(1,max(0,defaults.double(forKey: "MusicVolume")))
        shuffle = defaults.object(forKey: "MusicShuffle") == nil ? true : defaults.bool(forKey: "MusicShuffle")
        let bundled = ((try? FileManager.default.contentsOfDirectory(at: self.suppliedFolder,includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "mp3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { BackgroundTrack(id: "supplied:" + $0.lastPathComponent,title: $0.deletingPathExtension().lastPathComponent,filename: $0.lastPathComponent,supplied: true) }
        let custom = defaults.data(forKey: "MusicCustom").flatMap { try? JSONDecoder().decode([BackgroundTrack].self,from: $0) } ?? []
        tracks = bundled + custom.filter { !$0.supplied && $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent }
        selected = defaults.stringArray(forKey: "MusicSelected").map(Set.init) ?? Set(bundled.map(\.id))
        subscription = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var currentTitle: String { tracks.first { $0.id == currentID }?.title ?? "Музыка не играет" }
    func url(_ track: BackgroundTrack) -> URL { (track.supplied ? suppliedFolder : localFolder).appendingPathComponent(track.filename) }
    func setSelected(_ id: String,_ value: Bool) { if value { selected.insert(id) } else { selected.remove(id) } }
    func beginGame() { stop(); gameActive = true; muted = false; speaking = false; failed = []; message = "" }
    func stop() { session.stop(); gameActive = false; previewing = false; currentID = nil; level = 0 }
    func play(_ track: BackgroundTrack) {
        currentID = track.id; level = 0
        session.start(url: url(track),initialVolume: 0)
    }
    func preview(_ track: BackgroundTrack) {
        if previewing && currentID == track.id { stop(); return }
        stop(); previewing = true; message = ""; play(track)
    }
    func nextTrack() {
        let candidates = tracks.filter { selected.contains($0.id) && !failed.contains($0.id) }
        guard !candidates.isEmpty else { session.stop(); currentID = nil; message = "Выберите доступные треки для фона."; return }
        let track: BackgroundTrack
        if shuffle {
            let different = candidates.filter { $0.id != currentID }
            track = (different.isEmpty ? candidates : different).randomElement()!
        } else if let i = candidates.firstIndex(where: { $0.id == currentID }) { track = candidates[(i+1) % candidates.count] }
        else { track = candidates[0] }
        play(track)
    }
    func targetVolume(mediaActive: Bool) -> Float {
        if gameActive && (!enabled || muted || mediaActive) { return 0 }
        return Float(min(1,max(0,volume))) * (gameActive && speaking ? 0.2 : 1)
    }
    func tick(mediaActive: Bool) {
        guard gameActive || previewing else { return }
        if gameActive && !enabled { session.stop(); currentID = nil; level = 0; return }
        if gameActive, let id = currentID, !selected.contains(id) { session.stop(); currentID = nil }
        if session.finished {
            if let error = session.error {
                if let id = currentID { failed.insert(id) }
                message = "Не удалось открыть «\(currentTitle)»: \(error)"
            }
            if previewing { session.stop(); previewing = false; currentID = nil; return }
            nextTrack()
        }
        let target = targetVolume(mediaActive: mediaActive)
        // Fade in about one second, fade out in less than half a second.
        let change = max(Float(0.005),Float(min(1,max(0,volume))) * (target < level ? 0.5 : 0.2))
        level += min(change,max(-change,target-level))
        session.player?.volume = level
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        Task { await importFiles(urls); importing = false }
    }
    func importFiles(_ urls: [URL]) async {
        var added = 0; var errors: [String] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: source)
                guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw NSError(domain: "BackgroundMusic",code: 1,userInfo: [NSLocalizedDescriptionKey: "Нет доступной аудиодорожки."]) }
                try FileManager.default.createDirectory(at: localFolder,withIntermediateDirectories: true)
                let id = UUID().uuidString
                let filename = id + "." + source.pathExtension.lowercased()
                try FileManager.default.copyItem(at: source,to: localFolder.appendingPathComponent(filename))
                let track = BackgroundTrack(id: id,title: source.deletingPathExtension().lastPathComponent,filename: filename,supplied: false)
                tracks.append(track); selected.insert(id); added += 1
            } catch { errors.append(source.lastPathComponent + ": " + error.localizedDescription) }
        }
        defaults.set(try? JSONEncoder().encode(tracks.filter { !$0.supplied }),forKey: "MusicCustom")
        message = errors.isEmpty ? "Добавлено треков: \(added)." : "Добавлено: \(added). " + errors.joined(separator: "\n")
        failed = []
    }
}

@MainActor final class Studio: ObservableObject {
    enum Screen { case home, library, createLibrary, editor, teams }
    @Published var screen: Screen = .home
    @Published var introductionSeconds = 6
    @Published var resetScores = true
    @Published var automaticAdvance = true
    @Published var readBeforeTimer = false
    @Published var awaitingQuestionStart = false
    @Published var recentQuizzes: [URL] = []
    var rememberRecent = true
    var hiddenQuizzes: Set<String> = []
    let libraryDefaults: UserDefaults
    @Published var quiz = Quiz() {
        didSet {
            if screen == .editor && !suppressUndo && oldValue != quiz { undoHistory.append(oldValue); if undoHistory.count > 100 { undoHistory.removeFirst() } }
        }
    }
    @Published var undoHistory: [Quiz] = []
    var suppressUndo = false
    @Published var recoveryAvailable = false
    var checkpointTicks = 0
    @Published var checkingQuiz = false
    @Published var preflightIssues: [String] = []
    @Published var showPreflight = false
    @Published var showScoreInputLocally = false
    @Published var showJump = false
    @Published var selectedScreen = 0
    @Published var audioOutputUID = "" { didSet { setAudioOutput() } }
    @Published var signalsEnabled = false
    @Published var signalVolume = 0.4
    var signalPlayer: AVAudioPlayer?
    var startSignalSent = false

    @Published var roundIndex = 0
    @Published var questionIndex = 0
    @Published var playing = false
    @Published var paused = false
    @Published var remaining = 0
    @Published var index = 0
    @Published var status = ""
    @Published var publishedScores = false
    @Published var scoreSnapshot: [Team] = []
    @Published var scoreRevealedIDs: Set<UUID> = []
    @Published var scoreRevealGroup = 0
    @Published var registeredFontName: String? = nil
    var scoreGroups: [[Team]] = []
    var scoreRevealElapsed: Double = 0
    let background: BackgroundMusic
    let playback = MediaSession()
    var player: AVPlayer? { playback.player }
    var playbackSubscription: AnyCancellable?
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
        background = BackgroundMusic(defaults: draftURL == nil ? .standard : UserDefaults(suiteName: "QuizStudio.Checks." + UUID().uuidString)!)
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
        playbackSubscription = playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.playing, event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return event }
            // Do not steal navigation or spaces from the score table's field editor.
            if event.window is NSPanel || NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if event.isARepeat { return [49,123,124].contains(event.keyCode) ? nil : event }
            return self.handleKey(event.keyCode) ? nil : event
        }
        selectedScreen = NSScreen.screens.count > 1 ? 1 : 0
        recoveryAvailable = FileManager.default.fileExists(atPath: recoveryURL.path)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func autosave() { do { try writeDirectory(to: draft)
        if playing || screen == .teams { try persistResults() }; if playing { checkpoint() }
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
        Array(Set([quiz.appearance?.fontFile,quiz.appearance?.backgroundImage].compactMap({$0}) + quiz.rounds.flatMap { r in
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
        quiz.rounds.flatMap { r in (r.questions.isEmpty ? ["\(r.title): нет вопросов"] : []) + r.questions.enumerated().compactMap { i,q in q.issues.isEmpty ? nil : "\(r.title), вопрос \(i+1): \(q.issues.joined(separator: "; "))" } }
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
            guard !decoded.rounds.isEmpty, decoded.rounds.allSatisfy({ $0.questions.allSatisfy { $0.choices.count == 4 } }) else { throw CocoaError(.fileReadCorruptFile) }
            quiz = decoded; folder = mediaFolder; documentURL = url.standardizedFileURL == draft.standardizedFileURL ? nil : url
            roundIndex = 0; questionIndex = 0; remember(url); status = ""
            registeredFontName = asset(quiz.appearance?.fontFile).flatMap { registerFont($0) }
            if quiz.appearance?.fontFile != nil && registeredFontName == nil { status = "Шрифт не удалось открыть — используется системный" }
            undoHistory = []
            return true
        } catch { status = "Не удалось открыть квиз: \(error.localizedDescription)"; return false }
    }
    func newQuiz() { autosave(); screen = .editor; quiz = Quiz(); registeredFontName = nil; folder = nil; documentURL = nil; roundIndex = 0; questionIndex = 0; status = "Создан новый квиз"; undoHistory = [] }
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
    var presentationFontName: String? {
        quiz.appearance?.fontFile != nil ? registeredFontName : quiz.appearance?.fontName
    }
    func stageFont(size: CGFloat,weight: Font.Weight = .regular) -> Font {
        if let name = presentationFontName { return .custom(name,size: size).weight(weight) }
        return .system(size: size,weight: weight)
    }
    func registerFont(_ url: URL) -> String? {
        CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor,kCTFontNameAttribute) as? String,
              NSFont(name: name,size: 24) != nil else { return nil }
        return name
    }
    func importAppearance(font: Bool) {
        let panel = NSOpenPanel()
        panel.title = font ? "Выберите файл шрифта" : "Выберите фон квиза"
        panel.allowedContentTypes = font ? ["ttf","otf","ttc"].compactMap { UTType(filenameExtension: $0) } : [.image]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let root = folder ?? draft
            let dir = root.appendingPathComponent("Media")
            try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
            let name = UUID().uuidString + "." + source.pathExtension
            let dest = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source,to: dest)
            var appearance = quiz.appearance ?? QuizAppearance()
            if font {
                guard let registered = registerFont(dest) else { status = "Не удалось открыть шрифт. Выберите TTF, OTF или TTC."; return }
                registeredFontName = registered; appearance.fontName = registered; appearance.fontFile = name
            } else {
                guard NSImage(contentsOf: dest) != nil else { status = "Не удалось открыть картинку фона"; return }
                appearance.backgroundImage = name
            }
            folder = root; quiz.appearance = appearance
            status = font ? "Шрифт добавлен в квиз" : "Фон добавлен в квиз"
        } catch { status = error.localizedDescription }
    }
    func publishScores() {
        scoreSnapshot = quiz.teams.sorted { $0.total == $1.total ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.total > $1.total }
        let grouped = Dictionary(grouping: scoreSnapshot,by: \.total)
        scoreGroups = grouped.keys.sorted().map { grouped[$0]! }
        scoreRevealedIDs = []; scoreRevealGroup = 0; scoreRevealElapsed = 0
        publishedScores = true
    }
    var scoresFullyRevealed: Bool { scoreRevealGroup >= scoreGroups.count }
    var nextScoreRank: Int? {
        guard scoreGroups.indices.contains(scoreRevealGroup), let team = scoreGroups[scoreRevealGroup].first else { return nil }
        return 1 + scoreSnapshot.filter { $0.total > team.total }.count
    }
    func revealNextScoreGroup() {
        guard scoreGroups.indices.contains(scoreRevealGroup) else { return }
        withAnimation(.easeInOut(duration: 0.85)) {
            scoreRevealedIDs.formUnion(scoreGroups[scoreRevealGroup].map(\.id)); scoreRevealGroup += 1
        }
        scoreRevealElapsed = 0
    }
    func revealAllScores() {
        withAnimation(.easeInOut(duration: 0.85)) { scoreRevealedIDs = Set(scoreSnapshot.map(\.id)); scoreRevealGroup = scoreGroups.count }
    }
    func asset(_ name: String?) -> URL? { guard let name, let folder, name == (name as NSString).lastPathComponent, !name.contains("\\"), name != ".", name != ".." else { return nil }; return folder.appendingPathComponent("Media").appendingPathComponent(name) }

    var selectedQuestion: Question? {
        guard quiz.rounds.indices.contains(roundIndex), quiz.rounds[roundIndex].questions.indices.contains(questionIndex) else { return nil }
        return quiz.rounds[roundIndex].questions[questionIndex]
    }
    func questionBinding(_ id: UUID) -> Binding<Question> {
        let fallback = quiz.rounds.flatMap(\.questions).first { $0.id == id } ?? Question()
        return Binding(get: { self.quiz.rounds.flatMap(\.questions).first { $0.id == id } ?? fallback },set: { value in
            guard let r = self.quiz.rounds.firstIndex(where: { $0.questions.contains(where: { $0.id == id }) }), let q = self.quiz.rounds[r].questions.firstIndex(where: { $0.id == id }) else { return }
            self.quiz.rounds[r].questions[q] = value
        })
    }
    func roundBinding(_ id: UUID) -> Binding<Round> {
        let fallback = quiz.rounds.first { $0.id == id } ?? Round()
        return Binding(get: { self.quiz.rounds.first { $0.id == id } ?? fallback },set: { value in
            guard let index = self.quiz.rounds.firstIndex(where: { $0.id == id }) else { return }
            self.quiz.rounds[index] = value
        })
    }
    @discardableResult func moveQuestion(_ id: UUID,toRound target: UUID,before anchor: UUID? = nil) -> Bool {
        guard let source = quiz.rounds.firstIndex(where: { $0.questions.contains(where: { $0.id == id }) }),
              let sourceIndex = quiz.rounds[source].questions.firstIndex(where: { $0.id == id }),
              let destination = quiz.rounds.firstIndex(where: { $0.id == target }) else { return false }
        if anchor == id { return false }
        if let anchor, !quiz.rounds[destination].questions.contains(where: { $0.id == anchor }) { return false }
        var updated = quiz
        let question = updated.rounds[source].questions.remove(at: sourceIndex)
        let insertion = anchor.flatMap { wanted in updated.rounds[destination].questions.firstIndex { $0.id == wanted } } ?? updated.rounds[destination].questions.count
        updated.rounds[destination].questions.insert(question,at: insertion)
        quiz = updated; roundIndex = destination; questionIndex = insertion
        return true
    }
    func acceptQuestionDrop(_ providers: [NSItemProvider],toRound: UUID,before: UUID? = nil) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier,options: nil) { [weak self] item,_ in
            let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0,encoding: .utf8) }
            guard let text, let id = UUID(uuidString: text) else { return }
            Task { @MainActor in _ = self?.moveQuestion(id,toRound: toRound,before: before) }
        }
        return true
    }
    func selectRound(_ id: UUID) {
        guard let index = quiz.rounds.firstIndex(where: { $0.id == id }) else { return }
        roundIndex = index; questionIndex = 0
    }
    func deleteEmptyRound(_ id: UUID) {
        guard quiz.rounds.count > 1, let index = quiz.rounds.firstIndex(where: { $0.id == id }), quiz.rounds[index].questions.isEmpty else { return }
        let active = quiz.rounds[roundIndex].id
        quiz.rounds.remove(at: index)
        roundIndex = quiz.rounds.firstIndex(where: { $0.id == active }) ?? min(index,quiz.rounds.count-1)
        questionIndex = min(questionIndex,max(0,quiz.rounds[roundIndex].questions.count-1))
    }
    func deleteSelectedQuestion() {
        guard quiz.rounds.indices.contains(roundIndex), quiz.rounds[roundIndex].questions.indices.contains(questionIndex) else { return }
        quiz.rounds[roundIndex].questions.remove(at: questionIndex)
        questionIndex = min(questionIndex,max(0,quiz.rounds[roundIndex].questions.count-1))
    }
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
        guard !quiz.rounds.contains(where: { $0.questions.isEmpty }) else { status = "Заполните пустой раунд или перенесите в него вопросы"; return }
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
            if r.tieBreaker == true { continue }
            if let intro = r.intro { steps.append(Step(kind: .roundIntro,round: ri,duration: intro.seconds)) }
            for (qi,q) in r.questions.enumerated() { steps.append(Step(kind: .question,round: ri,question: qi,duration: q.seconds)) }
            if r.repeatQuestions { steps.append(Step(kind: .repeatIntro,round: ri,duration: r.repeatIntroSeconds ?? 5)); for qi in r.questions.indices { steps.append(Step(kind: .repeated,round: ri,question: qi,duration: r.repeatSeconds)) } }
            steps.append(Step(kind: .pause,round: ri,duration: r.breakSeconds))
            if r.showAnswers { for (qi,q) in r.questions.enumerated() { steps.append(Step(kind: .answerPrompt,round: ri,question: qi,duration: 4)); steps.append(Step(kind: .answer,round: ri,question: qi,duration: q.answerSeconds)) } }
            if r.standings { steps.append(Step(kind: .standings,round: ri,duration: 0)) }
        }
        for (ri,r) in quiz.rounds.enumerated() where r.tieBreaker == true {
            for (qi,q) in r.questions.enumerated() {
                steps.append(Step(kind: .question,round: ri,question: qi,duration: q.seconds))
                steps.append(Step(kind: .answerPrompt,round: ri,question: qi,duration: 4))
                steps.append(Step(kind: .answer,round: ri,question: qi,duration: q.answerSeconds))
            }
            steps.append(Step(kind: .standings,round: ri,duration: 0))
        }
        steps.append(Step(kind: .finish,round: max(0,quiz.rounds.count-1),duration: 0))
        background.beginGame(); playing = true; paused = false; index = 0; enter(); checkpoint(copyAssets: true)
    }
    func enter() {
        showScoreInputLocally = false
        playback.stop(); bleep?.stop(); signalPlayer?.stop(); startSignalSent = false; transitionElapsed = 0; publishedScores = false; mediaDone = true; waitingForMedia = false; elapsed = 0
        scoreSnapshot = []; scoreRevealedIDs = []; scoreGroups = []; scoreRevealGroup = 0; scoreRevealElapsed = 0
        guard let s = step else { return }; remaining = s.duration
        awaitingQuestionStart = readBeforeTimer && s.kind == .question
        if s.kind == .standings && NSScreen.screens.count > 1 { showTV() }
        if s.kind == .roundIntro, let url = asset(quiz.rounds[s.round].intro?.media) {
            mediaDone = false; playback.start(url: url,autoplay: !paused); return
        }
        if [.question,.repeated,.answer].contains(s.kind), let q = currentQuestion, let url = asset(s.kind == .answer ? (q.explanationMedia ?? q.media) : q.media) {
            mediaDone = false; waitingForMedia = s.kind == .question && q.afterMedia
            let explanation = s.kind == .answer && q.explanationMedia != nil
            playback.start(url: url,start: explanation ? 0 : q.start,end: explanation ? 0 : q.end,autoplay: !paused && !awaitingQuestionStart)
        }
    }
    var foregroundMediaActive: Bool { playing && !paused && !awaitingQuestionStart && !mediaDone }
    var roundMutesBackground: Bool { guard let s = step, quiz.rounds.indices.contains(s.round), s.kind != .introduction else { return false }; return quiz.rounds[s.round].muteBackground == true }
    func tick() {
        background.tick(mediaActive: foregroundMediaActive || roundMutesBackground)
        if playing { checkpointTicks += 1; if checkpointTicks >= 5 { checkpointTicks = 0; checkpoint() } }
        guard playing, !paused, !awaitingQuestionStart, let s = step else { return }
        if s.kind == .standings && publishedScores && !scoresFullyRevealed {
            scoreRevealElapsed += 0.2
            if scoreRevealElapsed >= Double(max(1,quiz.scoreRevealSeconds ?? 3)) { revealNextScoreGroup() }
            return
        }
        if !mediaDone {
            if playback.finished {
                mediaDone = true; waitingForMedia = false; bleep?.stop()
                if let error = playback.error { status = "Ошибка воспроизведения: " + error }
            } else if playback.loading { return }
        }
        if !mediaDone, s.kind != .roundIntro, let p = player, let q = currentQuestion {
            let t = p.currentTime().seconds
            let censored = s.kind != .answer && q.bleepRanges.split(separator: ",").contains { range in
                let parts = range.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return parts.count == 2 && t >= parts[0] && t < parts[1]
            }
            p.volume = censored ? 0 : 1
            if censored { if bleep == nil { bleep = try? AVAudioPlayer(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bleep.wav")); bleep?.numberOfLoops = -1 }; if bleep?.isPlaying != true { bleep?.play() } } else { bleep?.stop() }
        }
        guard ![.standings,.finish].contains(s.kind), s.duration > 0, !waitingForMedia else { return }
        if signalsEnabled && s.kind == .question && !startSignalSent { signal(1.3); startSignalSent = true }
        elapsed += 0.2
        if elapsed >= 1 {
            let old = remaining; remaining = max(0, remaining-1); elapsed -= 1
            if signalsEnabled && [.question,.repeated].contains(s.kind) && old != remaining && remaining <= 5 { signal(remaining == 0 ? 0.65 : 1) }
        }
        if automaticAdvance && remaining == 0 && mediaDone { transitionElapsed += 0.2; if [.introduction,.repeatIntro,.answerPrompt,.repeated].contains(s.kind) || transitionElapsed >= 2 { next() } }
    }
    func startQuestionTimer() {
        guard awaitingQuestionStart else { return }
        awaitingQuestionStart = false; elapsed = 0; transitionElapsed = 0
        paused = false; playback.setPaused(false)
    }
    func togglePause() { if awaitingQuestionStart { startQuestionTimer(); return }; paused.toggle(); playback.setPaused(paused); if paused { bleep?.stop() } }
    func next() {
        var target = index+1
        if let s = step, quiz.rounds[s.round].tieBreaker != true {
            while steps.indices.contains(target), steps[target].kind != .finish, quiz.rounds[steps[target].round].tieBreaker == true { target += 1 }
        }
        if steps.indices.contains(target) { index = target; enter(); if step?.kind == .finish { clearRecovery() } else { checkpoint() } }
    }
    func back() { if index > 0 { index -= 1; enter(); checkpoint() } }
    func stop(preserveRecovery: Bool = false) { autosave(); if !preserveRecovery { clearRecovery() }; signalPlayer?.stop(); background.stop(); playback.stop(); bleep?.stop(); playing = false; screen = .editor; tv?.close(); tv = nil }
    func returnToMenu() { stop(); screen = .home }
    func showTV() {
        if tv != nil { tv?.makeKeyAndOrderFront(nil); return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens[min(max(0,selectedScreen),screens.count-1)]
        let window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Квиз — экран участников"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Stage(studio: self, audience: true))
        window.makeKeyAndOrderFront(nil); tv = window
        if NSScreen.screens.count > 1 && screen != NSScreen.main { window.toggleFullScreen(nil) }
    }
}


// A native drag handle avoids Button/List gesture interception on macOS.
struct GameRecovery: Codable {
    var quiz: Quiz
    var steps: [Step]
    var layouts: [UUID: MatchLayout]
    var index: Int
    var remaining: Int
    var elapsed: Double
    var awaiting: Bool
    var mediaDone: Bool
    var position: Double
    var automatic: Bool
    var readFirst: Bool
    var document: String?
    var published: Bool
    var snapshot: [Team]
    var revealed: Set<UUID>
    var groups: [[Team]]
    var revealGroup: Int
    var revealElapsed: Double
}
struct AudioOutput: Identifiable {
    var id: String
    var name: String
    static func available() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,mScope: kAudioObjectPropertyScopeGlobal,mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0,count: Int(size)/MemoryLayout<AudioDeviceID>.size)
        let result = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!) }
        guard result == noErr else { return [] }
        return devices.compactMap { device in
            var channels = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,mScope: kAudioDevicePropertyScopeOutput,mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device,&channels,0,nil,&bytes) == noErr, bytes > 0 else { return nil }
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes),alignment: MemoryLayout<AudioBufferList>.alignment); defer { pointer.deallocate() }
            guard AudioObjectGetPropertyData(device,&channels,0,nil,&bytes,pointer) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
            guard list.contains(where: { $0.mNumberChannels > 0 }) else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var a = AudioObjectPropertyAddress(mSelector: selector,mScope: kAudioObjectPropertyScopeGlobal,mElement: kAudioObjectPropertyElementMain)
                var n = UInt32(MemoryLayout<CFString?>.size)
                let pointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
                pointer.initialize(to: nil)
                defer { pointer.deinitialize(count: 1); pointer.deallocate() }
                guard AudioObjectGetPropertyData(device,&a,0,nil,&n,pointer) == noErr else { return nil }
                return pointer.pointee as String?
            }
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            return AudioOutput(id: uid,name: name)
        }
    }
}
extension Studio {
    var recoveryFolder: URL { draft.deletingLastPathComponent().appendingPathComponent(draft.lastPathComponent + ".recovery") }
    var recoveryURL: URL { recoveryFolder.appendingPathComponent("session.json") }
    func checkpoint(copyAssets: Bool = false) {
        guard playing, let s = step, s.kind != .finish else { return }
        do {
            if copyAssets {
                if folder?.standardizedFileURL != recoveryFolder.standardizedFileURL {
                    try? FileManager.default.removeItem(at: recoveryFolder.appendingPathComponent("Media"))
                }
                try writeDirectory(to: recoveryFolder)
            }
            let state = GameRecovery(quiz: quiz,steps: steps,layouts: matchLayouts,index: index,remaining: remaining,elapsed: elapsed,awaiting: awaitingQuestionStart,mediaDone: mediaDone || playback.finished,position: playback.player?.currentTime().seconds ?? 0,automatic: automaticAdvance,readFirst: readBeforeTimer,document: documentURL?.path,published: publishedScores,snapshot: scoreSnapshot,revealed: scoreRevealedIDs,groups: scoreGroups,revealGroup: scoreRevealGroup,revealElapsed: scoreRevealElapsed)
            try FileManager.default.createDirectory(at: recoveryFolder,withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: recoveryURL,options: .atomic)
            recoveryAvailable = true
        } catch { status = "Не удалось сохранить точку восстановления: " + error.localizedDescription }
    }
    func clearRecovery() { try? FileManager.default.removeItem(at: recoveryURL); recoveryAvailable = false }
    func restoreGame() {
        do {
            let state = try JSONDecoder().decode(GameRecovery.self,from: Data(contentsOf: recoveryURL))
            guard !state.quiz.rounds.isEmpty, state.steps.indices.contains(state.index), state.steps.allSatisfy({ s in
                state.quiz.rounds.indices.contains(s.round) && (s.kind == .introduction ? state.quiz.teams.indices.contains(s.question) : [.question,.repeated,.answer,.answerPrompt].contains(s.kind) ? state.quiz.rounds[s.round].questions.indices.contains(s.question) : true)
            }) else { throw CocoaError(.fileReadCorruptFile) }
            quiz = state.quiz; folder = recoveryFolder
            documentURL = state.document.map { URL(fileURLWithPath: $0) }
            steps = state.steps; matchLayouts = state.layouts; index = state.index
            automaticAdvance = state.automatic; readBeforeTimer = state.readFirst
            playing = true; paused = true; background.beginGame(); background.muted = true
            enter(); remaining = max(0,state.remaining); elapsed = max(0,min(1,state.elapsed)); awaitingQuestionStart = state.awaiting
            if state.mediaDone { playback.stop(); mediaDone = true; waitingForMedia = false }
            else if step?.kind == .roundIntro, let s = step, let url = asset(quiz.rounds[s.round].intro?.media) {
                playback.start(url: url,start: state.position.isFinite ? max(0,state.position) : 0,autoplay: false)
            }
            else if let clip = currentQuestion, let url = asset(step?.kind == .answer ? (clip.explanationMedia ?? clip.media) : clip.media) {
                let explanation = step?.kind == .answer && clip.explanationMedia != nil
                let start = explanation ? 0 : clip.start
                let end = explanation ? 0 : clip.end
                let position = state.position.isFinite && state.position >= start && (end == 0 || state.position < end) ? state.position : start
                playback.start(url: url,start: position,end: end,autoplay: false)
            }
            publishedScores = state.published; scoreSnapshot = state.snapshot; scoreRevealedIDs = state.revealed
            scoreGroups = state.groups; scoreRevealGroup = state.revealGroup; scoreRevealElapsed = state.revealElapsed
            registeredFontName = asset(quiz.appearance?.fontFile).flatMap { registerFont($0) }
            status = "Игра восстановлена на паузе. Проверьте экран и нажмите «Продолжить». Фон выключен до вашей команды."
            undoHistory = []; checkpoint()
        } catch { status = "Не удалось восстановить игру: " + error.localizedDescription }
    }
    func undoEdit() {
        guard let previous = undoHistory.popLast() else { return }
        suppressUndo = true; quiz = previous; suppressUndo = false
        roundIndex = min(roundIndex,max(0,quiz.rounds.count-1)); questionIndex = min(questionIndex,max(0,quiz.rounds[roundIndex].questions.count-1))
        autosave()
    }
    func stepTitle(_ index: Int) -> String {
        guard steps.indices.contains(index) else { return "" }
        let s = steps[index]; let r = quiz.rounds[s.round]
        switch s.kind {
        case .introduction: return "Представление: " + quiz.teams[s.question].name
        case .roundIntro: return r.title + " — правила"
        case .question: return r.title + " — вопрос \(s.question+1)"
        case .repeated: return r.title + " — повтор \(s.question+1)"
        case .answerPrompt: return r.title + " — вопрос перед ответом \(s.question+1)"
        case .answer: return r.title + " — ответ \(s.question+1)"
        case .repeatIntro: return r.title + " — объявление повторов"
        case .pause: return r.title + " — сдача бланков"
        case .standings: return r.title + " — итоги"
        case .finish: return "Завершение игры"
        }
    }
    func jump(to target: Int) {
        guard steps.indices.contains(target) else { return }
        paused = true; index = target; enter(); if step?.kind == .finish { clearRecovery() } else { checkpoint() }
    }
    func confirmExit() {
        let alert = NSAlert(); alert.messageText = "Выйти из игры?"; alert.informativeText = "Команды и баллы сохранятся. Для продолжения текущего этапа выберите «Сохранить и выйти»."
        alert.addButton(withTitle: "Остаться"); alert.addButton(withTitle: "Сохранить и выйти"); alert.addButton(withTitle: "Завершить игру")
        let result = alert.runModal()
        if result == .alertSecondButtonReturn { checkpoint(); stop(preserveRecovery: true) }
        else if result == .alertThirdButtonReturn { stop() }
    }
    func setAudioOutput() {
        let uid = audioOutputUID.isEmpty ? nil : audioOutputUID
        playback.outputDevice = uid; background.session.outputDevice = uid; bleep?.currentDevice = uid; signalPlayer?.currentDevice = uid
    }
    func signal(_ rate: Float = 1) {
        guard let url = Bundle.main.url(forResource: "bleep",withExtension: "wav"), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        signalPlayer?.stop(); p.currentDevice = audioOutputUID.isEmpty ? nil : audioOutputUID; p.volume = Float(signalVolume); p.enableRate = true; p.rate = rate; p.play(); signalPlayer = p
    }
    func validateQuiz() async {
        guard !checkingQuiz else { return }
        checkingQuiz = true; defer { checkingQuiz = false }
        var issues = incompleteQuestions
        for name in referencedAssets {
            guard let url = asset(name), FileManager.default.fileExists(atPath: url.path) else { issues.append("Нет файла: " + name); continue }
            if ["png","jpg","jpeg","gif","heic","tiff","webp"].contains(url.pathExtension.lowercased()), NSImage(contentsOf: url) == nil { issues.append("Не читается изображение: " + name) }
        }
        var checked: [String: Double] = [:]
        for round in quiz.rounds {
            let entries = round.questions.flatMap { q -> [(String,Double,Double,String)] in
                var a: [(String,Double,Double,String)] = []
                if let name = q.media { a.append((name,q.start,q.end,round.title + ": " + q.text)) }
                if let name = q.explanationMedia { a.append((name,0,0,"Объяснение: " + q.text)) }; return a
            } + (round.intro?.media.map { [($0,0.0,0.0,"Правила: " + round.title)] } ?? [])
            for (name,start,end,label) in entries {
                do {
                    guard let url = asset(name), FileManager.default.fileExists(atPath: url.path) else { continue }
                    let duration: Double
                    if let value = checked[name] { duration = value } else {
                        let asset = AVURLAsset(url: url)
                        guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
                        duration = try await asset.load(.duration).seconds; checked[name] = duration
                    }
                    _ = try MediaRange.resolve(start: start,end: end,duration: duration)
                    if end > duration { issues.append(label + ": конец фрагмента позже конца записи.") }
                } catch { issues.append(label + ": " + error.localizedDescription) }
            }
        }
        preflightIssues = Array(Set(issues)).sorted()
    }
    func beginCheckedGame() {
        Task { let checked = quiz; await validateQuiz(); guard checked == quiz else { status = "Квиз изменился во время проверки. Нажмите старт ещё раз."; return }; if preflightIssues.isEmpty { beginGame() } else { showPreflight = true } }
    }
}

final class GameWindowGuard: NSObject, NSWindowDelegate {
    weak var studio: Studio?
    let original: NSWindowDelegate?
    init(studio: Studio,original: NSWindowDelegate?) { self.studio = studio; self.original = original }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
    override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let studio, studio.playing { studio.confirmExit(); if studio.playing { return false } }
        return original?.windowShouldClose?(sender) ?? true
    }
}
final class GameAppDelegate: NSObject, NSApplicationDelegate {
    weak var studio: Studio?
    var guards: [GameWindowGuard] = []
    func install(_ studio: Studio) {
        self.studio = studio
        guard let window = NSApp.windows.first(where: { $0.title.hasPrefix("Квиз Студия") }), !(window.delegate is GameWindowGuard) else { return }
        let guarder = GameWindowGuard(studio: studio,original: window.delegate); guards.append(guarder); window.delegate = guarder
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let studio, studio.playing else { return .terminateNow }
        studio.confirmExit(); return studio.playing ? .terminateCancel : .terminateNow
    }
}

extension Studio {
    func duplicateQuiz(from source: URL,to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw CocoaError(.fileWriteFileExists) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = Studio(draftURL: scratch.appendingPathComponent("Draft.workspace")); copy.timer?.invalidate()
        guard copy.load(source) else { throw NSError(domain: "QuizCopy",code: 1,userInfo: [NSLocalizedDescriptionKey: copy.status]) }
        defer { if (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, let unpacked = copy.folder { try? FileManager.default.removeItem(at: unpacked) } }
        copy.quiz.title += " — копия"
        for i in copy.quiz.teams.indices { copy.quiz.teams[i].scores = [:] }
        try copy.write(to: destination); remember(destination)
        status = "Создана копия: " + destination.lastPathComponent
    }
    func duplicateQuiz(_ source: URL) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "local.quizstudio.quiz",conformingTo: .data)]; panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " — копия.quiz"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try duplicateQuiz(from: source,to: destination) } catch { status = "Не удалось создать копию: " + error.localizedDescription }
    }
    func saveCopy() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "local.quizstudio.quiz",conformingTo: .data)]; panel.nameFieldStringValue = quiz.title + " — копия.quiz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != documentURL?.standardizedFileURL else { status = "Для копии выберите другое имя файла."; return }
        do { try write(to: url); remember(url); status = "Копия сохранена. Вы продолжаете редактировать исходный квиз." } catch { status = error.localizedDescription }
    }
    var audienceScreenReady: Bool {
        guard let tv, let display = tv.screen, NSScreen.screens.count > 1 else { return false }
        let host = NSApp.windows.first { $0.title.hasPrefix("Квиз Студия") }?.screen ?? NSScreen.main
        return display != host
    }
    var hostNote: String {
        guard let s = step, quiz.rounds.indices.contains(s.round) else { return "" }
        let round = quiz.rounds[s.round]
        let q = [.question,.repeated,.answer,.answerPrompt].contains(s.kind) ? currentQuestion?.hostNotes : nil
        return [round.hostNotes,q].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }
}

struct AnimatedQuizImage: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView(); view.imageScaling = .scaleProportionallyUpOrDown; view.imageAlignment = .alignCenter
        view.setContentCompressionResistancePriority(.defaultLow,for: .horizontal); view.setContentCompressionResistancePriority(.defaultLow,for: .vertical)
        view.animates = true; view.setContentHuggingPriority(.defaultLow,for: .horizontal); view.setContentHuggingPriority(.defaultLow,for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView,context: Context) {
        if view.identifier?.rawValue != url.path {
            view.image = NSImage(contentsOf: url); view.identifier = NSUserInterfaceItemIdentifier(url.path)
        }
        view.animates = true
    }
    static func dismantleNSView(_ view: NSImageView,coordinator: ()) { view.animates = false; view.image = nil }
}
struct QuestionDragHandle: NSViewRepresentable {
    let id: UUID
    func makeNSView(context: Context) -> QuestionDragHandleView { QuestionDragHandleView() }
    func updateNSView(_ view: QuestionDragHandleView,context: Context) { view.questionID = id }
}
final class QuestionDragHandleView: NSView, NSDraggingSource {
    var questionID = UUID()
    private var origin: NSPoint?
    override var intrinsicContentSize: NSSize { NSSize(width: 28,height: 32) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5
        for y in [12.0,16.0,20.0] { path.move(to: NSPoint(x: 7,y: y)); path.line(to: NSPoint(x: 21,y: y)) }
        path.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let start = origin, hypot(event.locationInWindow.x-start.x,event.locationInWindow.y-start.y) > 3 else { return }
        origin = nil
        let item = NSDraggingItem(pasteboardWriter: questionID.uuidString as NSString)
        let image = NSImage(systemSymbolName: "text.bubble",accessibilityDescription: "Вопрос") ?? NSImage(size: NSSize(width: 24,height: 24))
        item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow,from: nil),size: NSSize(width: 28,height: 28)),contents: image)
        beginDraggingSession(with: [item],event: event,source: self)
    }
    override func mouseUp(with event: NSEvent) { origin = nil }
    func draggingSession(_ session: NSDraggingSession,sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

struct QuestionInsertionHint: View {
    let visible: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.accentColor).frame(width: 6,height: 6)
            Rectangle().fill(Color.accentColor).frame(height: 2)
            Text("Вставить сюда").font(.system(size: 10,weight: .medium)).foregroundStyle(Color.accentColor).fixedSize()
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .frame(height: visible ? 28 : 0)
        .opacity(visible ? 1 : 0)
        .clipped()
        .accessibilityHidden(!visible)
        .allowsHitTesting(false)
    }
}
struct DraggableQuestionRow: View {
    @ObservedObject var studio: Studio
    let roundID: UUID
    let question: Question
    let number: Int
    let selected: Bool
    let select: () -> Void
    @State var targeted = false
    var body: some View {
        // Keep the hint inside the drop region so opening the gap does not
        // move the pointer out of its target and repeatedly collapse it.
        VStack(spacing: 0) {
            QuestionInsertionHint(visible: targeted)
            HStack(spacing: 0) {
                QuestionDragHandle(id: question.id).frame(width: 28,height: 32)
                    .help("Потяните за полоски, чтобы перенести вопрос")
                Button(action: select) {
                    HStack {
                        Image(systemName: !question.issues.isEmpty ? "exclamationmark.triangle.fill" : question.media == nil ? "text.bubble" : "play.rectangle")
                        Text("\(number). " + (question.text.isEmpty ? "Новый вопрос" : question.text)).lineLimit(1)
                    }.padding(8).frame(maxWidth: .infinity,alignment: .leading)
                        .background(selected ? Color.indigo.opacity(0.15) : .clear,in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }.foregroundStyle(question.issues.isEmpty ? Color.primary : .orange)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18),value: targeted)
        .help(question.issues.isEmpty ? "Перетащите для изменения порядка или переноса в другой раунд" : question.issues.joined(separator: "\n"))
        .onDrop(of: [UTType.text],isTargeted: $targeted) { providers in
            targeted = false
            return studio.acceptQuestionDrop(providers,toRound: roundID,before: question.id)
        }
    }
}
struct RoundDropTarget: View {
    @ObservedObject var studio: Studio
    let roundID: UUID
    @State var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            QuestionInsertionHint(visible: targeted)
            Text("Перетащите в конец раунда").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity,minHeight: 30).padding(4)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18),value: targeted)
        .onDrop(of: [UTType.text],isTargeted: $targeted) { providers in
            targeted = false
            return studio.acceptQuestionDrop(providers,toRound: roundID)
        }
    }
}

@main struct QuizStudioApp: App {
    @NSApplicationDelegateAdaptor(GameAppDelegate.self) var appDelegate
    @StateObject var studio = Studio()
    var body: some Scene {
        WindowGroup("Квиз Студия · 0.9.2") { Content(studio: studio).onAppear { appDelegate.install(studio) }.frame(minWidth: 1050,minHeight: 720).onChange(of: studio.quiz) { _,_ in studio.autosave() }.onOpenURL { url in if !studio.playing && studio.load(url) { studio.prepareGame() } } }
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
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 8,pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(studio.quiz.rounds.enumerated()),id: \.element.id) { ri,r in
                        Section {
                            ForEach(Array(r.questions.enumerated()),id: \.element.id) { qi,q in
                                DraggableQuestionRow(studio: studio,roundID: r.id,question: q,number: qi+1,selected: studio.selectedQuestion?.id == q.id) {
                                    studio.roundIndex = ri; studio.questionIndex = qi
                                }
                            }
                            RoundDropTarget(studio: studio,roundID: r.id)
                        } header: {
                            Button { studio.selectRound(r.id) } label: { Text(r.title + " · \(r.questions.count)") }.buttonStyle(.plain).help("Открыть настройки раунда")
                        }
                    }
                    }.padding(.horizontal,8)
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
                HStack { Button("Отменить изменение") { studio.undoEdit() }.disabled(studio.undoHistory.isEmpty); Button("Бланки…") { studio.printSheets() }; Button("Сохранить копию…") { studio.saveCopy() }; Spacer() }.padding(.horizontal,22).padding(.bottom,10)
                Divider()
                ScrollView { VStack(alignment: .leading,spacing: 24) {
                    AppearanceEditor(studio: studio)
                    RoundSettings(studio: studio, round: studio.roundBinding(studio.quiz.rounds[studio.roundIndex].id))
                    if let selected = studio.selectedQuestion {
                        QuestionEditor(studio: studio,question: studio.questionBinding(selected.id)).id(selected.id)
                    } else { Text("В этом раунде пока нет вопросов. Добавьте вопрос или перетащите его из другого раунда.").foregroundStyle(.secondary).padding() }
                    HStack {
                        Button("Добавить вопрос",systemImage: "plus") { studio.addQuestion() }.buttonStyle(.borderedProminent)
                        if studio.selectedQuestion != nil {
                            Button("Удалить вопрос",role: .destructive) { studio.deleteSelectedQuestion() }
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
                DisclosureGroup("Заметки ведущего о раунде") { TextEditor(text: Binding(get: { round.hostNotes ?? "" },set: { round.hostNotes = $0 })).frame(height: 90); Text("На экран участников не выводятся.").font(.caption).foregroundStyle(.secondary) }
                Toggle("Дополнительный раунд при ничьей",isOn: Binding(get: { round.tieBreaker ?? false },set: { round.tieBreaker = $0 }))
                if round.tieBreaker == true { Text("Пропускается в обычной игре. Ведущий запускает его через «Перейти…», в том числе с финального экрана.").font(.caption).foregroundStyle(.secondary) }
                if round.questions.isEmpty && studio.quiz.rounds.count > 1 { Button("Удалить пустой раунд",role: .destructive) { studio.deleteEmptyRound(round.id) } }
                HStack { Toggle("Повтор вопросов",isOn: $round.repeatQuestions); if round.repeatQuestions { Stepper("По \(round.repeatSeconds) сек",value: $round.repeatSeconds,in: 1...300) } }
                if round.repeatQuestions { Stepper("Экран перед повтором: \(round.repeatIntroSeconds ?? 5) сек",value: Binding(get: { round.repeatIntroSeconds ?? 5 },set: { round.repeatIntroSeconds = $0 }),in: 2...30) }
                Stepper("Сдача бланков: \(round.breakSeconds == 0 ? "до команды ведущего" : "\(round.breakSeconds) сек")",value: $round.breakSeconds,in: 0...600,step: 5)
                Toggle("Показать ответы после раунда",isOn: $round.showAnswers)
                Toggle("Промежуточные итоги после раунда",isOn: $round.standings)
                Toggle("Отключить фоновую музыку в этом раунде",isOn: Binding(get: { round.muteBackground ?? false },set: { round.muteBackground = $0 }))
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
    @StateObject var preview = MediaSession()
    @StateObject var explanationPreview = MediaSession()
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack { Text("Вопрос \(studio.questionIndex+1)").font(.title.bold()); Spacer(); Picker("Тип",selection: $question.kind) { ForEach(["Открытый вопрос","Один из четырёх","Сопоставление"],id: \.self) { Text($0) } }.frame(width: 300) }
            TextEditor(text: $question.text).font(.title3).frame(height: 100).padding(8).background(.background,in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            DisclosureGroup("Заметки ведущего к вопросу") { TextEditor(text: Binding(get: { question.hostNotes ?? "" },set: { question.hostNotes = $0 })).frame(height: 90); Text("Произношение, допустимые ответы и подсказки. Видны ведущему при отдельном экране участников.").font(.caption).foregroundStyle(.secondary) }
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
            if let url = studio.asset(question.image) {
                AnimatedQuizImage(url: url).frame(height: 200)
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
                            explanationPreview.stop(); preview.start(url: url,start: question.start,end: question.end)
                        }; Button("Убрать медиа") { preview.stop(); question.media = nil } }
                        MediaPreview(session: preview)
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
                    if let url = studio.asset(question.explanationImage) {
                        AnimatedQuizImage(url: url).frame(height: 160)
                        Button("Убрать картинку объяснения") { question.explanationImage = nil }
                    }
                    if let url = studio.asset(question.explanationMedia) {
                        HStack {
                            Button("Предпросмотр объяснения") { preview.stop(); explanationPreview.start(url: url) }
                            Button("Убрать медиа объяснения") { explanationPreview.stop(); question.explanationMedia = nil }
                        }
                        MediaPreview(session: explanationPreview)
                        Text("При показе ответа этот файл воспроизводится вместо медиа вопроса и до конца.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            HStack { Stepper("Показ ответа: \(question.answerSeconds) сек",value: $question.answerSeconds,in: 5...600,step: 5); Button("Применить ко всем ответам раунда") { let seconds = question.answerSeconds; for i in studio.quiz.rounds[studio.roundIndex].questions.indices { studio.quiz.rounds[studio.roundIndex].questions[i].answerSeconds = seconds } } }
        }.textFieldStyle(.roundedBorder)
        .onChange(of: question.kind) { _,kind in
            if kind == "Сопоставление" && question.matchPairs == nil { question.matchPairs = [MatchPair(),MatchPair()] }
        }
        .onChange(of: question.id) { _,_ in preview.stop(); explanationPreview.stop() }
        .onDisappear { preview.stop(); explanationPreview.stop() }
    }
}
struct PlayerView: View {
    @ObservedObject var studio: Studio
    @State var controls = true
    @State var hideTask: Task<Void,Never>?
    var body: some View {
        VStack(spacing: 0) {
            if studio.step?.kind == .standings && !studio.publishedScores {
                if studio.audienceScreenReady || studio.showScoreInputLocally { ScoreEditor(studio: studio) } else { StandingsBreakHost(studio: studio) }
            } else { Stage(studio: studio,audience: false) }
            if studio.audienceScreenReady { HostNotes(studio: studio) }
        }
        .overlay(alignment: .bottom) {
            if studio.step?.kind == .finish {
                HStack { Button("Вернуться в меню") { studio.returnToMenu() }; Button("Дополнительный вопрос / этап…") { studio.showJump = true } }.buttonStyle(.borderedProminent).controlSize(.large).padding(28)
            } else if controls || studio.paused || studio.awaitingQuestionStart {
                HStack(spacing: 18) {
                    Button("Выход") { studio.confirmExit() }
                    Button("Перейти…") { studio.showJump = true }
                    Button("Назад") { studio.back() }
                    Button(studio.awaitingQuestionStart ? "Запустить таймер" : (studio.paused ? "Продолжить" : "Пауза")) { studio.togglePause() }
                    Button("Вперёд") { studio.next() }
                    Button("+30 сек") { studio.remaining += 30 }
                    BackgroundMusicControls(music: studio.background)
                    if studio.step?.kind == .standings && studio.publishedScores && !studio.scoresFullyRevealed { Button("Показать все места") { studio.revealAllScores() } }
                    Button("Заново") { studio.enter() }
                    Button("Экран ТВ") { studio.showTV() }
                    Button("На весь экран") { NSApp.keyWindow?.toggleFullScreen(nil) }
                }.buttonStyle(.bordered).padding().background(.regularMaterial,in: Capsule()).padding(20)
            }
        }.sheet(isPresented: $studio.showJump) { JumpMenu(studio: studio) }
        .onAppear {
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
                QuizBackground(studio: studio)
                if let s = studio.step {
                    VStack(spacing: 24) {
                        Text(studio.quiz.title.uppercased()).font(studio.stageFont(size: 18,weight: .semibold)).tracking(4).foregroundStyle(.white.opacity(0.5))
                        switch s.kind {
                        case .introduction:
                            if studio.quiz.teams.indices.contains(s.question) {
                                Text("Встречаем команду!").font(studio.stageFont(size: 28)).foregroundStyle(.white.opacity(0.7))
                                Text(studio.quiz.teams[s.question].name).font(studio.stageFont(size: 64,weight: .bold)).multilineTextAlignment(.center)
                                Text("Ваши аплодисменты").font(studio.stageFont(size: 24)).foregroundStyle(.orange)
                            }
                        case .roundIntro:
                            if let intro = studio.quiz.rounds[s.round].intro {
                                Text(studio.quiz.rounds[s.round].title).font(studio.stageFont(size: 46,weight: .bold))
                                Text(intro.text).font(studio.stageFont(size: 28)).multilineTextAlignment(.center)
                                if let player = studio.player { if studio.playback.hasVideo { NativeMediaView(player: player,controls: false).frame(height: geometry.size.height*0.35) } else { Label("Аудиофрагмент",systemImage: "waveform") } }
                                if let url = studio.asset(intro.image) { AnimatedQuizImage(url: url).frame(height: geometry.size.height*0.3) }
                            }
                        case .repeatIntro:
                            Image(systemName: "arrow.counterclockwise").font(studio.stageFont(size: 52))
                            Text("Сейчас повторим вопросы").font(studio.stageFont(size: 48,weight: .bold))
                            Text("Проверьте записи и дополните ответы").font(studio.stageFont(size: 26))
                            Text(studio.quiz.rounds[s.round].title).font(studio.stageFont(size: 22)).foregroundStyle(.white.opacity(0.65))
                        case .pause: Text("Сдаём бланки").font(studio.stageFont(size: 52,weight: .bold)); Text("Спасибо! Скоро продолжим").font(studio.stageFont(size: 28))
                        case .finish: Text("Спасибо за игру!").font(studio.stageFont(size: 56,weight: .bold))
                        case .standings:
                            if studio.publishedScores { Scores(studio: studio) } else { Text("Перерыв").font(studio.stageFont(size: 52,weight: .bold)); Text("Мы подсчитываем баллы. Можно немного отдохнуть — скоро покажем результаты.").font(studio.stageFont(size: 28)).multilineTextAlignment(.center) }
                        default:
                            if let q = studio.currentQuestion {
                                Text("\(studio.quiz.rounds[s.round].title) · \(s.kind == .answer ? "Ответ" : s.kind == .answerPrompt ? "Ответ" : s.kind == .repeated ? "Повтор" : "Вопрос") \(s.question+1)").font(studio.stageFont(size: 20)).foregroundStyle(.white.opacity(0.65))
                                Text(q.text).font(studio.stageFont(size: min(48,geometry.size.width/22),weight: .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false,vertical: true)
                                if s.kind == .answer || s.kind == .answerPrompt {
                                    Group {
                                        if s.kind == .answer && !(q.kind == "Сопоставление" && q.matchPairs != nil) {
                                            Text(q.correctAnswer).font(studio.stageFont(size: 38,weight: .bold)).foregroundStyle(.green).multilineTextAlignment(.center)
                                        } else if s.kind == .answerPrompt { Text(" ").font(studio.stageFont(size: 38,weight: .bold)) }
                                    }.frame(maxWidth: .infinity,minHeight: 70).padding(12).background(.white.opacity(s.kind == .answer ? 0.07 : 0),in: RoundedRectangle(cornerRadius: 12))
                                }
                                if q.kind == "Сопоставление", let pairs = q.matchPairs {
                                    MatchingBoard(pairs: pairs,layout: studio.matchLayouts[q.id] ?? MatchLayout(left: pairs.map(\.id),right: pairs.map(\.id)),reveal: s.kind == .answer,font: studio.stageFont(size: 24))
                                }
                                if s.kind == .answer, let explanation = q.explanation, !explanation.isEmpty { Text(explanation).font(studio.stageFont(size: 24)).multilineTextAlignment(.center) }
                                if s.kind != .answer && q.kind == "Один из четырёх" { LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())],spacing: 12) { ForEach(0..<4,id: \.self) { i in Text("\(i+1). \(q.choices[i])").font(studio.stageFont(size: 24)).padding().frame(maxWidth: .infinity,alignment: .leading).background(.white.opacity(0.08),in: RoundedRectangle(cornerRadius: 12)) } } }
                                if let p = studio.player {
                                    if studio.playback.hasVideo && (s.kind == .answer ? (q.explanationMedia != nil || q.answerVideo) : !q.audioOnly) { NativeMediaView(player: p,controls: false).frame(height: geometry.size.height*0.38) }
                                    else { Label("Аудиофрагмент",systemImage: "waveform").font(studio.stageFont(size: 28)).padding(30) }
                                }
                                if let url = studio.asset(s.kind == .answer ? (q.explanationImage ?? q.image) : q.image) { AnimatedQuizImage(url: url).frame(height: geometry.size.height*(studio.player == nil ? 0.4 : 0.2)) }
                            }
                        }
                        if studio.playback.loading { Text("Открываем фрагмент…").font(.caption) }
                        if studio.playback.error != nil { Text("Не удалось воспроизвести фрагмент. Ведущий может вернуться в редактор.").font(.caption).foregroundStyle(.orange) }
                        if s.showsTimer && !studio.awaitingQuestionStart { Text(studio.waitingForMedia ? "Слушаем и смотрим…" : (s.duration == 0 ? "Продолжит ведущий" : (studio.remaining == 0 ? (s.kind == .repeated ? "" : "Время вышло") : "\(studio.remaining / 60):\(String(format: "%02d",studio.remaining % 60))"))).font(.system(size: 36,weight: .medium,design: .monospaced)).foregroundStyle(studio.remaining <= 10 && !studio.waitingForMedia ? .orange : .white) }
                        if studio.paused { Text("ПАУЗА").font(studio.stageFont(size: 17,weight: .semibold)).tracking(4).foregroundStyle(.orange) }
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
            Text("На отдельном экране ТВ — перерыв. Нажмите «Показать итоги», когда все баллы проверены.").foregroundStyle(.secondary)
            ScrollView([.horizontal,.vertical]) {
                VStack(alignment: .leading) {
                    HStack { Text("Команда").frame(width: 200); ForEach(studio.quiz.rounds) { r in Text(r.title).frame(width: 100) }; Text("Всего").frame(width: 70) }
                    ForEach($studio.quiz.teams) { $team in
                        HStack {
                            Text(team.name).frame(width: 200,alignment: .leading)
                            ForEach(studio.quiz.rounds) { r in ScoreField(value: Binding(get: { team.scores[r.id.uuidString] ?? 0 },set: { team.scores[r.id.uuidString] = $0 })).frame(width: 100) }
                            Text(scoreText(team.total)).frame(width: 70)
                        }
                    }
                }.textFieldStyle(.roundedBorder)
            }
            Text("Можно вводить дробные баллы через точку или запятую и отрицательные значения для штрафов. При равной сумме команды получают одинаковое место.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Показать итоги") { studio.publishScores() }.buttonStyle(.borderedProminent) }
            Spacer()
        }.padding(40).padding(.bottom,70)
    }
}
struct Scores: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 16) {
            Text("Промежуточные итоги").font(studio.stageFont(size: 44,weight: .bold))
            if let rank = studio.nextScoreRank {
                Text("Сейчас узнаем, кто занимает \(rank)-е место…").font(studio.stageFont(size: 24)).foregroundStyle(.white.opacity(0.75)).id(rank).transition(.opacity)
            } else { Text("Все результаты объявлены").font(studio.stageFont(size: 24)).foregroundStyle(.white.opacity(0.65)) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(studio.scoreSnapshot) { team in
                            let rank = 1 + studio.scoreSnapshot.filter { $0.total > team.total }.count
                            HStack {
                                Text("\(rank)").foregroundStyle(rank <= 3 ? .yellow : .orange).frame(width: 55)
                                if studio.scoreRevealedIDs.contains(team.id) {
                                    Text(team.name).transition(.opacity.combined(with: .move(edge: .bottom)))
                                    Spacer()
                                    Text(scoreText(team.total)).bold().transition(.opacity.combined(with: .scale(scale: 0.8)))
                                } else { Text("•••").foregroundStyle(.white.opacity(0.25)); Spacer() }
                            }.font(studio.stageFont(size: 28)).padding(16)
                                .background(.white.opacity(studio.scoreRevealedIDs.contains(team.id) ? 0.12 : 0.035),in: RoundedRectangle(cornerRadius: 12)).id(team.id)
                        }
                    }
                }.frame(maxHeight: 500)
                .onChange(of: studio.scoreRevealedIDs) { _,ids in
                    if let newest = studio.scoreSnapshot.first(where: { ids.contains($0.id) }) { withAnimation(.easeInOut(duration: 0.8)) { proxy.scrollTo(newest.id,anchor: .center) } }
                }
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
            if studio.recoveryAvailable { Button("Восстановить незавершённую игру") { studio.restoreGame() }.buttonStyle(.borderedProminent) }
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
    @State private var newestFirst = true
    var visibleQuizzes: [URL] {
        studio.recentQuizzes.filter { search.isEmpty || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(search) }.sorted { a,b in
            if newestFirst {
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if ad != bd { return ad > bd }
            }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
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
            HStack { TextField("Найти квиз по названию",text: $search).textFieldStyle(.roundedBorder); Picker("Порядок",selection: $newestFirst) { Text("По дате изменения").tag(true); Text("По названию").tag(false) }.frame(width: 260) }
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
                            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { Text("Изменён: " + date.formatted(date: .abbreviated,time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                            Text(((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "Папка старого формата · " : "Файл .quiz · ") + url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Создать копию") { studio.duplicateQuiz(url) }
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
    @State private var musicSettings = false
    @State private var deviceSettings = false
    var body: some View {
        ScrollView { VStack(alignment: .leading,spacing: 20) {
            HStack { Button("Назад") { studio.screen = .library }; Spacer(); Button("Открыть редактор") { studio.screen = .editor } }
            Text("Команды на игру").font(.largeTitle.bold())
            Text(studio.quiz.title).font(.title2).foregroundStyle(.secondary)
            Text("Введите команды один раз. Перед первым раундом каждая появится на экране, а в итогах останется только заполнить баллы.")
            List {
                ForEach($studio.quiz.teams) { $team in
                    HStack {
                        Image(systemName: "person.3.fill").foregroundStyle(.indigo)
                        TextField("Название команды",text: $team.name).textFieldStyle(.roundedBorder)
                        if team.total != 0 { Text(scoreText(team.total) + " баллов").foregroundStyle(.secondary) }
                        Button("Удалить",role: .destructive) { studio.quiz.teams.removeAll { $0.id == team.id } }
                    }.padding(6)
                }
            }
            .frame(height: 180)
            Button("Добавить команду",systemImage: "plus") { studio.quiz.teams.append(Team(name: "")) }
            Stepper("Представление каждой команды: \(studio.introductionSeconds) сек",value: $studio.introductionSeconds,in: 3...30)
            VStack(alignment: .leading,spacing: 10) {
                Text("Проведение квиза").font(.headline)
                Picker("Переключение экранов",selection: $studio.automaticAdvance) {
                    Text("Автоматически").tag(true)
                    Text("Вручную ведущим").tag(false)
                }.pickerStyle(.segmented)
                Text(studio.automaticAdvance ? "После окончания времени квиз продолжится сам. Итоги и экраны без времени переключает ведущий." : "После окончания времени экран останется до нажатия «Вперёд» или стрелки вправо.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Запускать время вопроса после чтения ведущим",isOn: $studio.readBeforeTimer)
                Text("Вопрос появится без отсчёта. После чтения нажмите «Запустить таймер» или пробел. Для аудио/видео эта кнопка запускает запись; отсчёт идёт во время фрагмента или после него по настройке вопроса.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Button("Проверить квиз") { studio.showPreflight = true; Task { await studio.validateQuiz() } }; Button("Экран и звук…") { deviceSettings = true }; Button("Печатные бланки…") { studio.printSheets() } }
            BackgroundMusicSetup(music: studio.background,showSettings: $musicSettings)
            Toggle("Начать новую игру — обнулить прошлые баллы",isOn: $studio.resetScores)
            Text("Снимите галочку, чтобы сохранить уже введённые результаты. Названия команд сохраняются в обоих случаях.").font(.caption).foregroundStyle(.secondary)
            HStack { Text(studio.status).foregroundStyle(.secondary); Spacer(); Button("Начать игру",systemImage: "play.fill") { studio.beginCheckedGame() }.buttonStyle(.borderedProminent).disabled(studio.quiz.teams.isEmpty || studio.checkingQuiz) }
        }.padding(36) }
        .sheet(isPresented: $deviceSettings) { DeviceSettings(studio: studio) }
        .sheet(isPresented: $studio.showPreflight) { PreflightReport(studio: studio) }
    }
}

struct BackgroundMusicSetup: View {
    @ObservedObject var music: BackgroundMusic
    @Binding var showSettings: Bool
    var body: some View {
        HStack {
            Toggle("Фоновая музыка",isOn: $music.enabled)
            Text("Выбрано: \(music.tracks.filter { music.selected.contains($0.id) }.count) · громкость \(Int(music.volume*100))%")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Выбрать музыку…") { showSettings = true }
        }
        .sheet(isPresented: $showSettings) { BackgroundMusicSettings(music: music) }
    }
}
struct BackgroundMusicSettings: View {
    @ObservedObject var music: BackgroundMusic
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack { Text("Фоновая музыка").font(.title.bold()); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("Музыка хранится на этом Mac отдельно от квиза. Свои файлы копируются в музыкальную библиотеку приложения.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Предложенные треки: Kevin MacLeod (incompetech.com)").font(.caption)
                Link("CC BY 4.0",destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }
            Toggle("Включить фон во время игры",isOn: $music.enabled)
            HStack {
                Text("Громкость")
                Slider(value: $music.volume,in: 0...1)
                Text("\(Int(music.volume*100))%").monospacedDigit().frame(width: 45)
            }
            Toggle("Перемешивать треки",isOn: $music.shuffle)
            Text("Выбранные треки повторяются по кругу. Во время записи вопроса, объяснения или видео фон затихает. На паузе игры музыка продолжается.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Выбрать все") { music.selected = Set(music.tracks.map(\.id)) }
                Button("Снять выбор") { music.selected = [] }
                Spacer()
                Button("Добавить свои файлы…",systemImage: "plus") { music.chooseFiles() }.disabled(music.importing)
            }
            List(music.tracks) { track in
                HStack {
                    Toggle(isOn: Binding(get: { music.selected.contains(track.id) },set: { music.setSelected(track.id,$0) })) {
                        VStack(alignment: .leading) {
                            Text(track.title)
                            Text(track.supplied ? "Kevin MacLeod · CC BY 4.0" : "Своя музыка · на этом Mac").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(music.currentID == track.id ? "Остановить" : "Послушать") { music.preview(track) }
                }.padding(.vertical,4)
            }.frame(minHeight: 220)
            if music.importing { ProgressView("Добавляем музыку…") }
            Text(music.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }.padding(24).frame(width: 650,height: 650)
        .onDisappear { music.stop() }
    }
}
struct BackgroundMusicControls: View {
    @ObservedObject var music: BackgroundMusic
    var body: some View {
        Menu {
            Text(music.currentTitle)
            if !music.message.isEmpty { Text(music.message) }
            Button(music.enabled ? "Выключить фон" : "Включить фон") { music.enabled.toggle() }
            Button(music.muted ? "Вернуть звук фона" : "Выключить звук фона") { music.muted.toggle() }
            Button(music.speaking ? "Вернуть громкость после речи" : "Говорит ведущий — приглушить") { music.speaking.toggle() }
            Button("Следующий трек") { music.nextTrack() }.disabled(!music.enabled)
            Divider()
            Button("Тише") { music.volume = max(0,music.volume-0.05) }
            Button("Громче") { music.volume = min(1,music.volume+0.05) }
        } label: { Label("Музыка",systemImage: !music.enabled || music.muted ? "speaker.slash" : "music.note") }
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
    var font: Font = .title2
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
        }.font(font).padding(20).background(.white.opacity(0.06),in: RoundedRectangle(cornerRadius: 14))
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
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SelectableScoreTextField {
        let field = SelectableScoreTextField(); field.delegate = context.coordinator; field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.stringValue = scoreText(value); field.alignment = .right; field.setContentHuggingPriority(.defaultLow,for: .horizontal)
        return field
    }
    func updateNSView(_ field: SelectableScoreTextField,context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil { field.stringValue = scoreText(value) }
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
            if let number = Double(field.stringValue.replacingOccurrences(of: ",",with: ".").replacingOccurrences(of: "\u{00a0}",with: "").replacingOccurrences(of: "\u{202f}",with: "").replacingOccurrences(of: " ",with: "")), number.isFinite { parent.value = (number*100).rounded()/100 }
            else if field.stringValue.isEmpty { parent.value = 0 }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }; field.stringValue = scoreText(parent.value)
        }
    }
}

struct RoundIntroEditor: View {
    @ObservedObject var studio: Studio
    @Binding var intro: RoundIntro
    @Environment(\.dismiss) var dismiss
    @StateObject var preview = MediaSession()
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("Объяснение раунда").font(.largeTitle.bold())
            Text("Этот экран появится перед первым вопросом раунда.").foregroundStyle(.secondary)
            TextEditor(text: $intro.text).font(.title3).frame(height: 140).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Button("Добавить картинку") { studio.attach(image: true,roundIntro: true) }
                Button("Добавить аудио / видео") { studio.attach(image: false,roundIntro: true) }
            }
            if let url = studio.asset(intro.image) {
                AnimatedQuizImage(url: url).frame(height: 150)
                Button("Убрать картинку") { intro.image = nil }
            }
            if let url = studio.asset(intro.media) {
                HStack { Button("Предпросмотр") { preview.start(url: url) }; Button("Убрать медиа") { preview.stop(); intro.media = nil } }
                MediaPreview(session: preview)
            }
            Stepper("Показ: \(intro.seconds == 0 ? "до команды ведущего" : "\(intro.seconds) сек")",value: $intro.seconds,in: 0...300,step: 5)
            Text("Если есть медиа, переход дождётся окончания записи. Таймер зрителям не показывается.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Готово") { dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 650).onDisappear { preview.stop() }
    }
}

struct QuizBackground: View {
    @ObservedObject var studio: Studio
    var colors: [Color] {
        switch studio.quiz.appearance?.background ?? "Стандартный" {
        case "Ночной": return [.black,Color(white: 0.12)]
        case "Океан": return [Color(red: 0.02,green: 0.1,blue: 0.2),Color(red: 0.04,green: 0.3,blue: 0.38)]
        case "Лес": return [Color(red: 0.03,green: 0.12,blue: 0.1),Color(red: 0.14,green: 0.28,blue: 0.16)]
        case "Бордовый": return [Color(red: 0.15,green: 0.04,blue: 0.1),Color(red: 0.35,green: 0.09,blue: 0.2)]
        default: return [Color(red: 0.06,green: 0.07,blue: 0.17),Color(red: 0.18,green: 0.12,blue: 0.35)]
        }
    }
    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: colors,startPoint: .topLeading,endPoint: .bottomTrailing)
                if let url = studio.asset(studio.quiz.appearance?.backgroundImage), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: g.size.width,height: g.size.height).clipped()
                    Color.black.opacity(min(0.9,max(0,studio.quiz.appearance?.imageDimming ?? 0.55)))
                }
            }
        }.clipped()
    }
}
struct AppearanceEditor: View {
    @ObservedObject var studio: Studio
    @State var expanded = false
    let families = NSFontManager.shared.availableFontFamilies.sorted()
    var appearance: Binding<QuizAppearance> { Binding(get: { studio.quiz.appearance ?? QuizAppearance() },set: { studio.quiz.appearance = $0 }) }
    var body: some View {
        DisclosureGroup("Оформление квиза и показ результатов",isExpanded: $expanded) {
            VStack(alignment: .leading,spacing: 14) {
                Picker("Шрифт на экране",selection: Binding(get: { studio.quiz.appearance?.fontName ?? "" },set: { name in
                    var style = studio.quiz.appearance ?? QuizAppearance(); style.fontName = name.isEmpty ? nil : name; style.fontFile = nil; studio.registeredFontName = nil; studio.quiz.appearance = style
                })) {
                    Text("Стандартный системный").tag("")
                    if let file = studio.quiz.appearance?.fontFile, !file.isEmpty, let name = studio.quiz.appearance?.fontName { Text("Из файла: " + name).tag(name) }
                    ForEach(families,id: \.self) { family in
                        if let font = NSFontManager.shared.font(withFamily: family,traits: [],weight: 5,size: 24), studio.quiz.appearance?.fontFile == nil || font.fontName != studio.quiz.appearance?.fontName { Text(family).tag(font.fontName) }
                    }
                }
                HStack { Button("Добавить шрифт файлом…") { studio.importAppearance(font: true) }; Text("TTF, OTF, TTC · файлы сохраняются внутри .quiz").font(.caption).foregroundStyle(.secondary) }
                Picker("Фон",selection: Binding(get: { studio.quiz.appearance?.background ?? "Стандартный" },set: { value in var style = studio.quiz.appearance ?? QuizAppearance(); style.background = value; style.backgroundImage = nil; studio.quiz.appearance = style })) { ForEach(["Стандартный","Ночной","Океан","Лес","Бордовый"],id: \.self) { Text($0) } }
                HStack {
                    Button("Выбрать картинку фона…") { studio.importAppearance(font: false) }
                    if studio.quiz.appearance?.backgroundImage != nil { Button("Убрать картинку") { studio.quiz.appearance?.backgroundImage = nil } }
                }
                if studio.quiz.appearance?.backgroundImage != nil { HStack { Text("Затемнение"); Slider(value: appearance.imageDimming,in: 0...0.9) } }
                ZStack { QuizBackground(studio: studio); Text("Так выглядит вопрос квиза").font(studio.stageFont(size: 28,weight: .semibold)).foregroundStyle(.white).padding() }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                Stepper("Пауза между раскрытием мест: \(studio.quiz.scoreRevealSeconds ?? 3) сек",value: Binding(get: { studio.quiz.scoreRevealSeconds ?? 3 },set: { studio.quiz.scoreRevealSeconds = $0 }),in: 1...10)
                Text("Результаты открываются от последнего места к первому. Команды с одинаковой суммой появляются вместе.").font(.caption).foregroundStyle(.secondary)
                Button("Вернуть стандартное оформление") { studio.quiz.appearance = nil; studio.registeredFontName = nil }
            }.padding(.top,12)
        }.padding(14).background(.quaternary.opacity(0.35),in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PreflightReport: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("Проверка перед игрой").font(.title.bold())
            if studio.checkingQuiz { ProgressView("Проверяем вопросы, файлы и границы записей…") }
            else if studio.preflightIssues.isEmpty { Label("Проблем не найдено",systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            List(Array(studio.preflightIssues.enumerated()),id: \.offset) { _,issue in Text(issue).foregroundStyle(.orange) }
            Text("Проверка не заменяет пробный показ на телевизоре. Звук можно проверить в настройках экрана и звука.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Проверить снова") { Task { await studio.validateQuiz() } }.disabled(studio.checkingQuiz); Spacer(); Button("Закрыть") { dismiss() } }
        }.padding(24).frame(width: 650,height: 450)
    }
}
struct JumpMenu: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text("Перейти к этапу").font(.title.bold())
            Text("Переход откроет этап на паузе. Баллы сохранятся. Меню видно только ведущему на отдельном экране Mac.").font(.callout).foregroundStyle(.secondary)
            List(Array(studio.steps.indices),id: \.self) { i in
                Button { studio.jump(to: i); dismiss() } label: {
                    HStack { Text(studio.stepTitle(i)); Spacer(); if i == studio.index { Image(systemName: "checkmark") } }
                }.buttonStyle(.plain).padding(4)
            }
            Button("Закрыть") { dismiss() }
        }.padding(24).frame(width: 600,height: 560)
    }
}
struct DeviceSettings: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    @State private var outputs = AudioOutput.available()
    @State private var testWindow: NSWindow?
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("Экран и звук").font(.title.bold())
            Picker("Экран участников",selection: $studio.selectedScreen) {
                ForEach(Array(NSScreen.screens.enumerated()),id: \.offset) { i,s in Text("\(i+1). " + s.localizedName).tag(i) }
            }
            Button("Проверить изображение") {
                testWindow?.close(); let screens = NSScreen.screens
                guard screens.indices.contains(studio.selectedScreen) else { return }
                let window = NSWindow(contentRect: screens[studio.selectedScreen].visibleFrame,styleMask: [.titled,.closable],backing: .buffered,defer: false)
                window.isReleasedWhenClosed = false; window.title = "Проверка экрана"
                window.contentView = NSHostingView(rootView: ZStack { Color.indigo; VStack(spacing: 30) { Text("КВИЗ СТУДИЯ").font(.system(size: 60,weight: .bold)); Text("Здесь будет экран участников").font(.largeTitle) }.foregroundStyle(.white) })
                window.makeKeyAndOrderFront(nil); testWindow = window
            }
            Picker("Устройство звука",selection: $studio.audioOutputUID) {
                Text("Системное по умолчанию").tag("")
                ForEach(outputs) { Text($0.name).tag($0.id) }
            }
            HStack { Button("Обновить устройства") { outputs = AudioOutput.available() }; Button("Проверить звук") { studio.signal() } }
            Text("Выбор применяется к записям, фоновой музыке и сигналам приложения. При отключении устройства выберите другое или системное по умолчанию.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Звуковые сигналы начала и окончания обсуждения",isOn: $studio.signalsEnabled)
            HStack { Text("Громкость сигналов"); Slider(value: $studio.signalVolume,in: 0...1); Text("\(Int(studio.signalVolume*100))%") }
            Text("Последние пять секунд отмечаются короткими сигналами. Громкость не зависит от фоновой музыки.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width: 620,height: 500)
        .onDisappear { testWindow?.close(); studio.signalPlayer?.stop() }
    }
}
extension Studio {
    func printSheets() {
        let choice = NSAlert(); choice.messageText = "Подготовить PDF для печати"; choice.informativeText = "Бланки создаются для каждой команды с номерами вопросов. Лист проверяющего содержит ответы и текстовые объяснения."
        choice.addButton(withTitle: "Бланки команд"); choice.addButton(withTitle: "Ответы для проверки"); choice.addButton(withTitle: "Отмена")
        let result = choice.runModal(); guard result != .alertThirdButtonReturn else { return }
        let answers = result == .alertSecondButtonReturn
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = answers ? "Ответы.pdf" : "Бланки.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportSheets(to: url,answers: answers); status = "PDF сохранён: " + url.lastPathComponent }
        catch { status = "Не удалось создать PDF: " + error.localizedDescription }
    }
    func exportSheets(to url: URL,answers: Bool) throws {
        var box = CGRect(x: 0,y: 0,width: 595,height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer,mediaBox: &box,nil) else { throw CocoaError(.fileWriteUnknown) }
        func page(_ title: String,_ body: String) {
            context.beginPDFPage(nil); context.saveGState(); context.translateBy(x: 0,y: 842); context.scaleBy(x: 1,y: -1)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: true)
            (title as NSString).draw(in: NSRect(x: 40,y: 35,width: 515,height: 70),withAttributes: [.font:NSFont.boldSystemFont(ofSize: 18),.foregroundColor:NSColor.black])
            (body as NSString).draw(in: NSRect(x: 40,y: 115,width: 515,height: 680),withAttributes: [.font:NSFont.systemFont(ofSize: 13),.foregroundColor:NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState(); context.endPDFPage()
        }
        if answers {
            for round in quiz.rounds { for (i,q) in round.questions.enumerated() {
                let correct = q.kind == "Сопоставление" && q.matchPairs != nil ? q.matchPairs!.map { $0.left + " — " + $0.right }.joined(separator: "\n") : q.correctAnswer
                // Split long content to preserve every character on printed pages.
                let text = q.text + "\n\nОтвет:\n" + correct + "\n\nОбъяснение:\n" + (q.explanation ?? "")
                var chunks: [String] = []; var rest = text as NSString
                while rest.length > 0 {
                    let storage = NSTextStorage(string: rest as String,attributes: [.font:NSFont.systemFont(ofSize: 13)])
                    let layout = NSLayoutManager(); let container = NSTextContainer(size: NSSize(width: 515,height: 675)); container.lineFragmentPadding = 0
                    layout.addTextContainer(container); storage.addLayoutManager(layout)
                    let glyphs = layout.glyphRange(for: container)
                    let range = layout.characterRange(forGlyphRange: glyphs,actualGlyphRange: nil)
                    guard range.length > 0 else { throw CocoaError(.fileWriteUnknown) }
                    chunks.append(rest.substring(with: range)); rest = rest.substring(from: range.length) as NSString
                }
                for (part,chunk) in chunks.enumerated() { page(quiz.title + " · " + round.title + " · \(i+1)" + (part > 0 ? " (продолжение)" : ""),chunk) }
            } }
        } else {
            let names = quiz.teams.isEmpty ? ["Команда: ____________________"] : quiz.teams.map(\.name)
            for name in names { for round in quiz.rounds { for start in stride(from: 0,to: round.questions.count,by: 5) {
                let body = (start..<min(start+5,round.questions.count)).map { "Вопрос \($0+1)\n\n________________________________________________________\n\n________________________________________________________\n\n" }.joined()
                page(quiz.title + " · " + round.title + "\n" + name,body)
            } } }
        }
        context.closePDF()
    }
}

struct HostNotes: View {
    @ObservedObject var studio: Studio
    var body: some View {
        if !studio.hostNote.isEmpty {
            DisclosureGroup("Заметки ведущего") { ScrollView { Text(studio.hostNote).frame(maxWidth: .infinity,alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 120) }
                .padding(12).background(.regularMaterial)
        }
    }
}
struct StandingsBreakHost: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 20) {
            Text("Перерыв · подсчёт баллов").font(.largeTitle.bold())
            Text("Чтобы таблица ввода не была видна участникам, подключите ТВ как отдельный экран, без дублирования рабочего стола.").multilineTextAlignment(.center)
            Button("Открыть экран участников") { studio.showTV(); studio.objectWillChange.send() }.disabled(NSScreen.screens.count < 2)
            Button("Зрители не видят этот Mac — открыть ввод баллов") { studio.showScoreInputLocally = true }
            Text("На отдельном экране участников остаётся заставка перерыва до команды «Показать итоги».").font(.caption).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: .infinity,maxHeight: .infinity)
    }
}

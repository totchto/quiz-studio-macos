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
struct ImageMask: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    var width: Double
    var height: Double
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
    var questionClip: ClipSettings? = nil
    var answerClip: ClipSettings? = nil
    var selectedChoice: Int? = nil
    var matchPairs: [MatchPair]? = nil
    var acceptedAnswers: [String]? = nil
    var hostNotes: String? = nil
    var explanation: String? = nil
    var explanationImage: String? = nil
    var explanationMedia: String? = nil
    var imageGallery: [String]? = nil
    var explanationGallery: [String]? = nil
    var questionImageMasks: [ImageMask]? = nil
    var answerImageMasks: [ImageMask]? = nil
    var siqAttachments: [SIQAttachment]? = nil
    var siqReviewRequired: Bool? = nil
    var tags: [String]? = nil
    var difficulty: String? = nil
    var bankEntryID: UUID? = nil
    var numericAnswer: Double? = nil
    var numericTolerance: Double? = nil
    var sequenceItems: [SequenceItem]? = nil
    var correctChoices: [Int]? = nil
    var correctPoints: Double? = nil
    var wrongPoints: Double? = nil
    var partialPoints: Double? = nil
    var wagerEnabled: Bool? = nil
    var wagerCorrectPoints: Double? = nil
    var wagerWrongPoints: Double? = nil
    var choiceImages: [String?]? = nil
    var categoryGroups: [String]? = nil
    var categoryItems: [CategoryItem]? = nil
    var correctAnswer: String {
        if let extraAnswer { return extraAnswer }
        if kind == "Сопоставление", let pairs = matchPairs { return pairs.map { $0.left+" — "+$0.right }.joined(separator:"\n") }
        if kind == "Один из четырёх", let selectedChoice, choices.indices.contains(selectedChoice) { return choices[selectedChoice] }
        return answer
    }
    var issues: [String] {
        var result: [String] = []
        if siqReviewRequired == true { result.append("Импортированное задание требует проверки") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("Не заполнен вопрос") }
        if let extraIssues { result += extraIssues } else if kind == "Сопоставление", let pairs = matchPairs {
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
    var defaultAnswerSeconds: Int? = nil
    var defaultAudioOnly: Bool? = nil
    var intro: RoundIntro? = nil
    var muteBackground: Bool? = nil
    var tieBreaker: Bool? = nil
    var hostNotes: String? = nil
    var blocks: [PresentationBlock]? = nil
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
    var bankHistoryID: UUID? = nil
    var importNotes: String? = nil
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
    enum Kind: String, Codable { case introduction, roundIntro, block, question, repeatIntro, repeated, answerPrompt, answer, pause, standings, finish }
    var kind: Kind
    var round: Int
    var question: Int = 0
    var duration: Int
    var block: Int? = nil
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
    private var effects: ClipSettings?
    private var effectRange: MediaRange?
    private var censorPlayer: AVAudioPlayer?
    func start(url: URL,start: Double = 0,end: Double = 0,autoplay: Bool = true,initialVolume: Float = 1,effects: ClipSettings? = nil) {
        stop()
        let token = generation
        self.effects = effects
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
                self.effectRange = try effects.map { try MediaRange.resolve(start:$0.start,end:$0.end,duration:duration) }
                self.clip = range; self.hasVideo = !video.isEmpty; self.position = range.start
                let item = AVPlayerItem(asset: asset)
                if let effects, let effectRange = self.effectRange {
                    let audioTracks = try await asset.loadTracks(withMediaType:.audio)
                    guard !Task.isCancelled, self.generation == token else { return }
                    item.audioMix = effects.audioMix(tracks:audioTracks,range:effectRange)
                }
                item.forwardPlaybackEndTime = CMTime(seconds: range.end,preferredTimescale: 600)
                let p = AVPlayer(playerItem: item)
                p.audioOutputDeviceUniqueID = self.outputDevice
                p.volume = min(1,max(0,initialVolume)); p.isMuted = false
                self.player = p; self.nativePlayer = p
                self.endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,object: item,queue: .main) { [weak self] _ in
                    Task { @MainActor in guard self?.generation == token else { return }; self?.finish() }
                }
                self.failureObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,object: item,queue: .main) { [weak self] note in
                    let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Не удалось воспроизвести запись."
                    Task { @MainActor in guard self?.generation == token else { return }; self?.finish(message) }
                }
                self.timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.02,preferredTimescale: 600),queue: .main) { [weak self] time in
                    Task { @MainActor in guard let self, self.generation == token else { return }; if time.seconds.isFinite { self.position = time.seconds; self.applyEffects(at:time.seconds) }; if self.prepared && !self.finished && time.seconds >= range.end { self.finish() } }
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
        if paused { player?.pause(); censorPlayer?.stop() } else if prepared && !finished { player?.play() }
    }
    private func applyEffects(at time: Double) {
        guard let effects, let range = effectRange, let player else { return }
        let region = effects.censor(at:time)
        if let region, !region.silence, player.rate > 0, wantsPlayback, !finished {
            if censorPlayer == nil, let url = Bundle.main.url(forResource:"bleep",withExtension:"wav") {
                censorPlayer = try? AVAudioPlayer(contentsOf:url); censorPlayer?.numberOfLoops = -1
            }
            censorPlayer?.currentDevice = outputDevice; censorPlayer?.volume = effects.gain(at:time,range:range) * player.volume
            if censorPlayer?.isPlaying != true { censorPlayer?.play() }
        } else { censorPlayer?.stop() }
    }
    func finish(_ message: String? = nil) {
        censorPlayer?.stop(); player?.pause(); loading = false; finished = true; error = message
    }
    func stop() {
        censorPlayer?.stop(); censorPlayer = nil; effects = nil; effectRange = nil
        generation = UUID(); task?.cancel(); task = nil
        observation?.invalidate(); observation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        player?.pause(); player = nil; nativePlayer = nil; loading = false; finished = true; error = nil; hasVideo = false; clip = nil; position = 0; seekStarted = false; prepared = false
    }
    deinit {
        censorPlayer?.stop(); task?.cancel(); observation?.invalidate()
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
    @Published var phoneMode = false
    let phoneRoom = PhoneRoom()
    @Published var showSIQImport = false
    @Published var showQuestionBank = false
    @Published var showBulkImport = false
    @Published var showQuizAssembly = false
    @Published var showGameArchive = false
    var archiveRun: ArchiveRunState?
    lazy var gameArchive = GameArchive(root:draft.deletingLastPathComponent().appendingPathComponent("GameArchive"))
    @Published var editorSelection: Set<UUID> = []
    @Published var showBulkEdit = false
    @Published var editorPreview: EditorPreviewMode?
    var isEditorPreview = false
    lazy var roundTemplates = RoundTemplateStore(url:draft.deletingLastPathComponent().appendingPathComponent("RoundTemplates.json"))
    lazy var quizTemplates = QuizTemplateStore(url:draft.deletingLastPathComponent().appendingPathComponent("QuizTemplates.json"))
    lazy var questionBank = QuestionBank(root:draft.deletingLastPathComponent().appendingPathComponent("QuestionBank"))
    lazy var teamRoster = TeamRoster(url:draft.deletingLastPathComponent().appendingPathComponent("Teams.json"))
    var siqSource: URL?
    @Published var showPhoneReview = false
    @Published var resetScores = true
    @Published var automaticAdvance = true
    @Published var readBeforeTimer = false
    @Published var awaitingQuestionStart = false
    @Published var recentQuizzes: [URL] = []
    @Published var libraryFolders: [String: String] = [:]
    @Published var libraryTags: [String: [String]] = [:]
    var rememberRecent = true
    var hiddenQuizzes: Set<String> = []
    let libraryDefaults: UserDefaults
    @Published var quiz = Quiz() {
        didSet {
            if screen == .editor && !suppressUndo && oldValue != quiz {
                undoHistory.append(oldValue); if undoHistory.count > 100 { undoHistory.removeFirst() }
                redoHistory = []
            }
        }
    }
    @Published var undoHistory: [Quiz] = []
    @Published var redoHistory: [Quiz] = []
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
    @Published var lastAutosave: Date?
    @Published var focusEditorSearch = false
    @Published var focusLibrarySearch = false
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
            libraryFolders = self.libraryDefaults.dictionary(forKey: "QuizFolders") as? [String: String] ?? [:]
            libraryTags = self.libraryDefaults.dictionary(forKey: "QuizTags") as? [String: [String]] ?? [:]
            let saved = (self.libraryDefaults.stringArray(forKey: "RecentQuizzes") ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL }
            let nearby = nearbyFolder ?? Bundle.main.bundleURL.deletingLastPathComponent()
            let discovered = ((try? FileManager.default.contentsOfDirectory(at: nearby,includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "quiz" }.map(\.standardizedFileURL)
            var seen: Set<String> = []
            recentQuizzes = (saved + discovered).filter { url in
                !hiddenQuizzes.contains(url.path) && FileManager.default.fileExists(atPath: url.path) && seen.insert(url.path).inserted
            }
        }
        if FileManager.default.fileExists(atPath: draft.path) { load(draft) }
        phoneRoom.studio = self
        playbackSubscription = playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.playing, event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return event }
            // Do not steal navigation or spaces from the score table's field editor.
            if event.window is NSPanel || NSApp.keyWindow?.firstResponder is NSTextView { return event }
            // Presentation remotes commonly send arrows, Page Up/Down, Enter or media keys.
            if event.isARepeat { return [49,36,123,124,116,121, Self.playPauseKeyCode].contains(event.keyCode) ? nil : event }
            return self.handleKey(event.keyCode) ? nil : event
        }
        selectedScreen = NSScreen.screens.count > 1 ? 1 : 0
        recoveryAvailable = FileManager.default.fileExists(atPath: recoveryURL.path)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func autosave() { do { try writeDirectory(to: draft)
        if (playing || screen == .teams) && !phoneMode { try persistResults() }; if playing { checkpoint() }; lastAutosave = Date()
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
        switch key {
        case 49, 36, Self.playPauseKeyCode: togglePause() // Space, Return, Play/Pause
        case 123, 116: back() // Left, Page Up
        case 124, 121: next() // Right, Page Down
        default: return false
        }
        return true
    }
    private static let playPauseKeyCode: UInt16 = 16 // NSEvent key code for Play/Pause on common remotes
    func persistLibrary() {
        guard rememberRecent else { return }
        libraryDefaults.set(recentQuizzes.map(\.path),forKey: "RecentQuizzes")
        libraryDefaults.set(hiddenQuizzes.sorted(),forKey: "HiddenQuizzes")
        libraryDefaults.set(libraryFolders,forKey: "QuizFolders")
        libraryDefaults.set(libraryTags,forKey: "QuizTags")
    }
    func setLibraryMetadata(for url: URL, folder: String, tags: String) {
        let key = url.standardizedFileURL.path
        let cleanFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTags = Array(Set(tags.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        libraryFolders[key] = cleanFolder.isEmpty ? nil : cleanFolder
        libraryTags[key] = cleanTags.isEmpty ? nil : cleanTags
        persistLibrary()
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
    func deleteQuizFile(_ url: URL) {
        let alert = NSAlert(); alert.messageText = "Удалить квиз с Mac?"
        alert.informativeText = "«\(url.deletingPathExtension().lastPathComponent)» будет удалён с диска, а не только из библиотеки."
        alert.alertStyle = .warning; alert.addButton(withTitle:"Удалить файл"); alert.addButton(withTitle:"Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(at:url)
            let key = url.standardizedFileURL.path
            recentQuizzes.removeAll { $0.standardizedFileURL.path == key }
            hiddenQuizzes.remove(key); libraryFolders.removeValue(forKey:key); libraryTags.removeValue(forKey:key)
            persistLibrary(); status = "Квиз удалён с Mac: " + url.lastPathComponent
        } catch { status = "Не удалось удалить квиз: " + error.localizedDescription }
    }
    func showLibrary(editing: Bool) { status = ""; screen = editing ? .createLibrary : .library }
    func editQuiz(_ url: URL) {
        autosave()
        if load(url) { screen = .editor }
    }
    func prepareGame() { if !phoneMode { phoneRoom.stop() }; resetScores = true; status = ""; screen = .teams }
    func beginGame() {
        if phoneMode {
            guard phoneRoom.running, !phoneRoom.joinedTeams.isEmpty else { status = "Откройте комнату и дождитесь подключения команд"; return }
            quiz.teams = phoneRoom.joinedTeams
        }
        let names = quiz.teams.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else { status = "Добавьте команды и заполните их названия"; return }
        guard Set(names.map { $0.lowercased() }).count == names.count else { status = "Названия команд должны различаться"; return }
        for i in quiz.teams.indices { quiz.teams[i].name = names[i] }
        // Do not discard a previous game's scores unless the quiz can actually start.
        start()
        if playing {
            if resetScores { for i in quiz.teams.indices { quiz.teams[i].scores = [:] } }
            if phoneMode { phoneRoom.beginGame() }
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
        var names = [quiz.appearance?.fontFile,quiz.appearance?.backgroundImage].compactMap { $0 }
        for round in quiz.rounds {
            names += [round.intro?.image,round.intro?.media].compactMap { $0 }
            for q in round.questions {
                names += [q.image,q.media,q.explanationImage,q.explanationMedia].compactMap { $0 }
                names += q.imageGallery ?? []; names += q.explanationGallery ?? []
                names += (q.siqAttachments ?? []).map(\.name)
                names += (q.choiceImages ?? []).compactMap { $0 }
            }
            names += (round.blocks ?? []).compactMap(\.image)
        }
        return Array(Set(names)).sorted()
    }
    func write(to url: URL) throws {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path,isDirectory: &directory), directory.boolValue {
            throw NSError(domain: "QuizStudio",code: 1,userInfo: [NSLocalizedDescriptionKey: "По этому пути находится папка старого квиза. Выберите другое имя для нового файла .quiz."])
        }
        if quiz.bankHistoryID == nil { quiz.bankHistoryID = UUID() }
        var assets: [String: Data] = [:]
        for name in referencedAssets {
            guard let source = asset(name) else { throw CocoaError(.fileNoSuchFile) }
            assets[name] = try Data(contentsOf: source)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
        try JSONEncoder().encode(QuizFile(quiz: quiz,assets: assets)).write(to: url,options: .atomic)
        recordBankUsage(played:false)
        var createdDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,isDirectory: &createdDirectory), !createdDirectory.boolValue else { throw CocoaError(.fileWriteUnknown) }
    }
    func leaveEditor(destination: Screen = .home) {
        let alert = NSAlert(); alert.messageText = "Сохранить квиз перед выходом в меню?"
        alert.informativeText = "Сохраните отдельный файл .quiz, чтобы продолжить работу позже или перенести игру. Черновик также сохраняется автоматически."
        alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Выйти с черновиком")
        switch alert.runModal() {
        case .alertFirstButtonReturn: if save() { screen = destination }
        case .alertThirdButtonReturn: autosave(); screen = destination
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
            undoHistory = []; redoHistory = []
            return true
        } catch { status = "Не удалось открыть квиз: \(error.localizedDescription)"; return false }
    }
    func newQuiz() { autosave(); screen = .editor; quiz = Quiz(); registeredFontName = nil; folder = nil; documentURL = nil; roundIndex = 0; questionIndex = 0; status = "Создан новый квиз"; undoHistory = []; redoHistory = [] }
    func duplicateSelectedQuestion() {
        guard quiz.rounds.indices.contains(roundIndex), quiz.rounds[roundIndex].questions.indices.contains(questionIndex) else { return }
        var copy = quiz.rounds[roundIndex].questions[questionIndex]
        copy.id = UUID()
        quiz.rounds[roundIndex].questions.insert(copy, at: questionIndex + 1)
        questionIndex += 1
    }
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
                    if image { quiz.rounds[roundIndex].questions[questionIndex].explanationImage = name; quiz.rounds[roundIndex].questions[questionIndex].answerImageMasks = nil }
                    else { quiz.rounds[roundIndex].questions[questionIndex].explanationMedia = name; quiz.rounds[roundIndex].questions[questionIndex].answerClip = nil }
                } else if image { quiz.rounds[roundIndex].questions[questionIndex].image = name; quiz.rounds[roundIndex].questions[questionIndex].questionImageMasks = nil }
                else {
                    quiz.rounds[roundIndex].questions[questionIndex].media = name
                    quiz.rounds[roundIndex].questions[questionIndex].questionClip = nil
                    quiz.rounds[roundIndex].questions[questionIndex].start = 0; quiz.rounds[roundIndex].questions[questionIndex].end = 0
                    quiz.rounds[roundIndex].questions[questionIndex].bleepRanges = ""
                    if quiz.rounds[roundIndex].questions[questionIndex].explanationMedia == nil { quiz.rounds[roundIndex].questions[questionIndex].answerClip = nil }
                }
            } catch { status = error.localizedDescription }
        }
    }
    func attachChoiceImage(_ choice:Int) {
        guard quiz.rounds.indices.contains(roundIndex),quiz.rounds[roundIndex].questions[questionIndex].choices.indices.contains(choice) else{return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.image]
        guard panel.runModal() == .OK,let url=panel.url,url.pathExtension.lowercased() != "gif" else { status="Для варианта ответа выберите статичное изображение";return }
        do { let root=folder ?? draft,dir=root.appendingPathComponent("Media");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);let name=UUID().uuidString+"."+url.pathExtension;try FileManager.default.copyItem(at:url,to:dir.appendingPathComponent(name));folder=root
            var images=quiz.rounds[roundIndex].questions[questionIndex].choiceImages ?? Array(repeating:nil,count:quiz.rounds[roundIndex].questions[questionIndex].choices.count)
            while images.count < quiz.rounds[roundIndex].questions[questionIndex].choices.count { images.append(nil) };images[choice]=name;quiz.rounds[roundIndex].questions[questionIndex].choiceImages=images
        } catch { status=error.localizedDescription }
    }
    func importDownloadedMedia(_ url: URL,questionID: UUID,explanation: Bool) throws {
        guard let ri = quiz.rounds.firstIndex(where:{ $0.questions.contains { $0.id == questionID } }),
              let qi = quiz.rounds[ri].questions.firstIndex(where:{ $0.id == questionID }) else { throw YouTubeImportError(message:"Вопрос больше не существует.") }
        let root = folder ?? draft; let dir = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let name = UUID().uuidString+"."+url.pathExtension
        try FileManager.default.copyItem(at:url,to:dir.appendingPathComponent(name)); folder = root
        if explanation { quiz.rounds[ri].questions[qi].explanationMedia = name; quiz.rounds[ri].questions[qi].answerClip = nil }
        else {
            quiz.rounds[ri].questions[qi].media = name; quiz.rounds[ri].questions[qi].questionClip = nil
            quiz.rounds[ri].questions[qi].start = 0; quiz.rounds[ri].questions[qi].end = 0; quiz.rounds[ri].questions[qi].bleepRanges = ""
            if quiz.rounds[ri].questions[qi].explanationMedia == nil { quiz.rounds[ri].questions[qi].answerClip = nil }
        }
        autosave()
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
        if phoneMode, let s = step, !phoneRoom.pending(through: s.round).isEmpty { showPhoneReview = true; return }
        scoreSnapshot = quiz.teams.sorted { $0.total == $1.total ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.total > $1.total }
        let grouped = Dictionary(grouping: scoreSnapshot,by: \.total)
        scoreGroups = grouped.keys.sorted().map { grouped[$0]! }
        scoreRevealedIDs = []; scoreRevealGroup = 0; scoreRevealElapsed = 0
        publishedScores = true
        if phoneMode { do { try persistResults() } catch { status = "Не удалось записать баллы в файл квиза: " + error.localizedDescription } }
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
        provider.loadObject(ofClass: NSString.self) { [weak self] item,_ in
            guard let text = item as? String, let id = UUID(uuidString: text) else { return }
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
    func duplicateRound(_ id: UUID) {
        guard let index = quiz.rounds.firstIndex(where: { $0.id == id }) else { return }
        var copy = quiz.rounds[index]; copy.id = UUID(); copy.title += " — копия"
        for questionIndex in copy.questions.indices { copy.questions[questionIndex].id = UUID() }
        quiz.rounds.insert(copy,at:index+1); roundIndex = index+1; questionIndex = 0
    }
    @discardableResult func moveRound(_ id: UUID,before anchor: UUID?) -> Bool {
        guard let source = quiz.rounds.firstIndex(where: { $0.id == id }), id != anchor,
              anchor == nil || quiz.rounds.contains(where: { $0.id == anchor }) else { return false }
        let activeID = quiz.rounds.indices.contains(roundIndex) ? quiz.rounds[roundIndex].id : id
        var updated = quiz
        let moving = updated.rounds.remove(at:source)
        let destination = anchor.flatMap { wanted in updated.rounds.firstIndex(where: { $0.id == wanted }) } ?? updated.rounds.count
        updated.rounds.insert(moving,at:destination)
        quiz = updated; roundIndex = updated.rounds.firstIndex(where: { $0.id == activeID }) ?? destination
        return true
    }
    func acceptRoundDrop(_ providers:[NSItemProvider],before anchor:UUID) -> Bool {
        guard let provider = providers.first(where:{ $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else { return false }
        provider.loadObject(ofClass:NSString.self) { [weak self] item,_ in
            guard let text = item as? String,let id = UUID(uuidString:text) else { return }
            Task { @MainActor in _ = self?.moveRound(id,before:anchor) }
        }
        return true
    }
    func applyTime() {
        let q = quiz.rounds[roundIndex].questions[questionIndex]
        quiz.rounds[roundIndex].defaultSeconds = q.seconds
        quiz.rounds[roundIndex].defaultAfterMedia = q.afterMedia
        for i in quiz.rounds[roundIndex].questions.indices { quiz.rounds[roundIndex].questions[i].seconds = q.seconds; quiz.rounds[roundIndex].questions[i].afterMedia = q.afterMedia }
    }
    func addQuestion() {
        let round = quiz.rounds[roundIndex]
        var q = Question(); q.seconds = round.defaultSeconds; q.afterMedia = round.defaultAfterMedia; q.answerSeconds = round.defaultAnswerSeconds ?? 20; q.audioOnly = round.defaultAudioOnly ?? false
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
        recordBankUsage(played:true)
        autosave(); steps = []; matchLayouts = [:]
        for r in quiz.rounds { for q in r.questions { if let pairs = q.matchPairs { matchLayouts[q.id] = MatchLayout.make(pairs) } } }
        for i in quiz.teams.indices { steps.append(Step(kind: .introduction,round: 0,question: i,duration: introductionSeconds)) }
        for (ri,r) in quiz.rounds.enumerated() {
            if r.tieBreaker == true { continue }
            if let intro = r.intro { steps.append(Step(kind: .roundIntro,round: ri,duration: intro.seconds)) }
            for (qi,q) in r.questions.enumerated() {
                for (bi,block) in (r.blocks ?? []).enumerated() where block.beforeQuestion == qi { steps.append(Step(kind:.block,round:ri,duration:block.seconds,block:bi)) }
                steps.append(Step(kind: .question,round: ri,question: qi,duration: q.seconds))
            }
            for (bi,block) in (r.blocks ?? []).enumerated() where block.beforeQuestion >= r.questions.count { steps.append(Step(kind:.block,round:ri,duration:block.seconds,block:bi)) }
            if !phoneMode && r.repeatQuestions { steps.append(Step(kind: .repeatIntro,round: ri,duration: r.repeatIntroSeconds ?? 5)); for qi in r.questions.indices { steps.append(Step(kind: .repeated,round: ri,question: qi,duration: r.repeatSeconds)) } }
            if !phoneMode { steps.append(Step(kind: .pause,round: ri,duration: r.breakSeconds)) }
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
        background.beginGame(); playing = true; paused = false; index = 0; beginArchiveRun(); enter(); if phoneMode && tv != nil { showTV() }; checkpoint(copyAssets: true)
    }
    func enter() {
        archiveEnteredStep()
        phoneRoom.questionChanged()
        showScoreInputLocally = false
        playback.stop(); bleep?.stop(); signalPlayer?.stop(); startSignalSent = false; transitionElapsed = 0; publishedScores = false; mediaDone = true; waitingForMedia = false; elapsed = 0
        scoreSnapshot = []; scoreRevealedIDs = []; scoreGroups = []; scoreRevealGroup = 0; scoreRevealElapsed = 0
        guard let s = step else { return }; remaining = s.duration
        awaitingQuestionStart = readBeforeTimer && s.kind == .question
        if !isEditorPreview && s.kind == .standings && NSScreen.screens.count > 1 { showTV() }
        if s.kind == .roundIntro, let url = asset(quiz.rounds[s.round].intro?.media) {
            mediaDone = false; playback.start(url: url,autoplay: !paused); return
        }
        if [.question,.repeated,.answer].contains(s.kind), let q = currentQuestion, let url = asset(s.kind == .answer ? (q.explanationMedia ?? q.media) : q.media) {
            mediaDone = false; waitingForMedia = s.kind == .question && q.afterMedia
            let settings = q.settings(answer:s.kind == .answer)
            playback.start(url:url,start:settings.start,end:settings.end,autoplay:!paused && !awaitingQuestionStart,effects:settings)
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
    func stop(preserveRecovery: Bool = false) {
        autosave(); var keepRecovery = preserveRecovery
        if phoneMode && playing {
            do { try persistResults() } catch { keepRecovery = true; status = "Баллы сохранены в восстановлении, но файл квиза записать не удалось: " + error.localizedDescription }
        }
        if playing { persistArchive(status:step?.kind == .finish ? "completed" : keepRecovery ? "paused" : "stopped") }
        archiveRun = nil
        phoneRoom.stop(clear: !keepRecovery); if !keepRecovery { clearRecovery() }
        signalPlayer?.stop(); background.stop(); playback.stop(); bleep?.stop(); playing = false; screen = .home; tv?.close(); tv = nil
    }
    func returnToMenu() { stop(); screen = .home }
    func showTV() {
        if let tv {
            tv.contentView = NSHostingView(rootView: playing ? AnyView(Stage(studio:self,audience:true)) : AnyView(PhoneJoinScreen(room:phoneRoom)))
            tv.makeKeyAndOrderFront(nil); return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens[min(max(0,selectedScreen),screens.count-1)]
        let window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Квиз — экран участников"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: playing ? AnyView(Stage(studio: self, audience: true)) : AnyView(PhoneJoinScreen(room:phoneRoom)))
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
    var phone: PhoneRecovery? = nil
    var archive: ArchiveRunState? = nil
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
        if playing { persistArchive() }
        guard !isEditorPreview, playing, let s = step, s.kind != .finish else { return }
        do {
            if copyAssets {
                if folder?.standardizedFileURL != recoveryFolder.standardizedFileURL {
                    try? FileManager.default.removeItem(at: recoveryFolder.appendingPathComponent("Media"))
                }
                try writeDirectory(to: recoveryFolder)
            }
            let state = GameRecovery(quiz: quiz,steps: steps,layouts: matchLayouts,index: index,remaining: remaining,elapsed: elapsed,awaiting: awaitingQuestionStart,mediaDone: mediaDone || playback.finished,position: playback.player?.currentTime().seconds ?? 0,automatic: automaticAdvance,readFirst: readBeforeTimer,document: documentURL?.path,published: publishedScores,snapshot: scoreSnapshot,revealed: scoreRevealedIDs,groups: scoreGroups,revealGroup: scoreRevealGroup,revealElapsed: scoreRevealElapsed,phone: phoneMode ? phoneRoom.recovery : nil,archive:archiveRun)
            try FileManager.default.createDirectory(at: recoveryFolder,withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: recoveryURL,options: .atomic)
            recoveryAvailable = true
        } catch { status = "Не удалось сохранить точку восстановления: " + error.localizedDescription }
    }
    func clearRecovery() { guard !isEditorPreview else { return }; try? FileManager.default.removeItem(at: recoveryURL); recoveryAvailable = false }
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
            phoneMode = state.phone != nil
            if let phone = state.phone { phoneRoom.start(restoring: phone) } else { phoneRoom.stop() }
            archiveRun = state.archive ?? ArchiveRunState()
            playing = true; paused = true; background.beginGame(); background.muted = true
            enter(); remaining = max(0,state.remaining); elapsed = max(0,min(1,state.elapsed)); awaitingQuestionStart = state.awaiting
            if state.mediaDone { playback.stop(); mediaDone = true; waitingForMedia = false }
            else if step?.kind == .roundIntro, let s = step, let url = asset(quiz.rounds[s.round].intro?.media) {
                playback.start(url: url,start: state.position.isFinite ? max(0,state.position) : 0,autoplay: false)
            }
            else if let clip = currentQuestion, let url = asset(step?.kind == .answer ? (clip.explanationMedia ?? clip.media) : clip.media) {
                let settings = clip.settings(answer:step?.kind == .answer)
                let start = settings.start
                let end = settings.end
                let position = state.position.isFinite && state.position >= start && (end == 0 || state.position < end) ? state.position : start
                playback.start(url: url,start: position,end: end,autoplay: false,effects:settings)
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
        redoHistory.append(quiz)
        suppressUndo = true; quiz = previous; suppressUndo = false
        roundIndex = min(roundIndex,max(0,quiz.rounds.count-1)); questionIndex = min(questionIndex,max(0,quiz.rounds[roundIndex].questions.count-1))
        autosave()
    }
    func redoEdit() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(quiz)
        suppressUndo = true; quiz = next; suppressUndo = false
        roundIndex = min(roundIndex,max(0,quiz.rounds.count-1)); questionIndex = min(questionIndex,max(0,quiz.rounds[roundIndex].questions.count-1))
        autosave()
    }
    func stepTitle(_ index: Int) -> String {
        guard steps.indices.contains(index) else { return "" }
        let s = steps[index]; let r = quiz.rounds[s.round]
        switch s.kind {
        case .introduction: return "Представление: " + quiz.teams[s.question].name
        case .roundIntro: return r.title + " — правила"
        case .block: return r.title + " — "+((s.block.flatMap { (r.blocks ?? []).indices.contains($0) ? r.blocks![$0].kind : nil }) ?? "вставной блок")
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
                let questionSettings = q.settings(answer:false); let answerSettings = q.settings(answer:true)
                if let name = q.media { a.append((name,questionSettings.start,questionSettings.end,round.title + ": " + q.text)) }
                if let name = q.explanationMedia ?? q.media { a.append((name,answerSettings.start,answerSettings.end,"Объяснение: " + q.text)) }; return a
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
        copy.quiz.bankHistoryID = UUID()
        copy.quiz.title += " — копия"
        for i in copy.quiz.teams.indices { copy.quiz.teams[i].scores = [:] }
        try copy.write(to: destination)
        if let id = copy.quiz.bankHistoryID {
            try questionBank.recordUse(questionIDs:Set(copy.quiz.rounds.flatMap(\.questions).compactMap(\.bankEntryID)),quizID:id,title:copy.quiz.title,played:false)
        }
        remember(destination)
        status = "Создана копия: " + destination.lastPathComponent
    }
    func duplicateQuiz(_ source: URL) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "local.quizstudio.quiz",conformingTo: .data)]; panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " — копия.quiz"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try duplicateQuiz(from: source,to: destination) } catch { status = "Не удалось создать копию: " + error.localizedDescription }
    }
    func exportQuiz(_ source: URL) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs:"local.quizstudio.quiz",conformingTo:.data)]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " — экспорт.quiz"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard source.standardizedFileURL != destination.standardizedFileURL else { throw CocoaError(.fileWriteFileExists) }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("QuizExport-" + UUID().uuidString)
            let copy = Studio(draftURL:scratch.appendingPathComponent("Draft.workspace")); copy.timer?.invalidate()
            defer { if (try? source.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) != true, let folder = copy.folder { try? FileManager.default.removeItem(at:folder) } }
            guard copy.load(source) else { throw NSError(domain:"QuizExport",code:1,userInfo:[NSLocalizedDescriptionKey:copy.status]) }
            var assets: [String:Data] = [:]
            for name in copy.referencedAssets {
                guard let asset = copy.asset(name) else { throw CocoaError(.fileNoSuchFile) }
                assets[name] = try Data(contentsOf:asset)
            }
            try JSONEncoder().encode(QuizFile(quiz:copy.quiz,assets:assets)).write(to:destination,options:.atomic)
            remember(destination); status = "Экспортирован переносимый квиз: " + destination.lastPathComponent
        } catch { status = "Не удалось экспортировать квиз: " + error.localizedDescription }
    }
    func saveCopy() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "local.quizstudio.quiz",conformingTo: .data)]; panel.nameFieldStringValue = quiz.title + " — копия.quiz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != documentURL?.standardizedFileURL else { status = "Для копии выберите другое имя файла."; return }
        do { let originalID = quiz.bankHistoryID; quiz.bankHistoryID = UUID(); defer { quiz.bankHistoryID = originalID }; try write(to: url); remember(url); status = "Копия сохранена. Вы продолжаете редактировать исходный квиз." } catch { status = error.localizedDescription }
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
struct QuizImage: View {
    let url: URL
    var masks: [ImageMask] = []
    var body: some View {
        if url.pathExtension.lowercased() == "gif" {
            AnimatedQuizImage(url:url)
        } else {
            GeometryReader { geometry in
                if let image = NSImage(contentsOf:url) {
                    let size = image.size
                    let scale = min(geometry.size.width/max(1,size.width),geometry.size.height/max(1,size.height))
                    let shown = CGSize(width:size.width*scale,height:size.height*scale)
                    let origin = CGPoint(x:(geometry.size.width-shown.width)/2,y:(geometry.size.height-shown.height)/2)
                    ZStack(alignment:.topLeading) {
                        Image(nsImage:image).resizable().scaledToFit().frame(width:geometry.size.width,height:geometry.size.height)
                        ForEach(masks) { mask in
                            Rectangle().fill(.black)
                                .frame(width:shown.width*mask.width,height:shown.height*mask.height)
                                .offset(x:origin.x+shown.width*mask.x,y:origin.y+shown.height*mask.y)
                        }
                    }.clipped()
                }
            }
        }
    }
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
        .contextMenu {
            Button("Дублировать вопрос", systemImage: "plus.square.on.square") { select(); studio.duplicateSelectedQuestion() }
            Button("Сохранить в банк вопросов", systemImage: "tray.and.arrow.down") { select(); studio.saveSelectedToBank() }
            Divider()
            Button("Удалить вопрос", systemImage: "trash", role: .destructive) { select(); studio.deleteSelectedQuestion() }
        }
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
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    var appearance: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    var body: some Scene {
        WindowGroup("Квиз Студия · 0.18.0 — тестовая сборка") { Content(studio: studio).onAppear { appDelegate.install(studio) }.frame(minWidth: 1050,minHeight: 720).preferredColorScheme(appearance).onChange(of: studio.quiz) { _,_ in studio.autosave() }.onOpenURL { url in if url.pathExtension.lowercased() == "siq" { studio.chooseSIQ(url) } else if !studio.playing && studio.load(url) { studio.prepareGame() } } }
        .commands {
            CommandGroup(replacing: .newItem) { Button("Создать квиз") { studio.newQuiz() }.keyboardShortcut("n").disabled(studio.playing); Button("Открыть квиз…") { studio.open() }.keyboardShortcut("o").disabled(studio.playing); Button("Сохранить квиз…") { studio.save() }.keyboardShortcut("s") }
            CommandGroup(after:.textEditing) {
                Button("Найти") {
                    if studio.screen == .editor { studio.focusEditorSearch = true }
                    else if studio.screen == .library || studio.screen == .createLibrary { studio.focusLibrarySearch = true }
                }.keyboardShortcut("f")
            }
        }
        Settings { AppearanceSettings() }
    }
}
struct AppearanceSettings: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    var body: some View {
        Form {
            Picker("Оформление",selection:$appearanceMode) {
                Text("Как в системе").tag("system")
                Text("Светлое").tag("light")
                Text("Тёмное").tag("dark")
            }
            Text("Выбор влияет на окна редактора и библиотеки. Экран участников сохраняет оформление квиза.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width:420)
    }
}
struct QuestionBankView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var bank: QuestionBank
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var category = "Все"
    @State private var selection: Set<UUID> = []
    @State private var editing: BankEntry?
    @State private var creating = false
    @State private var showArchived = false
    @State private var tag = "Все темы"
    @State private var difficulty = "Любая сложность"
    @State private var unusedOnly = false
    @State private var bulkImport = false
    @State private var assembly = false
    @State private var error: String?
    init(studio: Studio) { self.studio = studio; self.bank = studio.questionBank }
    var visible: [BankEntry] {
        bank.entries.filter { entry in entry.archived == showArchived && (tag == "Все темы" || (entry.question.tags ?? []).contains(tag)) && (difficulty == "Любая сложность" || (entry.question.difficulty ?? "Не указана") == difficulty) && (!unusedOnly || (entry.history ?? []).isEmpty) && (category == "Все" || entry.question.bankCategories.contains(category)) && (search.isEmpty || [entry.question.text,entry.question.correctAnswer,entry.question.hostNotes ?? "",entry.origin ?? "",(entry.question.tags ?? []).joined(separator:" ")].joined(separator:" ").localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("Банк вопросов").font(.largeTitle.bold()); Spacer(); Menu("Импорт…",systemImage:"square.and.arrow.down") { Button("Вопросы из таблицы или текста…") { bulkImport = true }; Button("Пак «Своя игра» (.siq)…") { studio.chooseSIQ() } }; Button("Собрать квиз") { assembly = true }; Button("Новая идея",systemImage:"plus") { creating = true }.buttonStyle(.borderedProminent) }
            DisclosureGroup("О банке вопросов") {
                Text("Вопрос может входить в несколько категорий. Открытый вопрос — игроки вводят ответ сами. Незавершённые идеи сохраняются как черновики.").font(.caption).foregroundStyle(.secondary).padding(.top,4)
            }
            HStack { TextField("Поиск по вопросу, ответу или источнику",text:$search); Toggle("Архив",isOn:$showArchived).toggleStyle(.switch) }
            DisclosureGroup("Фильтры · \(category) · \(tag) · \(difficulty)") {
                VStack(alignment:.leading,spacing:8) {
                    Picker("Категория",selection:$category) { ForEach(["Все","Аудио / видео","4 варианта","Открытые вопросы","Сопоставление","Числовой ответ","Порядок событий","Несколько вариантов","Категоризация"],id:\.self) { Text($0) } }
                    Picker("Тема",selection:$tag) { Text("Все темы").tag("Все темы"); ForEach(Array(Set(bank.entries.flatMap { $0.question.tags ?? [] })).sorted(),id:\.self) { Text($0).tag($0) } }
                    Picker("Сложность",selection:$difficulty) { ForEach(["Любая сложность","Не указана","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) } }
                    Toggle("Ещё не использовались",isOn:$unusedOnly)
                }.padding(.top,6)
            }
            Text("Найдено: \(visible.count) · Всего в банке: \(bank.entries.filter { !$0.archived }.count)").font(.caption)
            List(visible) { entry in
                HStack(alignment:.top,spacing:12) {
                    if studio.screen == .editor && !showArchived {
                        Toggle("Выбрать",isOn:Binding(get:{ selection.contains(entry.id) },set:{ if $0 { selection.insert(entry.id) } else { selection.remove(entry.id) } })).labelsHidden()
                    }
                    VStack(alignment:.leading,spacing:5) {
                        Text(entry.question.text.isEmpty ? "Без текста — новая идея" : entry.question.text).font(.headline).lineLimit(3)
                        Text(entry.question.bankCategories.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                        Text(((entry.question.tags ?? [])+[entry.question.difficulty].compactMap { $0 }).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                        if let history = entry.history, !history.isEmpty {
                            DisclosureGroup("Использован в квизах: \(history.count)") {
                                ForEach(history) { use in Text("\(use.title) · \(use.played ? "игра запускалась" : "включён в квиз") · \(use.date.formatted(date:.abbreviated,time:.omitted))").font(.caption) }
                            }.foregroundStyle(.orange)
                        }
                        if studio.quiz.rounds.flatMap(\.questions).contains(where:{ $0.bankEntryID == entry.id }) { Text("Уже есть в текущем квизе").font(.caption).foregroundStyle(.orange) }
                        if let origin = entry.origin { Text(origin).font(.caption).foregroundStyle(.secondary) }
                        if !entry.question.issues.isEmpty { Text("Черновик: "+entry.question.issues.joined(separator:"; ")).font(.caption).foregroundStyle(.orange) }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Button("Изменить") { editing = entry }
                    Button(showArchived ? "Восстановить" : "В архив") { do { try bank.setArchived(entry,!entry.archived); selection.remove(entry.id) } catch { self.error = error.localizedDescription } }
                }.padding(.vertical,6)
            }.overlay { if visible.isEmpty { Text("Здесь пока нет вопросов. Добавьте идею или импортируйте пак .siq из главного меню.").foregroundStyle(.secondary).padding().allowsHitTesting(false) } }
            if let error { Text(error).foregroundStyle(.red) }
            Text(bank.message).font(.caption).foregroundStyle(.secondary)
            if studio.screen == .editor {
                HStack { Text("Добавление в текущий раунд после выбранного вопроса").font(.caption); Spacer(); Button("Добавить выбранные (\(selection.count))") {
                    do { try studio.insertBankQuestions(bank.entries.filter { selection.contains($0.id) && !$0.archived }); studio.showQuestionBank=false; dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(selection.isEmpty) }
            }
        }.padding(16).frame(minWidth:850,minHeight:620)
        .sheet(isPresented:$bulkImport) { BulkQuestionImportView(studio:studio) }
        .sheet(isPresented:$assembly) { QuizAssemblyView(studio:studio) }
        .sheet(isPresented:$creating) { BankQuestionEditor(bank:bank,entry:nil) }
        .sheet(item:$editing) { BankQuestionEditor(bank:bank,entry:$0) }
    }
}
struct BankQuestionEditor: View {
    @ObservedObject var bank: QuestionBank
    let entry: BankEntry?
    @StateObject private var session: Studio
    @Environment(\.dismiss) var dismiss
    @State private var error: String?
    init(bank: QuestionBank,entry: BankEntry?) {
        self.bank = bank; self.entry = entry
        let session = Studio(draftURL:FileManager.default.temporaryDirectory.appendingPathComponent("BankEdit-"+UUID().uuidString+".workspace"))
        session.timer?.invalidate(); session.rememberRecent = false
        do {
            let record = try entry.map { try bank.record($0) }
            var quiz = Quiz(); quiz.title = "Вопрос для банка"; quiz.rounds = [Round()]; quiz.rounds[0].questions = [record?.entry.question ?? Question()]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BankEdit-"+UUID().uuidString+".quiz")
            try JSONEncoder().encode(QuizFile(quiz:quiz,assets:record?.assets ?? [:])).write(to:url,options:.atomic)
            guard session.load(url) else { throw SIQError(message:session.status) }
        } catch { session.status = "Не удалось открыть вопрос: "+error.localizedDescription }
        _session = StateObject(wrappedValue:session)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(entry == nil ? "Новая идея для вопроса" : "Редактирование вопроса банка").font(.title2.bold()); Spacer(); Button("Отмена") { dismiss() }; Button("Сохранить в банк") {
                guard let q = session.selectedQuestion else { return }
                do { _ = try bank.save(q,assets:session.bankQuestionAssets(q),existing:entry); dismiss() } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(session.status.hasPrefix("Не удалось открыть")) }
            Text("Можно сохранить незаполненную идею и вернуться к ней позже. Категории определятся по типу вопроса и медиа.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            if session.status.hasPrefix("Не удалось открыть") { Text(session.status).foregroundStyle(.red) }
            ScrollView { if let q = session.selectedQuestion { QuestionEditor(studio:session,question:session.questionBinding(q.id)).padding() } }
        }.padding(20).frame(width:920,height:720)
        .sheet(item:$session.editorPreview) { mode in EditorPreview(studio:session,mode:mode) }
        .onDisappear { session.playback.stop(); session.timer?.invalidate() }
    }
}

struct QuestionMetadataEditor: View {
    @Binding var question: Question
    @State private var tagsText = ""
    var body: some View {
        HStack {
            TextField("Темы через запятую: кино, музыка…",text:$tagsText).onChange(of:tagsText) { _,text in question.tags = Question.cleanTags(text) }
            Picker("Сложность",selection:Binding(get:{ question.difficulty ?? "Не указана" },set:{ question.difficulty = $0 == "Не указана" ? nil : $0 })) {
                ForEach(["Не указана","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) }
            }.frame(width:230)
        }.onAppear { tagsText = (question.tags ?? []).joined(separator:", ") }.onChange(of:question.id) { _,_ in tagsText = (question.tags ?? []).joined(separator:", ") }
    }
}
struct BulkQuestionSettings: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    @State private var useSeconds = true
    @State private var seconds = 60
    @State private var useMedia = false
    @State private var afterMedia = true
    @State private var useAnswer = false
    @State private var answerSeconds = 20
    var ids: Set<UUID> { studio.editorSelection.intersection(Set(studio.quiz.rounds.flatMap(\.questions).map(\.id))) }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Массовые настройки · \(ids.count) вопросов").font(.title2.bold())
            Text("Изменятся только отмеченные настройки. Кнопка «Отменить изменение» в редакторе отменит всю операцию.").font(.callout).foregroundStyle(.secondary)
            Toggle("Изменить время вопроса",isOn:$useSeconds)
            if useSeconds { Stepper(seconds == 0 ? "Без отсчёта" : "Время: \(seconds) сек",value:$seconds,in:0...3600,step:5) }
            Toggle("Изменить запуск таймера для медиа",isOn:$useMedia)
            if useMedia { Toggle("Таймер после фрагмента",isOn:$afterMedia) }
            Toggle("Изменить время показа ответа",isOn:$useAnswer)
            if useAnswer { Stepper("Ответ: \(answerSeconds) сек",value:$answerSeconds,in:1...600) }
            HStack { Button("Отмена") { dismiss() }; Spacer(); Button("Применить") { studio.applyBulk(ids:ids,seconds:useSeconds ? seconds : nil,afterMedia:useMedia ? afterMedia : nil,answerSeconds:useAnswer ? answerSeconds : nil); dismiss() }.buttonStyle(.borderedProminent).disabled(ids.isEmpty || !(useSeconds || useMedia || useAnswer)) }
        }.padding(24).frame(width:530)
    }
}
struct RoundTemplatePicker: View {
    @ObservedObject var studio: Studio
    let roundID: UUID
    @ObservedObject var store: RoundTemplateStore
    @Environment(\.dismiss) var dismiss
    @State private var selected = RoundTemplate.builtins[0].id
    @State private var name = ""
    @State private var error: String?
    init(studio: Studio,roundID: UUID) { self.studio = studio; self.roundID = roundID; self.store = studio.roundTemplates }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Шаблоны раундов").font(.title2.bold())
            Picker("Шаблон",selection:$selected) { ForEach(store.all) { Text($0.name).tag($0.id) } }
            if let template = store.all.first(where:{ $0.id == selected }) {
                Text("Вопрос: \(template.seconds) сек · Медиа: \(template.audioOnly.map { $0 ? "без видео" : "с видео" } ?? "без изменения") · Ответ: \(template.answerSeconds) сек\nТаймер: \(template.afterMedia ? "после медиа" : "во время медиа") · Повтор: \(template.repeatQuestions ? "да" : "нет")\nСдача бланков: \(template.breakSeconds) сек · Итоги: \(template.standings ? "да" : "нет")")
            }
            Text("Шаблон применится к настройкам раунда и времени всех его вопросов. Тексты, медиа и число вопросов сохранятся. Новые вопросы получат эти настройки.").font(.callout).foregroundStyle(.secondary)
            HStack { Button("Закрыть") { dismiss() }; Spacer(); Button("Применить к раунду") { if let template = store.all.first(where:{ $0.id == selected }) { studio.applyTemplate(template,roundID:roundID); dismiss() } }.buttonStyle(.borderedProminent) }
            Divider()
            Text("Сохранить текущие настройки как свой шаблон").bold()
            HStack { TextField("Название шаблона",text:$name); Button("Сохранить шаблон") {
                guard let round = studio.quiz.rounds.first(where:{ $0.id == roundID }) else { return }
                do { try store.save(name:name,round:round); error = nil; if let last = store.custom.first(where:{ $0.name.localizedCaseInsensitiveCompare(name.trimmingCharacters(in:.whitespacesAndNewlines)) == .orderedSame }) { selected = last.id } } catch { self.error = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
            Text("Одинаковое название обновляет ваш шаблон.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            if !store.error.isEmpty { Text(store.error).foregroundStyle(.red) }
        }.padding(24).frame(width:610)
    }
}
struct EditorPreview: View {
    @StateObject private var session: Studio
    @Environment(\.dismiss) var dismiss
    init(studio: Studio,mode: EditorPreviewMode) {
        let session = Studio(draftURL:FileManager.default.temporaryDirectory.appendingPathComponent("EditorPreview-"+UUID().uuidString+".workspace"))
        session.beginEditorPreview(from:studio,mode:mode)
        _session = StateObject(wrappedValue:session)
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text("Предпросмотр · экран участников").bold(); Spacer()
                Toggle("Автопереход",isOn:$session.automaticAdvance)
                Button("Сначала") { session.index = 0; session.paused = false; session.enter() }
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Stage(studio:session,audience:true).frame(minHeight:520)
            HStack {
                Button("Назад") { session.back() }.disabled(session.index == 0)
                Button(session.awaitingQuestionStart ? "Запустить таймер" : session.paused ? "Продолжить" : "Пауза") { session.togglePause() }.disabled(session.step?.kind == .finish)
                Button("Вперёд") { session.next() }.disabled(session.step?.kind == .finish)
                Spacer(); Text(session.step?.kind == .finish ? "Предпросмотр завершён" : "\(session.index+1) / \(session.steps.count-1)").font(.caption)
            }.padding(12)
            if !session.status.isEmpty { Text(session.status).font(.caption).foregroundStyle(.orange).padding(6) }
        }.frame(minWidth:1000,minHeight:650)
        .onDisappear { session.endEditorPreview() }
    }
}

struct Content: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing:0) {
            if !studio.playing { AppSectionBar(studio:studio) }
            Group {
                if studio.showQuestionBank { QuestionBankView(studio:studio) }
                else if studio.showGameArchive { GameArchiveView(studio:studio) }
                else if studio.playing { PlayerView(studio: studio) }
                else { switch studio.screen {
                case .home: Welcome(studio: studio)
                case .library: QuizLibrary(studio: studio)
                case .createLibrary: QuizLibrary(studio: studio,editing: true)
                case .teams: TeamSetup(studio: studio)
                case .editor: Editor(studio: studio)
                } }
            }
        }
        .tint(.indigo)
        .sheet(item:$studio.editorPreview) { mode in EditorPreview(studio:studio,mode:mode) }
        .sheet(isPresented:$studio.showBulkEdit) { BulkQuestionSettings(studio:studio) }
        .sheet(isPresented:$studio.showBulkImport) { BulkQuestionImportView(studio:studio) }
        .sheet(isPresented:$studio.showQuizAssembly) { QuizAssemblyView(studio:studio) }
        .sheet(isPresented:$studio.showSIQImport) { if let url = studio.siqSource { SIQImportView(studio:studio,source:url) } }
    }
}
struct AppSectionBar: View {
    @ObservedObject var studio: Studio
    var body: some View {
        HStack(spacing:6) {
            section("Главная","house",selected:studio.screen == .home && !studio.showQuestionBank && !studio.showGameArchive) {
                studio.showQuestionBank=false; studio.showGameArchive=false
                if studio.screen == .editor { studio.leaveEditor(destination:.home) } else { studio.screen = .home }
            }
            section("Мои квизы","rectangle.stack",selected:(studio.screen == .library || studio.screen == .createLibrary) && !studio.showQuestionBank && !studio.showGameArchive) {
                studio.showQuestionBank=false; studio.showGameArchive=false
                if studio.screen == .editor { studio.leaveEditor(destination:.createLibrary) } else { studio.screen = .createLibrary }
            }
            section("Банк вопросов","tray.full",selected:studio.showQuestionBank) {
                studio.showGameArchive=false; studio.showQuestionBank=true
            }
            section("Архив игр","chart.bar.doc.horizontal",selected:studio.showGameArchive) {
                studio.showQuestionBank=false; studio.persistArchive(); studio.showGameArchive=true
            }
            Spacer(minLength:0)
        }.buttonStyle(.plain).padding(.horizontal,12).padding(.vertical,7)
            .background(.bar)
            .overlay(alignment:.bottom) { Divider() }
    }
    private func section(_ title:String,_ icon:String,selected:Bool,action:@escaping ()->Void) -> some View {
        Button(action:action) {
            Label(title,systemImage:icon).font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal,10).padding(.vertical,6)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear,in:Capsule())
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }.help(title)
    }
}
struct Editor: View {
    @ObservedObject var studio: Studio
    @State private var editorSection = "Вопрос"
    @State private var showQuizTemplateSave = false
    @State private var showInspector = true
    @State private var tableMode = false
    @State private var questionSearch = ""
    @State private var showEditorIssues = false
    @FocusState private var questionSearchFocused: Bool
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading,spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("СОДЕРЖАНИЕ КВИЗА").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(studio.quiz.title.isEmpty ? "Без названия" : studio.quiz.title).font(.headline).lineLimit(1)
                }.padding(.horizontal, 12).padding(.top, 8)
                TextField("Найти вопрос…", text: $questionSearch).textFieldStyle(.roundedBorder).padding(.horizontal, 10).focused($questionSearchFocused)
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 8,pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(studio.quiz.rounds.enumerated()),id: \.element.id) { ri,r in
                        Section {
                            ForEach(Array(r.questions.enumerated()).filter { questionSearch.isEmpty || $0.element.text.localizedCaseInsensitiveContains(questionSearch) || $0.element.correctAnswer.localizedCaseInsensitiveContains(questionSearch) },id: \.element.id) { qi,q in
                                HStack(spacing:5) {
                                Toggle("Выбрать вопрос \(qi+1)",isOn:Binding(get:{ studio.editorSelection.contains(q.id) },set:{ if $0 { studio.editorSelection.insert(q.id) } else { studio.editorSelection.remove(q.id) } })).labelsHidden().help("Выбрать для массового изменения")
                                DraggableQuestionRow(studio: studio,roundID: r.id,question: q,number: qi+1,selected: studio.selectedQuestion?.id == q.id) {
                                    studio.roundIndex = ri; studio.questionIndex = qi; editorSection = "Вопрос"
                                }
                                if q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Не указан правильный ответ")
                                }
                                }
                            }
                            RoundDropTarget(studio: studio,roundID: r.id)
                        } header: {
                            HStack {
                                Image(systemName:"line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
                                    .onDrag { NSItemProvider(object:r.id.uuidString as NSString) }
                                    .help("Перетащите, чтобы изменить порядок раундов")
                                Button { studio.selectRound(r.id); editorSection = "Раунд" } label: {
                                    HStack { Text(r.title).font(.subheadline.weight(.semibold)); Spacer(); Text("\(r.questions.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }.padding(.vertical, 3)
                                }.buttonStyle(.plain).help("Открыть настройки раунда")
                                Menu {
                                    Button("Настроить раунд") { studio.selectRound(r.id); editorSection = "Раунд" }
                                    Button("Дублировать раунд",systemImage:"plus.square.on.square") { studio.duplicateRound(r.id) }
                                    if ri > 0 { Button("Переместить выше",systemImage:"arrow.up") { _ = studio.moveRound(r.id,before:studio.quiz.rounds[ri-1].id) } }
                                    if ri+1 < studio.quiz.rounds.count { Button("Переместить ниже",systemImage:"arrow.down") { _ = studio.moveRound(r.id,before:ri+2 < studio.quiz.rounds.count ? studio.quiz.rounds[ri+2].id : nil) } }
                                    if r.questions.isEmpty && studio.quiz.rounds.count > 1 { Divider(); Button("Удалить пустой раунд",role:.destructive) { studio.deleteEmptyRound(r.id) } }
                                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }.menuStyle(.borderlessButton)
                            }.onDrop(of:[UTType.text],isTargeted:nil) { providers in studio.acceptRoundDrop(providers,before:r.id) }
                        }
                    }
                    }.padding(.horizontal,8)
                }
                Button("Следующий раунд",systemImage: "plus.rectangle.on.rectangle") { studio.addRound() }.padding()
            }.padding(.top)
            .navigationSplitViewColumnWidth(min: 190,ideal: 240,max:300)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                Button { studio.leaveEditor() } label: { Image(systemName:"house") }
                        .help("В главное меню")
                    TextField("Название квиза",text: $studio.quiz.title).font(.title2.bold()).textFieldStyle(.plain).lineLimit(1).frame(minWidth:70,idealWidth:220,maxWidth:300)
                    Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(showInspector ? "Скрыть параметры" : "Показать параметры")
                    Button { tableMode.toggle() } label: {
                        Image(systemName: tableMode ? "tablecells" : "rectangle.and.pencil.and.ellipsis")
                    }.help(tableMode ? "Табличный вид" : "Вид редактора")
                    Menu {
                        Button("Отменить изменение", systemImage: "arrow.uturn.backward") { studio.undoEdit() }.keyboardShortcut("z").disabled(studio.undoHistory.isEmpty)
                        Button("Повторить изменение", systemImage: "arrow.uturn.forward") { studio.redoEdit() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(studio.redoHistory.isEmpty)
                        Button("Дублировать вопрос", systemImage: "plus.square.on.square") { studio.duplicateSelectedQuestion() }.keyboardShortcut("d").disabled(studio.selectedQuestion == nil)
                        Divider()
                        Button("Импортировать вопросы…", systemImage: "tablecells") { studio.showBulkImport = true }
                        Button("Собрать квиз из банка…", systemImage: "sparkles") { studio.showQuizAssembly = true }
                        Button("Открыть банк вопросов…", systemImage: "tray.full") { studio.showQuestionBank = true }
                        Button("Сохранить как шаблон квиза…",systemImage:"square.grid.3x3") { showQuizTemplateSave = true }
                        if !studio.editorSelection.isEmpty {
                            Divider()
                            Button("Выбрать все вопросы раунда") { studio.editorSelection = Set(studio.quiz.rounds[studio.roundIndex].questions.map(\.id)) }
                            Button("Снять выделение") { studio.editorSelection = [] }
                            Button("Массовые настройки…") { studio.showBulkEdit = true }
                                .disabled(studio.editorSelection.intersection(Set(studio.quiz.rounds.flatMap(\.questions).map(\.id))).isEmpty)
                        }
                        Divider()
                        Button("Печатные бланки…", systemImage: "doc.text") { studio.printSheets() }
                        Button("Сохранить копию…", systemImage: "doc.on.doc") { studio.saveCopy() }
                    } label: { Label("Инструменты",systemImage:"ellipsis.circle") }.labelStyle(.iconOnly).help("Инструменты")
                    Menu {
                        Button("Мои квизы",systemImage:"rectangle.stack") { studio.leaveEditor(destination:.createLibrary) }
                        Button("Сохранить копию…", systemImage: "doc.on.doc") { studio.saveCopy() }
                        Button("Печатные бланки…", systemImage: "doc.text") { studio.printSheets() }
                    } label: { Image(systemName:"ellipsis") }.help("Дополнительные действия")
                    Button("Сохранить") { studio.save() }
                    Button("Начать игру",systemImage: "play.fill") { studio.prepareGame() }.buttonStyle(.borderedProminent)
                }.padding(.horizontal,10).padding(.vertical,7).frame(maxWidth:.infinity,alignment:.leading)
                Divider()
                HSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Picker("Раздел редактора", selection: $editorSection) {
                                Text("Вопрос").tag("Вопрос")
                                Text("Раунд").tag("Раунд")
                                Text("Оформление").tag("Оформление")
                            }.pickerStyle(.segmented).frame(maxWidth: 420)
                            Spacer()
                        }.padding(.horizontal, 22).padding(.vertical, 12)
                        Divider()
                        ScrollView { VStack(alignment: .leading,spacing: 24) {
                            if editorSection == "Оформление" {
                                AppearanceEditor(studio: studio, expanded: true)
                            } else if editorSection == "Раунд" {
                                RoundSettings(studio: studio, round: studio.roundBinding(studio.quiz.rounds[studio.roundIndex].id))
                            } else if tableMode {
                                QuizQuestionTable(studio: studio,filter:questionSearch)
                            } else if let selected = studio.selectedQuestion {
                                QuestionEditor(studio: studio,question: studio.questionBinding(selected.id)).id(selected.id)
                            } else {
                                ContentUnavailableView("В этом раунде пока нет вопросов",systemImage: "text.badge.plus",description: Text("Добавьте вопрос или возьмите его из банка.")).frame(maxWidth: .infinity, minHeight: 220)
                            }
                            HStack {
                                Button("Добавить из банка…",systemImage:"tray.full") { studio.showQuestionBank = true }
                                Button("Добавить вопрос",systemImage: "plus") { studio.addQuestion() }.buttonStyle(.borderedProminent)
                                Spacer()
                                Menu {
                                    Button("Сохранить вопрос в банк") { studio.saveSelectedToBank() }.disabled(studio.selectedQuestion == nil)
                                    Button("Удалить вопрос",role: .destructive) { studio.deleteSelectedQuestion() }.disabled(studio.selectedQuestion == nil)
                                } label: { Label("Ещё",systemImage:"ellipsis") }.contentShape(Rectangle()).help("Дополнительные действия")
                            }
                        }.padding(16) }
                    }
                    if showInspector && !tableMode && editorSection == "Вопрос", let selected = studio.selectedQuestion {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Label("Параметры вопроса", systemImage: "slider.horizontal.3").font(.headline)
                                Picker("Тип вопроса", selection: studio.questionBinding(selected.id).kind) {
                                    ForEach(Question.kinds, id: \.self) { Text($0) }
                                }
                                VStack(alignment:.leading,spacing:8) {
                                    Text("Темы").font(.caption).foregroundStyle(.secondary)
                                    TextField("Кино, музыка…",text:Binding(get:{ (selected.tags ?? []).joined(separator:", ") },set:{ studio.questionBinding(selected.id).wrappedValue.tags = Question.cleanTags($0) }))
                                    Text("Сложность").font(.caption).foregroundStyle(.secondary)
                                    Picker("Сложность",selection:Binding(get:{ selected.difficulty ?? "Не указана" },set:{ studio.questionBinding(selected.id).wrappedValue.difficulty = $0 == "Не указана" ? nil : $0 })) {
                                        ForEach(["Не указана","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) }
                                    }
                                }
                                Stepper("Время: \(selected.seconds == 0 ? "без таймера" : "\(selected.seconds) сек")", value: studio.questionBinding(selected.id).seconds, in: 0...600, step: 5)
                                ScoringRulesEditor(question: studio.questionBinding(selected.id))
                            }.padding(16)
                        }.frame(minWidth: 190, idealWidth: 280, maxWidth: 320)
                    }
                }
                HStack(spacing:12) {
                    let issueCount = studio.preflightIssues.isEmpty ? studio.incompleteQuestions.count : studio.preflightIssues.count
                    Label(studio.lastAutosave.map { "Сохранено \($0.formatted(date:.omitted,time:.shortened))" } ?? "Черновик сохраняется автоматически",systemImage:"checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength:4)
                    Text("\(studio.quiz.rounds.reduce(0) { $0 + $1.questions.count }) вопросов · \(studio.quiz.rounds.count) раундов").font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await studio.validateQuiz(); showEditorIssues = true }
                    } label: {
                        Label(issueCount == 0 ? "Проверить" : "Проблемы: \(issueCount)",systemImage:issueCount == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    }.font(.caption).foregroundStyle(issueCount == 0 ? Color.secondary : Color.orange).disabled(studio.checkingQuiz)
                }.padding(.horizontal,12).padding(.vertical,9)
            }
        }.sheet(isPresented:$showQuizTemplateSave) { QuizTemplateSaveView(store:studio.quizTemplates,quiz:studio.quiz,introductionSeconds:studio.introductionSeconds,phoneMode:studio.phoneMode,readBeforeTimer:studio.readBeforeTimer,automaticAdvance:studio.automaticAdvance,signalsEnabled:studio.signalsEnabled) }
        .sheet(isPresented:$showEditorIssues) { PreflightReport(studio:studio) }
        .onChange(of: studio.focusEditorSearch) { _, requested in
            if requested { questionSearchFocused = true; studio.focusEditorSearch = false }
        }
    }
}
struct QuizQuestionTable: View {
    @ObservedObject var studio: Studio
    var filter = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var batchSeconds = 30
    @State private var batchDifficulty = "Средний"
    @State private var showQuestionDetail = false
    @State private var showOnlyIssues = false
    struct Row: Identifiable { let id: UUID; let roundTitle: String; let question: Question }
    var rows: [Row] { studio.quiz.rounds.flatMap { round in round.questions.map { Row(id: $0.id, roundTitle: round.title, question: $0) } }.filter { (filter.isEmpty || $0.question.text.localizedCaseInsensitiveContains(filter) || $0.question.correctAnswer.localizedCaseInsensitiveContains(filter)) && (!showOnlyIssues || !$0.question.issues.isEmpty) } }
    private func updateSelectedQuestions(_ update: (inout Question) -> Void) {
        var quiz = studio.quiz
        for roundIndex in quiz.rounds.indices {
            for questionIndex in quiz.rounds[roundIndex].questions.indices where selectedIDs.contains(quiz.rounds[roundIndex].questions[questionIndex].id) {
                update(&quiz.rounds[roundIndex].questions[questionIndex])
            }
        }
        studio.quiz = quiz
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Вопросы квиза").font(.title2.bold()); Spacer()
                Toggle("Только с проблемами",isOn:$showOnlyIssues).toggleStyle(.checkbox)
                if selectedIDs.count == 1 {
                    Button("Редактировать всё…") { showQuestionDetail = true }
                    Button { moveSelected(by:-1) } label: { Image(systemName:"arrow.up") }.help("Переместить выше")
                    Button { moveSelected(by:1) } label: { Image(systemName:"arrow.down") }.help("Переместить ниже")
                }
                Text("\(rows.count) вопросов").foregroundStyle(.secondary)
            }
            if !selectedIDs.isEmpty {
                HStack(spacing:12) {
                    Text("Выбрано: \(selectedIDs.count)").font(.caption).foregroundStyle(.secondary)
                    Stepper("Время: \(batchSeconds) сек",value:$batchSeconds,in:0...600,step:5)
                    Button("Применить время") { updateSelectedQuestions { $0.seconds = batchSeconds } }
                    Picker("Сложность",selection:$batchDifficulty) { ForEach(["Не указана","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) } }.frame(width:130)
                    Button("Применить сложность") {
                        updateSelectedQuestions { $0.difficulty = batchDifficulty == "Не указана" ? nil : batchDifficulty }
                    }
                    Button("Снять выбор") { selectedIDs.removeAll() }.buttonStyle(.plain)
                }.buttonStyle(.bordered).padding(.vertical,4)
            }
            Table(rows, selection: Binding<Set<UUID>>(get: { selectedIDs }, set: { ids in
                selectedIDs = ids
                guard let id = ids.first, let r = studio.quiz.rounds.firstIndex(where: { $0.questions.contains(where: { $0.id == id }) }), let q = studio.quiz.rounds[r].questions.firstIndex(where: { $0.id == id }) else { return }
                studio.roundIndex = r; studio.questionIndex = q
            })) {
                TableColumn("Раунд", value: \.roundTitle).width(min: 100, ideal: 130)
                TableColumn("Вопрос") { row in TextField("Текст вопроса", text: studio.questionBinding(row.id).text).textFieldStyle(.plain).lineLimit(1) }.width(min: 220, ideal: 360)
                TableColumn("Проверка") { row in
                    Image(systemName:row.question.issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(row.question.issues.isEmpty ? Color.secondary : Color.orange)
                        .help(row.question.issues.isEmpty ? "Ошибок в вопросе не найдено" : row.question.issues.joined(separator:"\n"))
                }.width(min:70,ideal:85)
                TableColumn("Тип") { row in
                    Picker("Тип",selection:studio.questionBinding(row.id).kind) { ForEach(Question.kinds,id:\.self) { Text($0) } }.labelsHidden()
                }.width(min: 130, ideal: 170)
                TableColumn("Правильный ответ") { row in
                    if row.question.kind == "Сопоставление" || row.question.extraIssues != nil {
                        Text(row.question.correctAnswer).lineLimit(1)
                    } else {
                        TextField("Ответ",text:Binding(get:{ studio.questionBinding(row.id).wrappedValue.correctAnswer },set:{ value in
                            var question = studio.questionBinding(row.id).wrappedValue
                            question.answer = value
                            if question.kind == "Один из четырёх" { question.selectedChoice = question.choices.firstIndex(of:value) }
                            studio.questionBinding(row.id).wrappedValue = question
                        })).textFieldStyle(.plain).lineLimit(1)
                    }
                }.width(min: 160, ideal: 220)
                TableColumn("Сложность") { row in
                    Picker("Сложность",selection:Binding(get:{ studio.questionBinding(row.id).wrappedValue.difficulty ?? "Не указана" },set:{ studio.questionBinding(row.id).wrappedValue.difficulty = $0 == "Не указана" ? nil : $0 })) {
                        ForEach(["Не указана","Лёгкий","Средний","Сложный"],id:\.self) { Text($0) }
                    }.labelsHidden()
                }.width(min: 100, ideal: 130)
                TableColumn("Время") { row in Text(row.question.seconds == 0 ? "—" : "\(row.question.seconds) с") }.width(min: 60, ideal: 75)
            }
        }
        .sheet(isPresented:$showQuestionDetail) {
            if let question = studio.selectedQuestion {
                ScrollView { QuestionEditor(studio:studio,question:studio.questionBinding(question.id)).padding() }
                    .frame(minWidth:850,minHeight:650)
            }
        }
    }
    private func moveSelected(by offset: Int) {
        guard let id = selectedIDs.first,
              let roundIndex = studio.quiz.rounds.firstIndex(where: { $0.questions.contains(where: { $0.id == id }) }),
              let questionIndex = studio.quiz.rounds[roundIndex].questions.firstIndex(where: { $0.id == id }) else { return }
        let destination = questionIndex + offset
        guard studio.quiz.rounds[roundIndex].questions.indices.contains(destination) else { return }
        var quiz = studio.quiz
        quiz.rounds[roundIndex].questions.swapAt(questionIndex,destination)
        studio.quiz = quiz
        studio.roundIndex = roundIndex; studio.questionIndex = destination
    }
}
struct RoundSettings: View {
    @ObservedObject var studio: Studio
    @Binding var round: Round
    @State var editingIntro = false
    @State private var showTemplates = false
    @State private var showFlowSettings = false
    @State private var showDisplaySettings = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading,spacing: 12) {
                HStack { TextField("Название раунда",text: $round.title).font(.title3.bold()); Button("Шаблоны…") { showTemplates = true }; Button("Посмотреть раунд") { studio.editorPreview = .round } }
                DisclosureGroup("Заметки ведущего") { TextEditor(text: Binding(get: { round.hostNotes ?? "" },set: { round.hostNotes = $0 })).frame(height: 90); Text("На экран участников не выводятся.").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Таймеры новых вопросов и шаблон") {
                    Stepper("Вопрос: \(round.defaultSeconds) сек (0 — без отсчёта)",value:$round.defaultSeconds,in:0...3600,step:5)
                    Stepper("Ответ: \(round.defaultAnswerSeconds ?? 20) сек",value:Binding(get:{ round.defaultAnswerSeconds ?? 20 },set:{ round.defaultAnswerSeconds = $0 }),in:1...600)
                    Toggle("Таймер после медиа",isOn:$round.defaultAfterMedia)
                    Toggle("Медиа без видео",isOn:Binding(get:{ round.defaultAudioOnly ?? false },set:{ round.defaultAudioOnly = $0 }))
                    Text("Существующие вопросы меняются через шаблон или массовые настройки.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Показ и переходы", isExpanded: $showDisplaySettings) {
                    Toggle("Показать ответы после раунда",isOn: $round.showAnswers)
                    Toggle("Промежуточные итоги после раунда",isOn: $round.standings)
                    Toggle("Отключить фоновую музыку в этом раунде",isOn: Binding(get: { round.muteBackground ?? false },set: { round.muteBackground = $0 }))
                    PresentationBlocksEditor(studio:studio,round:$round)
                    HStack {
                        Button(round.intro == nil ? "Добавить вступление раунда" : "Редактировать вступление",systemImage: "info.bubble") {
                            if round.intro == nil { round.intro = RoundIntro() }; editingIntro = true
                        }
                        if round.intro != nil { Button("Убрать вступление",role: .destructive) { round.intro = nil } }
                    }
                }
                DisclosureGroup("Правила раунда", isExpanded: $showFlowSettings) {
                    Toggle("Дополнительный раунд при ничьей",isOn: Binding(get: { round.tieBreaker ?? false },set: { round.tieBreaker = $0 }))
                    if round.tieBreaker == true { Text("Ведущий запускает этот раунд вручную через меню перехода.").font(.caption).foregroundStyle(.secondary) }
                    HStack { Toggle("Повтор вопросов",isOn: $round.repeatQuestions); if round.repeatQuestions { Stepper("Каждые \(round.repeatSeconds) сек",value: $round.repeatSeconds,in: 1...300) } }
                    if round.repeatQuestions { Stepper("Заставка перед повтором: \(round.repeatIntroSeconds ?? 5) сек",value: Binding(get: { round.repeatIntroSeconds ?? 5 },set: { round.repeatIntroSeconds = $0 }),in: 2...30) }
                    Stepper("Сдача бланков: \(round.breakSeconds == 0 ? "вручную" : "\(round.breakSeconds) сек")",value: $round.breakSeconds,in: 0...600,step: 5)
                    if round.questions.isEmpty && studio.quiz.rounds.count > 1 { Button("Удалить пустой раунд",role: .destructive) { studio.deleteEmptyRound(round.id) } }
                }
            }.padding(8)
        } label: { Label("Настройки раунда",systemImage: "rectangle.stack") }
        .sheet(isPresented:$showTemplates) { RoundTemplatePicker(studio:studio,roundID:round.id) }
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
    @State private var showClipEditor = false
    @State private var editorStartsAnswer = false
    @State private var showYouTubeImport = false
    @State private var youtubeForAnswer = false
    @State private var youtubeImported = false
    @State private var imageEditorTarget: ImageEditorTarget?
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            if let notes = studio.quiz.importNotes {
                DisclosureGroup("Отчёт импорта .siq") { ScrollView { Text(notes).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(height:180) }
            }
            HStack { VStack(alignment: .leading, spacing: 3) { Text("Вопрос \(studio.questionIndex+1)").font(.title.bold()); Text("Раунд \(studio.roundIndex+1) · \(studio.quiz.rounds[studio.roundIndex].title)").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            HStack { Button("Посмотреть вопрос",systemImage:"play.rectangle") { preview.stop(); explanationPreview.stop(); studio.editorPreview = .question }; Button("Посмотреть ответ") { preview.stop(); explanationPreview.stop(); studio.editorPreview = .answer } }
            TextEditor(text: $question.text).font(.title3).frame(height: 100).padding(8).background(.background,in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            DisclosureGroup("Заметки ведущего к вопросу") { TextEditor(text: Binding(get: { question.hostNotes ?? "" },set: { question.hostNotes = $0 })).frame(height: 90); Text("Произношение, допустимые ответы и подсказки. Видны ведущему при отдельном экране участников.").font(.caption).foregroundStyle(.secondary) }
            if question.extraIssues != nil {
                ExtraQuestionFields(question:$question).id(question.kind)
            } else if question.kind == "Один из четырёх" {
                Text("Нажмите кружок рядом с правильным вариантом").font(.caption).foregroundStyle(.secondary)
                ForEach(question.choices.indices,id: \.self) { i in
                    HStack {
                        Button { question.selectedChoice = i; question.answer = question.choices[i] } label: {
                            Image(systemName: (question.selectedChoice == i || (question.selectedChoice == nil && !question.answer.isEmpty && question.answer == question.choices[i])) ? "checkmark.circle.fill" : "circle").foregroundStyle(.indigo).font(.title2)
                        }.buttonStyle(.plain).help("Выбрать правильный ответ")
                        TextField("\(i+1). Вариант ответа",text: $question.choices[i])
                        Button("Картинка") { studio.attachChoiceImage(i) }
                        if let images=question.choiceImages,images.indices.contains(i),images[i] != nil { Button("Убрать фото") { question.choiceImages?[i]=nil } }
                    }
                }
            } else if question.kind == "Сопоставление" {
                MatchingEditor(question: $question)
            } else {
                VStack(alignment:.leading,spacing:5) {
                    Text("Правильный ответ").font(.caption).foregroundStyle(.secondary)
                    TextField("Введите правильный ответ",text: $question.answer)
                    Text("Допустимые варианты").font(.caption).foregroundStyle(.secondary).padding(.top,3)
                    TextField("Несколько вариантов разделите точкой с запятой",text: Binding(get: { (question.acceptedAnswers ?? []).joined(separator: "; ") },set: { question.acceptedAnswers = $0.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }))
                }
            }
            Menu("Добавить медиа",systemImage:"paperclip") {
                Button("Картинку",systemImage:"photo") { studio.attach(image:true) }
                Button("Аудио / видео",systemImage:"film") { let old=question.media; studio.attach(image:false); if question.media != old { editorStartsAnswer=false; showClipEditor=true } }
                Button("С YouTube",systemImage:"link") { preview.stop(); explanationPreview.stop(); youtubeForAnswer=false; showYouTubeImport=true }
            }
            if !question.images(answer:false).isEmpty {
                SIQImageGallery(names:question.images(answer:false),studio:studio,masks:question.questionImageMasks ?? []).frame(height:240)
                if let name = question.image, name.lowercased().hasSuffix(".gif") == false {
                    Button("Закрыть фрагмент на фото…",systemImage:"rectangle.dashed") { imageEditorTarget = ImageEditorTarget(name:name,answer:false) }
                }
                Button("Убрать картинки") { question.image = nil; question.imageGallery = nil; question.questionImageMasks = nil }
            }
            if question.siqReviewRequired != nil {
                Toggle("Импортированное задание проверено",isOn:Binding(get:{ question.siqReviewRequired != true },set:{ question.siqReviewRequired = !$0 }))
            }
            if let attachments = question.siqAttachments, !attachments.isEmpty {
                DisclosureGroup("Медиа из пака .siq (\(attachments.count))") {
                    ForEach(attachments) { attachment in
                        HStack {
                            Text(attachment.originalName).font(.caption).lineLimit(1); Spacer()
                            if attachment.type != "image" {
                                Button("Для вопроса") { question.media = attachment.name; question.questionClip = nil; question.start = 0; question.end = 0; question.bleepRanges = ""; question.audioOnly = attachment.type == "audio"; editorStartsAnswer = false; showClipEditor = true }
                                Button("Для ответа") { question.explanationMedia = attachment.name; question.answerClip = nil; editorStartsAnswer = true; showClipEditor = true }
                            }
                        }
                    }
                }
            }
            if question.media != nil {
                GroupBox("Фрагмент аудио / видео") {
                    VStack(alignment: .leading,spacing: 12) {
                        Button("Открыть редактор аудио / видео",systemImage:"waveform") { preview.stop(); explanationPreview.stop(); editorStartsAnswer = false; showClipEditor = true }
                        Text("Вопрос: \(question.settings(answer:false).start,specifier:"%.2f") – \(question.settings(answer:false).end,specifier:"%.2f") с · Ответ: \(question.settings(answer:true).start,specifier:"%.2f") – \(question.settings(answer:true).end,specifier:"%.2f") с (0 — до конца)").font(.caption).foregroundStyle(.secondary)
                        Toggle("В вопросе — только звук",isOn: $question.audioOnly)
                        Picker("Запуск таймера",selection: $question.afterMedia) { Text("Вместе с фрагментом").tag(false); Text("После фрагмента").tag(true) }.pickerStyle(.segmented)
                        Toggle("Показывать видео при ответе",isOn: $question.answerVideo)
                        HStack { Button("Просмотреть фрагмент") {
                            guard let url = studio.asset(question.media) else { return }
                            explanationPreview.stop(); let c = question.settings(answer:false); preview.start(url:url,start:c.start,end:c.end,effects:c)
                        }; Button("Убрать медиа") { preview.stop(); question.media = nil; question.questionClip = nil } }
                        MediaPreview(session: preview)
                    }.padding(8)
                }
            }
            GroupBox("Объяснение ответа — по желанию") {
                VStack(alignment: .leading,spacing: 12) {
                    TextEditor(text: Binding(get: { question.explanation ?? "" },set: { question.explanation = $0 })).frame(height: 80)
                    HStack {
                        Menu("Добавить медиа",systemImage:"paperclip") {
                            Button("Картинку",systemImage:"photo") { studio.attach(image:true,explanation:true) }
                            Button("С YouTube",systemImage:"link") { preview.stop(); explanationPreview.stop(); youtubeForAnswer=true; showYouTubeImport=true }
                            Button("Аудио / видео",systemImage:"film") { let old=question.explanationMedia; studio.attach(image:false,explanation:true); if old != question.explanationMedia { editorStartsAnswer=true; showClipEditor=true } }
                        }
                    }
                    if question.explanationImage != nil || !(question.explanationGallery ?? []).isEmpty {
                        SIQImageGallery(names:[question.explanationImage].compactMap{$0}+(question.explanationGallery ?? []),studio:studio,masks:question.answerImageMasks ?? []).frame(height:200)
                        if let name = question.explanationImage, name.lowercased().hasSuffix(".gif") == false {
                            Button("Закрыть фрагмент на фото…",systemImage:"rectangle.dashed") { imageEditorTarget = ImageEditorTarget(name:name,answer:true) }
                        }
                        Button("Убрать картинки объяснения") { question.explanationImage = nil; question.explanationGallery = nil; question.answerImageMasks = nil }
                    }
                    if let url = studio.asset(question.explanationMedia) {
                        HStack {
                            Button("Предпросмотр объяснения") { preview.stop(); let c = question.settings(answer:true); explanationPreview.start(url:url,start:c.start,end:c.end,effects:c) }
                            Button("Редактировать фрагмент") { preview.stop(); explanationPreview.stop(); editorStartsAnswer = true; showClipEditor = true }
                            Button("Убрать медиа объяснения") { explanationPreview.stop(); question.explanationMedia = nil; question.answerClip = nil }
                        }
                        MediaPreview(session: explanationPreview)
                        Text("При показе ответа используется выбранный фрагмент этого файла вместо медиа вопроса.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            HStack { Stepper("Показ ответа: \(question.answerSeconds) сек",value: $question.answerSeconds,in: 5...600,step: 5); Button("Применить ко всем ответам раунда") { let seconds = question.answerSeconds; for i in studio.quiz.rounds[studio.roundIndex].questions.indices { studio.quiz.rounds[studio.roundIndex].questions[i].answerSeconds = seconds } } }
        }.textFieldStyle(.roundedBorder)
        .sheet(item:$imageEditorTarget) { target in
            if let url = studio.asset(target.name) {
                ImageMaskEditor(url:url,masks:Binding(get:{ target.answer ? (question.answerImageMasks ?? []) : (question.questionImageMasks ?? []) },set:{ value in if target.answer { question.answerImageMasks = value.isEmpty ? nil : value } else { question.questionImageMasks = value.isEmpty ? nil : value } }))
            }
        }
        .onAppear { if question.kind == "Один из четырёх" { question.choices = Array((question.choices+["","","",""]).prefix(4)) } }
        .onChange(of: question.kind) { _,kind in
            if kind == "Один из четырёх" { question.choices = Array((question.choices+["","","",""]).prefix(4)); if let i = question.selectedChoice, !question.choices.indices.contains(i) { question.selectedChoice = nil } }
            if kind == "Сопоставление" && question.matchPairs == nil { question.matchPairs = [MatchPair(),MatchPair()] }
            if kind == "Порядок событий" && question.sequenceItems == nil { question.sequenceItems = [SequenceItem(),SequenceItem()] }
            if kind == "Категоризация" && question.categoryGroups == nil { question.categoryGroups=["",""];question.categoryItems=[CategoryItem(),CategoryItem()] }
        }
        .sheet(isPresented:$showYouTubeImport,onDismiss:{
            if youtubeImported { youtubeImported = false; showClipEditor = true }
        }) {
            YouTubeImportView { url,_ in
                try studio.importDownloadedMedia(url,questionID:question.id,explanation:youtubeForAnswer)
                editorStartsAnswer = youtubeForAnswer; youtubeImported = true
            }
        }
        .sheet(isPresented:$showClipEditor) {
            if let url = studio.asset(question.media) ?? studio.asset(question.explanationMedia), let answerURL = studio.asset(question.explanationMedia) ?? studio.asset(question.media) {
                ClipEditor(question:$question,questionURL:url,answerURL:answerURL,initialAnswer:editorStartsAnswer)
            }
        }
        .onChange(of: question.id) { _,_ in preview.stop(); explanationPreview.stop() }
        .onDisappear { preview.stop(); explanationPreview.stop() }
    }
}
struct PlayerView: View {
    @ObservedObject var studio: Studio
    @State var controls = true
    @State var hideTask: Task<Void,Never>?
    var hostQuestion: Question? {
        guard studio.step?.kind == .question || studio.step?.kind == .repeated,
              studio.quiz.rounds.indices.contains(studio.roundIndex),
              studio.quiz.rounds[studio.roundIndex].questions.indices.contains(studio.questionIndex) else { return nil }
        return studio.quiz.rounds[studio.roundIndex].questions[studio.questionIndex]
    }
    var nextHostQuestion: Question? {
        guard let current = studio.steps.indices.first(where: { $0 > studio.index && studio.steps[$0].kind == .question }),
              studio.steps[current].round < studio.quiz.rounds.count,
              studio.steps[current].question < studio.quiz.rounds[studio.steps[current].round].questions.count else { return nil }
        return studio.quiz.rounds[studio.steps[current].round].questions[studio.steps[current].question]
    }
    var body: some View {
        VStack(spacing: 0) {
            if studio.step?.kind == .standings && !studio.publishedScores {
                if studio.audienceScreenReady || studio.showScoreInputLocally { ScoreEditor(studio: studio) } else { StandingsBreakHost(studio: studio) }
            } else { Stage(studio: studio,audience: false) }
            if studio.audienceScreenReady { HostNotes(studio: studio) }
            if hostQuestion != nil {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading,spacing:6) {
                        let total = studio.quiz.rounds.reduce(0) { $0 + $1.questions.count }
                        let number = studio.quiz.rounds.prefix(studio.roundIndex).reduce(0) { $0 + $1.questions.count } + studio.questionIndex + 1
                        Label("Вопрос \(number) / \(total)",systemImage:"number").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if studio.phoneMode { Label("\(studio.phoneRoom.joinedTeams.count) подключено",systemImage:"iphone").font(.caption).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ПРАВИЛЬНЫЙ ОТВЕТ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(hostQuestion?.correctAnswer.isEmpty == false ? hostQuestion!.correctAnswer : "Не указан").font(.headline)
                    }
                    if let notes = hostQuestion?.hostNotes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) { Text("ЗАМЕТКИ ВЕДУЩЕГО").font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(notes).font(.callout).lineLimit(3) }
                    }
                    Spacer(minLength: 8)
                    if let nextHostQuestion { VStack(alignment: .leading, spacing: 4) { Text("ДАЛЬШЕ").font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(nextHostQuestion.text).font(.callout).lineLimit(2).frame(maxWidth: 220, alignment: .leading) } }
                }.padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
        .overlay(alignment: .top) {
            if let step = studio.step, step.kind != .finish {
                HStack(spacing: 12) {
                    Label(studio.stepTitle(studio.index),systemImage:"sparkles.tv")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 12)
                    if step.showsTimer {
                        Text(studio.awaitingQuestionStart ? "Ожидает запуска" : studio.paused ? "Пауза" : (studio.waitingForMedia ? "Воспроизведение" : "Эфир"))
                            .font(.caption.weight(.medium)).foregroundStyle(studio.paused ? .orange : .secondary)
                        Text(studio.awaitingQuestionStart ? "—:—" : "\(studio.remaining / 60):\(String(format: "%02d",studio.remaining % 60))")
                            .font(.system(.title3,design:.monospaced).weight(.bold))
                            .foregroundStyle(studio.remaining <= 10 && !studio.paused && !studio.awaitingQuestionStart ? .orange : .primary)
                    }
                    if studio.phoneMode {
                        Label("\(studio.phoneRoom.joinedTeams.count) команд",systemImage:"iphone")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal,18).padding(.vertical,10)
                .background(.regularMaterial,in:Capsule())
                .padding(.top,14).padding(.horizontal,24)
            }
        }
        .overlay(alignment: .bottom) {
            if studio.step?.kind == .finish {
                HStack(spacing: 12) {
                    Button("Завершить игру") { studio.returnToMenu() }
                    Button("Архив и статистика") { studio.persistArchive(); studio.showGameArchive = true }.buttonStyle(.borderedProminent)
                    if studio.phoneMode { Button("Проверить ответы") { studio.showPhoneReview = true } }
                    Button("Перейти к этапу…") { studio.showJump = true }
                }.controlSize(.large).padding(28)
            } else if controls || studio.paused || studio.awaitingQuestionStart {
                HStack(spacing: 10) {
                    Button("Назад") { studio.back() }
                    Button(studio.awaitingQuestionStart ? "Запустить таймер" : (studio.paused ? "Продолжить" : "Пауза")) { studio.togglePause() }.buttonStyle(.borderedProminent)
                    Button(studio.step?.kind == .question || studio.step?.kind == .repeated ? "Ответ" : "Далее") { studio.next() }.buttonStyle(.borderedProminent)
                    if studio.phoneMode { Button("Ответы \(studio.phoneRoom.pending(through: studio.roundIndex).count)") { studio.showPhoneReview = true }.disabled(!studio.audienceScreenReady && !studio.showScoreInputLocally) }
                    BackgroundMusicControls(music: studio.background)
                    Button("Завершить квиз…",role:.destructive) { studio.confirmExit() }
                    Menu {
                        Section("Пульт презентаций") {
                            Label("Вопрос вперёд: → или Page Down", systemImage: "arrow.right")
                            Label("Пауза: пробел, Enter или Play/Pause", systemImage: "pause")
                            Label("Назад: ← или Page Up", systemImage: "arrow.left")
                        }
                        Button("Перейти к этапу…") { studio.showJump = true }
                        Button("Заново начать этап") { studio.enter() }
                        Button("Экран ТВ") { studio.showTV() }
                        Button("На весь экран") { NSApp.keyWindow?.toggleFullScreen(nil) }
                        if studio.step?.kind == .standings && studio.publishedScores && !studio.scoresFullyRevealed { Button("Показать все места") { studio.revealAllScores() } }
                    } label: { Image(systemName:"ellipsis").frame(width: 28,height: 28).contentShape(Rectangle()) }.help("Ещё")
                }.buttonStyle(.bordered).padding().background(.regularMaterial,in: Capsule()).padding(20)
            }
        }.sheet(isPresented: $studio.showJump) { JumpMenu(studio: studio) }
        .sheet(isPresented: $studio.showPhoneReview) { PhoneAnswerReview(studio: studio,room: studio.phoneRoom) }
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
                        case .block:
                            if let bi=s.block,(studio.quiz.rounds[s.round].blocks ?? []).indices.contains(bi) {
                                let block=studio.quiz.rounds[s.round].blocks![bi]
                                Text(block.kind.uppercased()).font(studio.stageFont(size:20,weight:.semibold)).foregroundStyle(.orange)
                                Text(block.kind == "Случайная команда" ? selectedRandomTeam(block,teams:studio.quiz.teams) : block.title).font(studio.stageFont(size:52,weight:.bold)).multilineTextAlignment(.center)
                                Text(block.text).font(studio.stageFont(size:28)).multilineTextAlignment(.center)
                                if studio.phoneMode,["Голосование","Выбор темы"].contains(block.kind) { VStack(alignment:.leading,spacing:10) { ForEach(block.options ?? [],id:\.self) { option in let count=studio.phoneRoom.blockResponses[block.id]?.values.filter{$0==option}.count ?? 0;HStack { Text(option);Spacer();Text("\(count)").bold() }.font(studio.stageFont(size:24)).padding(10).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:10)) } } }
                                if studio.phoneMode,block.kind == "Облако слов" { Text((studio.phoneRoom.blockResponses[block.id]?.values ?? [:].values).joined(separator:"   ·   ")).font(studio.stageFont(size:30,weight:.semibold)).multilineTextAlignment(.center).foregroundStyle(.orange) }
                                if let url=studio.asset(block.image) { QuizImage(url:url).frame(height:geometry.size.height*0.38) }
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
                                if s.kind == .question { Text(q.scoringSummary).font(studio.stageFont(size:18)).foregroundStyle(q.wagerEnabled == true ? .orange:.white.opacity(0.55)) }
                                if s.kind == .answer || s.kind == .answerPrompt {
                                    Group {
                                        if s.kind == .answer && !["Порядок событий","Категоризация"].contains(q.kind) && !(q.kind == "Сопоставление" && q.matchPairs != nil) {
                                            Text(q.correctAnswer).font(studio.stageFont(size: 38,weight: .bold)).foregroundStyle(.green).multilineTextAlignment(.center)
                                        } else if s.kind == .answerPrompt { Text(" ").font(studio.stageFont(size: 38,weight: .bold)) }
                                    }.frame(maxWidth: .infinity,minHeight: 70).padding(12).background(.white.opacity(s.kind == .answer ? 0.07 : 0),in: RoundedRectangle(cornerRadius: 12))
                                }
                                if q.kind == "Сопоставление", let pairs = q.matchPairs {
                                    MatchingBoard(pairs: pairs,layout: studio.matchLayouts[q.id] ?? MatchLayout(left: pairs.map(\.id),right: pairs.map(\.id)),reveal: s.kind == .answer,font: studio.stageFont(size: 24))
                                }
                                if q.kind == "Порядок событий" { VStack(alignment:.leading,spacing:6) { ForEach(Array((s.kind == .answer ? q.sequenceItems ?? [] : q.displayedSequence).enumerated()),id:\.element.id) { i,item in Text("\(s.kind == .answer ? String(i+1) : MatchLayout.letter(i)). \(item.text)").font(studio.stageFont(size:min(24,CGFloat(220/max(2,q.sequenceItems?.count ?? 2))))).foregroundStyle(s.kind == .answer ? .green : .white).lineLimit(2).minimumScaleFactor(0.7) } } }
                                if q.kind == "Категоризация" {
                                    if s.kind == .answer { HStack(alignment:.top,spacing:14) { ForEach((q.categoryGroups ?? []).indices,id:\.self) { group in VStack { Text(q.categoryGroups![group]).bold().foregroundStyle(.green);ForEach((q.categoryItems ?? []).filter{$0.category==group}) { Text($0.text).font(studio.stageFont(size:20)) } }.padding().frame(maxWidth:.infinity).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:12)) } } }
                                    else { VStack(alignment:.leading) { ForEach(Array(q.displayedCategoryItems.enumerated()),id:\.element.id) { i,item in Text("\(MatchLayout.letter(i)). \(item.text)").font(studio.stageFont(size:22)) };Text("Категории: \((q.categoryGroups ?? []).joined(separator:" · "))").foregroundStyle(.orange) } }
                                }
                                if s.kind == .answer,q.kind == "Один из четырёх",let choice=q.selectedChoice,let images=q.choiceImages,images.indices.contains(choice),let name=images[choice],let url=studio.asset(name) { QuizImage(url:url).frame(height:geometry.size.height*0.28) }
                                if s.kind == .answer, let explanation = q.explanation, !explanation.isEmpty { Text(explanation).font(studio.stageFont(size: 24)).multilineTextAlignment(.center) }
                                if s.kind != .answer && q.isChoiceQuestion { LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())],spacing: 12) { ForEach(q.choices.indices,id: \.self) { i in VStack { if let images=q.choiceImages,images.indices.contains(i),let name=images[i],let url=studio.asset(name) { QuizImage(url:url).frame(height:120) };Text("\(i+1). \(q.choices[i])").font(studio.stageFont(size: 24)).frame(maxWidth:.infinity,alignment:.leading) }.padding().frame(maxWidth: .infinity).background(.white.opacity(0.08),in: RoundedRectangle(cornerRadius: 12)) } } }
                                if let p = studio.player {
                                    if studio.playback.hasVideo && q.showsVideo(answer:s.kind == .answer) { NativeMediaView(player: p,controls: false).frame(height: geometry.size.height*0.38) }
                                    else { Label("Аудиофрагмент",systemImage: "waveform").font(studio.stageFont(size: 28)).padding(30) }
                                }
                                if !q.images(answer:s.kind == .answer).isEmpty { SIQImageGallery(names:q.images(answer:s.kind == .answer),studio:studio,masks:s.kind == .answer ? (q.answerImageMasks ?? []) : (q.questionImageMasks ?? [])).frame(height:geometry.size.height*(studio.player == nil ? 0.4 : 0.2)) }
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
                            ForEach(studio.quiz.rounds) { r in
                                if studio.phoneMode { Text(scoreText(team.scores[r.id.uuidString] ?? 0)).frame(width:100) }
                                else { ScoreField(value: Binding(get: { team.scores[r.id.uuidString] ?? 0 },set: { team.scores[r.id.uuidString] = $0 })).frame(width: 100) }
                            }
                            Text(scoreText(team.total)).frame(width: 70)
                        }
                    }
                }.textFieldStyle(.roundedBorder)
            }
            Text("Можно вводить дробные баллы через точку или запятую и отрицательные значения для штрафов. При равной сумме команды получают одинаковое место.").font(.caption).foregroundStyle(.secondary)
            if studio.phoneMode { Button("Проверить ответы команд") { studio.showPhoneReview = true }; Text("Баллы считаются по отправленным ответам. Свободные ответы с опечатками подтверждает ведущий; сопоставление: все пары верны — 1, иначе 0.").font(.caption) }
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
    @State private var showQuickCreate = false
    var body: some View {
        GeometryReader { geometry in
        let compact = geometry.size.height < 650
        ScrollView(.vertical) {
        VStack(spacing: compact ? 12 : 18) {
            HStack(alignment:.center,spacing:12) {
                VStack(alignment:.leading,spacing:4) {
                    Text("Квиз Студия").font(.system(size: compact ? 28 : 34,weight:.bold))
                    Text("Создайте игру или проведите готовый квиз").font(compact ? .callout : .title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Архив",systemImage:"chart.bar.doc.horizontal") { studio.showGameArchive = true }.buttonStyle(.bordered)
            }
            if studio.recoveryAvailable { Button("Восстановить незавершённую игру") { studio.restoreGame() }.buttonStyle(.borderedProminent) }
            Button("Продолжить черновик",systemImage:"pencil") { studio.screen = .editor }.buttonStyle(.link).frame(maxWidth:.infinity,alignment:.leading)
            LazyVGrid(columns: [GridItem(.flexible(),spacing: 12),GridItem(.flexible(),spacing: 12)],spacing: 12) {
                Button { showQuickCreate = true } label: { entry("Создать квиз","Начните с первого вопроса, затем настройте игру","square.and.pencil") }
                Button { studio.showLibrary(editing:true) } label: { entry("Мои квизы","Открывайте, сортируйте и редактируйте проекты","rectangle.stack") }
                Button { studio.showLibrary(editing: false) } label: { entry("Провести игру","Выберите квиз и подготовьте команды","play.rectangle") }
                Button { studio.showQuestionBank = true } label: { entry("Банк вопросов","Ищите, импортируйте и собирайте вопросы","tray.full") }
            }.buttonStyle(.plain).frame(maxWidth: 740)
            if !studio.status.isEmpty { Text(studio.status).foregroundStyle(.secondary).font(.caption).lineLimit(2) }
        }.padding(.horizontal,compact ? 22 : 40).padding(.vertical,compact ? 14 : 26).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height,alignment:.center)
        }
        }.background(Color.indigo.opacity(0.04))
            .sheet(isPresented:$showQuickCreate) { QuickQuizStartView(studio:studio) }
    }
    func entry(_ title: String,_ subtitle: String,_ icon: String) -> some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.indigo).frame(width:26)
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.headline)
                Text(subtitle).foregroundStyle(.secondary).font(.caption).lineLimit(2)
            }
            Spacer(minLength:0)
        }.padding(16).frame(maxWidth: .infinity,minHeight: 78,alignment: .leading).background(.background,in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}
struct QuickQuizStartView: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Новый квиз"
    @State private var questions = [QuickQuizDraft()]
    var canCreate: Bool { !questions.isEmpty && questions.allSatisfy { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !$0.answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            VStack(alignment:.leading,spacing:5) {
                Text("Соберите короткий квиз").font(.title2.bold())
                Text("Добавьте вопросы и ответы. Раунды и оформление можно настроить позже.").foregroundStyle(.secondary)
            }
            TextField("Название квиза",text:$title)
            ScrollView {
                VStack(spacing:10) {
                    ForEach($questions) { $question in
                        GroupBox {
                            VStack(alignment:.leading,spacing:8) {
                                TextEditor(text:$question.text).frame(height:72).overlay(RoundedRectangle(cornerRadius:7).stroke(.quaternary))
                                TextField("Правильный ответ",text:$question.answer)
                                if questions.count > 1 { Button("Удалить вопрос",systemImage:"minus.circle",role:.destructive) { let id=question.id; questions.removeAll { $0.id == id } }.font(.caption) }
                            }
                        } label: { Text("Вопрос \(questions.firstIndex(where:{$0.id == question.id}).map{$0+1} ?? 1)").font(.headline) }
                    }
                    Button("Добавить вопрос",systemImage:"plus.circle") { questions.append(QuickQuizDraft()) }
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.top,4)
                }
            }
            .frame(maxHeight:360)
            HStack {
                Button("Пустой квиз") { studio.newQuiz(); dismiss() }
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Создать и открыть редактор") {
                    studio.newQuiz()
                    studio.quiz.title = title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "Новый квиз" : title.trimmingCharacters(in:.whitespacesAndNewlines)
                    studio.quiz.rounds[0].questions = questions.map { Question(text:$0.text.trimmingCharacters(in:.whitespacesAndNewlines),answer:$0.answer.trimmingCharacters(in:.whitespacesAndNewlines)) }
                    studio.roundIndex = 0; studio.questionIndex = 0
                    studio.status = "Первый вопрос добавлен — продолжите в редакторе"
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(!canCreate)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:560,height:620)
    }
}
private struct QuickQuizDraft: Identifiable {
    var id = UUID()
    var text = ""
    var answer = ""
}
struct QuizLibrary: View {
    @ObservedObject var studio: Studio
    var editing = false
    @State var search = ""
    @State private var newestFirst = true
    @State private var showQuizTemplates = false
    @State private var selectedFolder = ""
    @State private var selectedTag = ""
    @State private var metadataURL: URL?
    @State private var showMetadata = false
    @State private var summaries: [String: QuizLibrarySummary] = [:]
    @State private var summariesLoaded = false
    @FocusState private var librarySearchFocused: Bool
    var folders: [String] { Array(Set(studio.libraryFolders.values)).sorted() }
    var tags: [String] { Array(Set(studio.libraryTags.values.flatMap { $0 })).sorted() }
    var visibleQuizzes: [URL] {
        studio.recentQuizzes.filter { url in
            let key = url.standardizedFileURL.path
            let quizTags = studio.libraryTags[key] ?? []
            let matchesSearch = search.isEmpty || url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(search) || quizTags.contains { $0.localizedCaseInsensitiveContains(search) }
            let matchesFolder = selectedFolder.isEmpty || studio.libraryFolders[key] == selectedFolder
            let matchesTag = selectedTag.isEmpty || quizTags.contains(selectedTag)
            return matchesSearch && matchesFolder && matchesTag
        }.sorted { a,b in
            if newestFirst {
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if ad != bd { return ad > bd }
            }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack {
                Button("Главная") { studio.screen = .home }
                Spacer()
                if editing { Button("Из шаблона…") { showQuizTemplates = true } }
                Button("Открыть квиз на Mac…") { studio.open(forPlay: !editing) }
                if editing { Button("Создать с нуля",systemImage: "plus") { studio.newQuiz() }.buttonStyle(.borderedProminent) }
            }
            Text(editing ? "Мои квизы" : "Провести игру").font(.largeTitle.bold())
            Text(editing ? "Откройте сохранённый квиз для правок или начните новый с нуля." : "Выберите квиз для проведения. Его также можно открыть для редактирования.").foregroundStyle(.secondary)
            HStack {
                TextField("Найти квиз по названию",text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 420).focused($librarySearchFocused)
                Picker("Порядок",selection: $newestFirst) { Text("По дате изменения").tag(true); Text("По названию").tag(false) }.frame(width: 240)
                Picker("Папка", selection: $selectedFolder) {
                    Text("Все папки").tag("")
                    ForEach(folders,id:\.self) { Text($0).tag($0) }
                }.frame(width: 150)
                Picker("Тег", selection: $selectedTag) {
                    Text("Все теги").tag("")
                    ForEach(tags,id:\.self) { Text($0).tag($0) }
                }.frame(width: 130)
                Spacer()
                Text("\(visibleQuizzes.count) квизов").font(.caption).foregroundStyle(.secondary)
            }
            if studio.recentQuizzes.isEmpty {
                ContentUnavailableView("Пока нет сохранённых квизов",systemImage: "rectangle.stack",description: Text(editing ? "Создайте квиз с нуля или откройте файл на Mac." : "Нажмите «Открыть квиз на Mac…» и укажите файл .quiz"))
            } else if visibleQuizzes.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 285),spacing: 14)],spacing: 14) {
                        ForEach(visibleQuizzes,id: \.path) { url in
                            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0),countStyle: .file) } ?? "Квиз"
                            VStack(alignment: .leading,spacing: 14) {
                                HStack(alignment: .top,spacing: 12) {
                                    Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.indigo).frame(width: 42,height: 42).background(.indigo.opacity(0.1),in: RoundedRectangle(cornerRadius: 11))
                                    VStack(alignment: .leading,spacing: 4) {
                                        Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(2)
                                        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                                            Text("Изменён " + date.formatted(date: .abbreviated,time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Menu {
                                        Button("Создать копию…",systemImage:"doc.on.doc") { studio.duplicateQuiz(url) }
                                        Button("Экспортировать…",systemImage:"square.and.arrow.up") { studio.exportQuiz(url) }
                                        Button("Показать в Finder",systemImage:"folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                        Button("Папка и теги…",systemImage:"tag") { metadataURL = url; showMetadata = true }
                                        Divider()
                                        Button("Убрать из списка",systemImage:"xmark.circle",role:.destructive) { studio.removeFromLibrary(url) }
                                        Button("Удалить файл с Mac…",systemImage:"trash",role:.destructive) { studio.deleteQuizFile(url) }
                                    } label: { Image(systemName:"ellipsis").padding(6).contentShape(Rectangle()) }.menuStyle(.borderlessButton)
                                }
                                Text("\(size) · \(url.pathExtension.uppercased())")
                                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                let summary = summaries[url.standardizedFileURL.path]
                                if let summary {
                                    Label("\(summary.questions) вопросов · \(summary.rounds) раундов",systemImage:"list.number").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Label(summariesLoaded ? "Сводка недоступна" : "Сводка загружается…",systemImage:summariesLoaded ? "exclamationmark.circle" : "list.number").font(.caption).foregroundStyle(.secondary)
                                }
                                let urlTags = studio.libraryTags[url.standardizedFileURL.path] ?? []
                                let folder = studio.libraryFolders[url.standardizedFileURL.path]
                                if folder != nil || !urlTags.isEmpty {
                                    HStack(spacing:6) {
                                        if let folder { Label(folder,systemImage:"folder").font(.caption2).padding(.horizontal,7).padding(.vertical,4).background(.quaternary,in:Capsule()) }
                                        ForEach(urlTags,id:\.self) { tag in Text(tag).font(.caption2).padding(.horizontal,7).padding(.vertical,4).background(.indigo.opacity(0.1),in:Capsule()) }
                                    }.lineLimit(1)
                                }
                                HStack {
                                    Button("Редактировать",systemImage:"square.and.pencil") { studio.editQuiz(url) }
                                    Spacer()
                                    if !editing { Button("Начать",systemImage:"play.fill") { if studio.load(url) { studio.prepareGame() } }.buttonStyle(.borderedProminent) }
                                }
                            }
                            .padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(.quaternary))
                            .contextMenu {
                                Button("Создать копию…") { studio.duplicateQuiz(url) }
                                Button("Экспортировать…") { studio.exportQuiz(url) }
                                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Папка и теги…") { metadataURL = url; showMetadata = true }
                                Button("Убрать из списка",role:.destructive) { studio.removeFromLibrary(url) }
                                Button("Удалить файл с Mac…",role:.destructive) { studio.deleteQuizFile(url) }
                            }
                        }
                    }.padding(.vertical,4)
                }
            }
            Text(studio.status).foregroundStyle(.secondary)
            Text("Удаление из списка не удаляет файл. Чтобы вернуть квиз, откройте его на Mac заново.").font(.caption).foregroundStyle(.secondary)
        }.padding(28)
        .sheet(isPresented:$showQuizTemplates) { QuizTemplatePicker(studio:studio) }
        .sheet(isPresented:$showMetadata) {
            if let metadataURL {
                QuizLibraryMetadataEditor(url:metadataURL, folder:studio.libraryFolders[metadataURL.standardizedFileURL.path] ?? "", tags:(studio.libraryTags[metadataURL.standardizedFileURL.path] ?? []).joined(separator:", ")) { folder,tags in
                    studio.setLibraryMetadata(for:metadataURL,folder:folder,tags:tags)
                }
            }
        }
        .task(id: studio.recentQuizzes.map(\.path).joined(separator:"\n")) {
            let urls = studio.recentQuizzes
            let loaded = await Task.detached(priority:.utility) {
                var result: [String:QuizLibrarySummary] = [:]
                for url in urls {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory) else { continue }
                    let source = isDirectory.boolValue ? url.appendingPathComponent("quiz.json") : url
                    guard let data = try? Data(contentsOf:source) else { continue }
                    let quiz: Quiz?
                    if isDirectory.boolValue { quiz = try? JSONDecoder().decode(Quiz.self,from:data) }
                    else { quiz = try? JSONDecoder().decode(QuizLibraryContainer.self,from:data).quiz }
                    if let quiz {
                        result[url.standardizedFileURL.path] = QuizLibrarySummary(rounds:quiz.rounds.count,questions:quiz.rounds.reduce(0) { $0 + $1.questions.count })
                    }
                }
                return result
            }.value
            summaries = loaded
            summariesLoaded = true
        }
        .onChange(of: studio.focusLibrarySearch) { _, requested in
            if requested { librarySearchFocused = true; studio.focusLibrarySearch = false }
        }
    }
}
private struct QuizLibraryContainer: Decodable { let quiz: Quiz }
private struct QuizLibrarySummary: Sendable { let rounds: Int; let questions: Int }
struct QuizLibraryMetadataEditor: View {
    let url: URL
    @State var folder: String
    @State var tags: String
    let save: (String,String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Папка и теги").font(.title2.bold())
            Text(url.deletingPathExtension().lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            TextField("Папка, например «Музыка»",text:$folder)
            TextField("Теги через запятую",text:$tags)
            HStack { Spacer(); Button("Отмена") { dismiss() }; Button("Сохранить") { save(folder,tags); dismiss() }.buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder).padding(22).frame(width:420)
    }
}
struct TeamSetup: View {
    @ObservedObject var studio: Studio
    @State private var musicSettings = false
    @State private var deviceSettings = false
    @State private var showGameOptions = false
    @State private var preflightComplete = false
    @State private var preflightPassed = false
    var validTeamCount: Int { studio.quiz.teams.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }
    var body: some View {
        ScrollView { VStack(alignment: .leading,spacing: 20) {
            HStack { Button("Назад") { studio.screen = .library }; Spacer(); Button("Открыть редактор") { studio.screen = .editor } }
            VStack(alignment: .leading,spacing: 5) {
                Text("Подготовка к игре").font(.largeTitle.bold())
                Text(studio.quiz.title).font(.title2).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading,spacing: 10) {
                    Text("Как команды будут отвечать?").font(.headline)
                    Picker("Формат игры",selection: $studio.phoneMode) { Text("Бумажные бланки").tag(false); Text("Телефоны").tag(true) }.pickerStyle(.segmented)
                    Text(studio.phoneMode ? "Команды подключатся по QR-коду и отправят ответы со своих телефонов." : "Добавьте команды и внесите их баллы после каждого раунда.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if studio.phoneMode { PhoneLobby(studio: studio,room: studio.phoneRoom) }
            if !studio.phoneMode {
            GroupBox {
            VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Команды").font(.headline); Spacer(); Button("Добавить",systemImage:"plus") { studio.quiz.teams.append(Team(name: "")) } }
            if studio.quiz.teams.isEmpty { ContentUnavailableView("Команды ещё не добавлены",systemImage:"person.3",description:Text("Добавьте названия команд, чтобы начать игру.")).frame(minHeight:100) }
            else { List {
                ForEach($studio.quiz.teams) { $team in
                    HStack {
                        Image(systemName: "person.3.fill").foregroundStyle(.indigo)
                        TextField("Название команды",text: $team.name).textFieldStyle(.roundedBorder)
                        if team.total != 0 { Text(scoreText(team.total) + " баллов").foregroundStyle(.secondary) }
                        Button(role: .destructive) { studio.quiz.teams.removeAll { $0.id == team.id } } label: { Image(systemName:"trash") }.buttonStyle(.borderless).help("Удалить команду")
                    }.padding(6)
                }
            }
            .frame(minHeight:130,maxHeight:220) }
            DisclosureGroup("Сохранённые команды") {
                    HStack { Button("Сохранить команды из этой игры") { studio.teamRoster.add(studio.quiz.teams.map(\.name)) }; Text("Хранятся на этом Mac и доступны в других квизах.").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:180))],spacing:8) {
                        ForEach(studio.teamRoster.teams,id:\.self) { name in
                            HStack { Button(name) { if !studio.quiz.teams.contains(where:{ $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { studio.quiz.teams.append(Team(name:name)) } }; Spacer(); Button { studio.teamRoster.remove(name) } label:{ Image(systemName:"xmark.circle") }.buttonStyle(.plain) }
                                .padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }
            }
            }
            }
            GroupBox("Сценарий ведущего") {
                VStack(alignment: .leading,spacing: 12) {
                    Picker("Переключение экранов",selection: $studio.automaticAdvance) { Text("Автоматически").tag(true); Text("Вручную").tag(false) }.pickerStyle(.segmented)
                    Text(studio.automaticAdvance ? "По таймеру игра переходит дальше сама. Итоги и экраны без таймера переключает ведущий." : "После таймера экран ждёт команды ведущего.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Сначала прочитать вопрос, потом запустить таймер",isOn: $studio.readBeforeTimer)
                    if !studio.phoneMode { Stepper("Представление команды: \(studio.introductionSeconds) сек",value: $studio.introductionSeconds,in: 3...30) }
                }
            }
            DisclosureGroup("Дополнительные настройки",isExpanded:$showGameOptions) {
                BackgroundMusicSetup(music: studio.background,showSettings: $musicSettings)
                Toggle("Обнулить прошлые баллы перед игрой",isOn: $studio.resetScores)
                Text("Если выключено, сохранённые баллы команд останутся.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Проверить квиз") { studio.showPreflight = true; Task { await studio.validateQuiz() } }; Button("Экран и звук…") { deviceSettings = true }; if !studio.phoneMode { Button("Печатные бланки…") { studio.printSheets() } } }
            }
            GroupBox {
                VStack(alignment: .leading,spacing: 10) {
                    Text("Готовность к игре").font(.headline)
                    readinessRow("Формат",detail:studio.phoneMode ? "Ответы с телефонов" : "Бумажные бланки",ready:true)
                    readinessRow("Команды",detail:studio.phoneMode ? (studio.phoneRoom.running ? "Подключено: \(studio.phoneRoom.joinedTeams.count)" : "Комната не запущена") : "Добавлено: \(validTeamCount)",ready:studio.phoneMode ? (studio.phoneRoom.running && !studio.phoneRoom.joinedTeams.isEmpty) : validTeamCount > 0)
                    readinessRow("Квиз",detail:preflightComplete ? (preflightPassed ? "Проверка пройдена" : "Найдены замечания") : "Будет проверен перед запуском",ready:preflightComplete && preflightPassed)
                    if studio.checkingQuiz { ProgressView("Проверяем квиз…") }
                    else if !studio.status.isEmpty { Text(studio.status).font(.caption).foregroundStyle(.secondary) }
                    HStack { Spacer(); Button("Проверить и начать игру",systemImage: "play.fill") { studio.beginCheckedGame() }.buttonStyle(.borderedProminent).disabled((!studio.phoneMode && studio.quiz.teams.isEmpty) || studio.checkingQuiz || (studio.phoneMode && (!studio.phoneRoom.running || studio.phoneRoom.joinedTeams.isEmpty))) }
                }
            }
        }.padding(36) }
        .onChange(of: studio.phoneMode) { _,enabled in if !enabled { studio.phoneRoom.stop(); studio.tv?.close(); studio.tv = nil } }
        .sheet(isPresented: $deviceSettings) { DeviceSettings(studio: studio) }
        .sheet(isPresented: $studio.showPreflight) { PreflightReport(studio: studio) }
        .task { await refreshPreflight() }
        .onChange(of: studio.quiz) { _,_ in preflightComplete = false }
    }
    func readinessRow(_ title: String,detail: String,ready: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ready ? .green : .secondary)
            Text(title).fontWeight(.medium)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }.font(.subheadline)
    }
    @MainActor func refreshPreflight() async {
        await studio.validateQuiz()
        preflightComplete = true
        preflightPassed = studio.preflightIssues.isEmpty
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
        } label: { Label("Музыка",systemImage: !music.enabled || music.muted ? "speaker.slash" : "music.note").contentShape(Rectangle()) }
            .help("Управление фоновой музыкой")
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

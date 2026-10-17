struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct Checks {
 @MainActor static func tryData(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
 @MainActor static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let app = Studio(draftURL: root.appendingPathComponent("draft.quiz"))
  app.timer?.invalidate()
  app.quiz.rounds[0].questions[0].text = "Вопрос"
  app.quiz.rounds[0].questions[0].answer = "Ответ"
  app.quiz.rounds[0].questions[0].seconds = 5
  app.applyTime(); app.addQuestion()
  assert(app.quiz.rounds[0].questions[1].seconds == 5)
  app.quiz.rounds[0].questions[1].text = "Второй вопрос"; app.quiz.rounds[0].questions[1].answer = "Второй ответ"
  app.quiz.rounds[0].repeatQuestions = true
  app.quiz.rounds[0].standings = true
  app.start()
  assert(app.steps.map(\.kind) == [.question,.question,.repeated,.repeated,.pause,.answerPrompt,.answer,.answerPrompt,.answer,.standings,.finish])
  app.paused = true; app.tick(); assert(app.remaining == 5)
  app.paused = false
  for _ in 0..<38 { app.tick() }
  assert(app.index == 1)
  app.back(); assert(app.index == 0 && app.remaining == 5)
  app.quiz.rounds[0].questions[0].seconds = 0; app.start()
  for _ in 0..<100 { app.tick() }; assert(app.index == 0)
  let dest = root.appendingPathComponent("portable.quiz")
  try app.write(to: dest)
  let restored = Studio(draftURL: dest); restored.timer?.invalidate()
  assert(restored.quiz == app.quiz)
  let mediaRoot = root.appendingPathComponent("media.quiz")
  try FileManager.default.createDirectory(at: mediaRoot.appendingPathComponent("Media"),withIntermediateDirectories: true)
  try Data([1,2,3]).write(to: mediaRoot.appendingPathComponent("Media/test.dat"))
  app.folder = mediaRoot; app.quiz.rounds[0].questions[0].image = "test.dat"
  try app.write(to: dest)
  let portable = try JSONDecoder().decode(QuizFile.self,from: Data(contentsOf: dest)); assert(portable.assets["test.dat"] == Data([1,2,3]))
  let extracted = Studio(draftURL: root.appendingPathComponent("extract-draft.quiz")); extracted.timer?.invalidate(); assert(extracted.load(dest)); assert(tryData(extracted.asset("test.dat")!) == Data([1,2,3]))
  app.quiz.teams = [Team(name: "А",scores: ["1": 3,"2": 5]), Team(name: "Б",scores: ["1": 8])]
  assert(app.quiz.teams[0].total == 8 && app.quiz.teams[1].total == 8)

  let game = Studio(draftURL: root.appendingPathComponent("game-draft.quiz")); game.timer?.invalidate()
  assert(game.screen == .home)
  game.quiz.rounds[0].questions[0].text = "Готовый вопрос"; game.quiz.rounds[0].questions[0].answer = "Ответ"
  game.quiz.rounds[0].standings = true
  game.addRound(); game.quiz.rounds[1].questions[0].text = "Второй раунд"; game.quiz.rounds[1].questions[0].answer = "Ответ"; game.quiz.rounds[1].standings = true
  let r1 = game.quiz.rounds[0].id.uuidString
  let r2 = game.quiz.rounds[1].id.uuidString
  game.quiz.teams = [Team(name: "Знатоки",scores: [r1: 8]),Team(name: "Совушки",scores: [r1: 6])]
  let gameURL = root.appendingPathComponent("saved-game.quiz"); try game.write(to: gameURL); assert(game.load(gameURL))
  game.prepareGame(); game.resetScores = false; game.introductionSeconds = 3; game.beginGame()
  assert(game.playing && game.steps[0].kind == .introduction && game.steps[1].kind == .introduction && game.steps[2].kind == .question)
  assert(game.quiz.teams[0].scores[r1] == 8)
  for _ in 0..<17 { game.tick() }; assert(game.index == 1)
  game.index = game.steps.firstIndex { $0.kind == .standings }!; game.enter()
  game.next(); game.quiz.teams[0].scores[r2] = 7; game.autosave()
  game.index = game.steps.lastIndex { $0.kind == .standings }!; game.enter()
  assert(game.quiz.teams[0].scores[r1] == 8 && game.quiz.teams[0].scores[r2] == 7 && game.quiz.teams[0].total == 15)
  let reopened = Studio(draftURL: root.appendingPathComponent("another-draft.quiz")); reopened.timer?.invalidate()
  assert(reopened.load(gameURL)); assert(reopened.quiz.teams[0].total == 15)
  reopened.prepareGame(); reopened.resetScores = true; reopened.beginGame()
  assert(reopened.playing && reopened.quiz.teams.map(\.total) == [0,0] && reopened.quiz.teams[0].name == "Знатоки")
  reopened.stop(); reopened.quiz.teams[1].name = "знатоки"; reopened.prepareGame(); reopened.beginGame(); assert(!reopened.playing)
  reopened.quiz.teams = []; reopened.beginGame(); assert(!reopened.playing)
  reopened.quiz.teams = [Team(name: "Тест",scores: [r1: 12])]; reopened.quiz.rounds[0].questions[0].text = ""; reopened.beginGame()
  assert(!reopened.playing && reopened.quiz.teams[0].total == 12)
  print("PASS: home routing, team introductions, introduction timing, retained scores across two standings, persisted results on reopening, reset without losing names, name validation, validation before score reset")


  // Existing quiz files must remain readable with optional new fields absent.
  let oldJSON = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
  let legacy = try JSONDecoder().decode(Quiz.self,from: oldJSON)
  assert(legacy.rounds[0].questions[0].selectedChoice == nil)
  var choice = Question(); choice.text = "Вопрос"; choice.kind = "Один из четырёх"; choice.choices = ["А","Б","В","Г"]
  assert(!choice.issues.isEmpty)
  choice.selectedChoice = 2; assert(choice.correctAnswer == "В" && choice.issues.isEmpty)
  choice.choices[2] = "Изменённый ответ"; assert(choice.correctAnswer == "Изменённый ответ")
  var matching = Question(); matching.text = "Сопоставьте"; matching.kind = "Сопоставление"
  matching.matchPairs = [MatchPair(left: "Франция",right: "Париж"),MatchPair(left: "Япония",right: "Токио"),MatchPair(left: "Италия",right: "Рим")]
  assert(matching.issues.isEmpty)
  for _ in 0..<100 {
    let layout = MatchLayout.make(matching.matchPairs!)
    assert(Set(layout.left) == Set(matching.matchPairs!.map(\.id)) && Set(layout.right) == Set(layout.left))
    assert(layout.left != layout.right)
    for id in layout.left { assert(layout.right.firstIndex(of: id) != nil) }
  }
  matching.matchPairs![0].right = ""; assert(!matching.issues.isEmpty)
  matching.matchPairs![0].right = "Париж"
  for kind in [Step.Kind.introduction,.answer,.standings,.finish] { assert(!Step(kind: kind,round: 0,duration: 5).showsTimer) }
  assert(Step(kind: .question,round: 0,duration: 5).showsTimer)
  app.quiz.rounds[0].questions[0] = matching
  app.start(); let layout = app.matchLayouts[matching.id]!
  app.next(); app.back(); assert(app.matchLayouts[matching.id]!.right == layout.right)

  let promptIndex = app.steps.firstIndex { $0.kind == .answerPrompt }!
  app.index = promptIndex; app.enter(); assert(app.player == nil && !app.step!.showsTimer)
  for _ in 0..<22 { app.tick() }; assert(app.step!.kind == .answer)
  assert(app.handleKey(49) && app.paused)
  let frozen = app.remaining; for _ in 0..<10 { app.tick() }; assert(app.remaining == frozen)
  assert(app.handleKey(123)); assert(app.step!.kind == .answerPrompt && app.paused)
  assert(app.handleKey(124)); assert(app.step!.kind == .answer && app.paused)
  assert(app.handleKey(49) && !app.paused)
  assert(!app.handleKey(0))
  let legacyFolder = root.appendingPathComponent("legacy.quiz")
  try app.writeDirectory(to: legacyFolder)
  let imported = Studio(draftURL: root.appendingPathComponent("import-draft.quiz")); imported.timer?.invalidate()
  assert(imported.load(legacyFolder)); assert(imported.quiz == app.quiz)
  let migrated = root.appendingPathComponent("migrated.quiz"); try imported.write(to: migrated)
  var directory: ObjCBool = false; assert(FileManager.default.fileExists(atPath: migrated.path,isDirectory: &directory) && !directory.boolValue)
  assert(imported.load(migrated)); assert(imported.quiz == app.quiz)
  let invalid = root.appendingPathComponent("invalid.quiz")
  try JSONEncoder().encode(QuizFile(quiz: app.quiz,assets: ["../outside": Data([1])])).write(to: invalid)
  let beforeInvalid = imported.quiz; assert(!imported.load(invalid) && imported.quiz == beforeInvalid)
  let editor = NSTextView()
  let field = MockScoreField(editor: editor); field.stringValue = "0"; editor.string = "0"; field.selectZero(); assert(editor.string.isEmpty)
  var score = 0
  let scoreInput = ScoreField(value: Binding(get: { score },set: { score = $0 }))
  let delegate = scoreInput.makeCoordinator(); field.stringValue = "12"
  delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,object: field)); assert(score == 12)
  field.stringValue = ""; delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,object: field)); assert(score == 0)
  print("PASS: single-file quiz with embedded assets, archive extraction, old-folder migration, archive path validation, answer prompt before reveal, independent keyboard handling, paused navigation, zero clearing and score input")

  app.quiz.rounds[0].questions[0].explanation = "Объяснение"
  app.quiz.rounds[0].questions[0].explanationImage = "test.dat"
  app.quiz.rounds[0].questions[0].explanationMedia = "test.dat"
  app.quiz.rounds[0].questions[0].image = nil
  try app.write(to: root.appendingPathComponent("explanation.quiz"))
  let explanationData = try Data(contentsOf: root.appendingPathComponent("explanation.quiz"))
  let savedExplanation = try JSONDecoder().decode(QuizFile.self,from: explanationData)
  assert(savedExplanation.quiz.rounds[0].questions[0].explanation == "Объяснение")
  assert(savedExplanation.assets["test.dat"] == Data([1,2,3]))
  app.returnToMenu(); assert(!app.playing && app.screen == .home && app.player == nil)
  print("PASS: legacy decoding, selected correct choice, matching completeness and shuffle, stable repeat mapping, hidden timers, explanation persistence and assets, return to menu")


  let withIntro = Studio(draftURL: root.appendingPathComponent("round-intro-draft.workspace")); withIntro.timer?.invalidate()
  withIntro.quiz.rounds[0].questions[0].text = "Вопрос"; withIntro.quiz.rounds[0].questions[0].answer = "Ответ"
  withIntro.folder = mediaRoot
  withIntro.quiz.rounds[0].intro = RoundIntro(text: "Правила раунда",image: "test.dat",media: nil,seconds: 5)
  withIntro.quiz.rounds[0].repeatQuestions = true; withIntro.quiz.rounds[0].repeatSeconds = 1
  withIntro.start(); assert(withIntro.step!.kind == .roundIntro && !withIntro.step!.showsTimer)
  for _ in 0..<38 { withIntro.tick() }; assert(withIntro.step!.kind == .question)
  withIntro.index = withIntro.steps.firstIndex { $0.kind == .repeated }!; withIntro.enter()
  for _ in 0..<6 { withIntro.tick() }; assert(withIntro.step!.kind == .pause)
  let introFile = root.appendingPathComponent("intro.quiz"); try withIntro.write(to: introFile)
  let archivedIntro = try JSONDecoder().decode(QuizFile.self,from: Data(contentsOf: introFile))
  assert(archivedIntro.quiz.rounds[0].intro?.text == "Правила раунда" && archivedIntro.assets["test.dat"] == Data([1,2,3]))
  withIntro.quiz.rounds[0].intro?.media = "test.dat"
  try withIntro.write(to: introFile); let archivedMediaIntro = try JSONDecoder().decode(QuizFile.self,from: Data(contentsOf: introFile)); assert(archivedMediaIntro.quiz.rounds[0].intro?.media == "test.dat")
  do { try withIntro.write(to: legacyFolder); assertionFailure("Must not overwrite a legacy folder") } catch { }
  assert(FileManager.default.fileExists(atPath: legacyFolder.appendingPathComponent("quiz.json").path))
  print("PASS: round explanation step and timer, immediate repeat transitions, embedded round image and media, refusal to overwrite legacy folders")


  let libraryFolder = root.appendingPathComponent("library")
  try FileManager.default.createDirectory(at: libraryFolder,withIntermediateDirectories: true)
  let libraryFile = libraryFolder.appendingPathComponent("Saved.quiz")
  try withIntro.write(to: libraryFile)
  let suite = "QuizStudioTests-" + UUID().uuidString
  let preferences = UserDefaults(suiteName: suite)!
  defer { preferences.removePersistentDomain(forName: suite) }
  let library = Studio(draftURL: root.appendingPathComponent("library-draft.workspace"),libraryDefaults: preferences,nearbyFolder: libraryFolder); library.timer?.invalidate()
  assert(library.recentQuizzes == [libraryFile.standardizedFileURL])
  library.showLibrary(editing: true); assert(library.screen == .createLibrary)
  library.editQuiz(libraryFile); assert(library.screen == .editor && library.documentURL == libraryFile && library.quiz.rounds[0].intro?.text == "Правила раунда")
  library.removeFromLibrary(libraryFile); assert(library.recentQuizzes.isEmpty && FileManager.default.fileExists(atPath: libraryFile.path))
  let reloadedLibrary = Studio(draftURL: root.appendingPathComponent("library-reloaded.workspace"),libraryDefaults: preferences,nearbyFolder: libraryFolder); reloadedLibrary.timer?.invalidate()
  assert(reloadedLibrary.recentQuizzes.isEmpty)
  assert(reloadedLibrary.load(libraryFile)); assert(reloadedLibrary.recentQuizzes == [libraryFile.standardizedFileURL])
  reloadedLibrary.remember(libraryFile); assert(reloadedLibrary.recentQuizzes.count == 1)
  reloadedLibrary.showLibrary(editing: false); assert(reloadedLibrary.screen == .library)
  reloadedLibrary.newQuiz(); assert(reloadedLibrary.screen == .editor && reloadedLibrary.documentURL == nil && reloadedLibrary.quiz.title == "Новый квиз")
  print("PASS: creation library, open for editing, non-destructive removal, hidden discovery after restart, explicit restore, duplicate prevention, play library and new blank quiz")

  print("PASS: schedule, per-round defaults, pause, automatic transitions, back, untimed question, save/load, portable assets, scores")
 }
}

final class MockScoreField: SelectableScoreTextField {
    let editor: NSTextView
    init(editor: NSTextView) { self.editor = editor; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func currentEditor() -> NSText? { editor }
}

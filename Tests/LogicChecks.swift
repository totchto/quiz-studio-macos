import PDFKit
struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct Checks {
 @MainActor static func tryData(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
 @MainActor static func tryRange(start: Double,end: Double,duration: Double) -> Bool { (try? MediaRange.resolve(start: start,end: end,duration: duration)) != nil }
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
  assert(app.steps.map(\.kind) == [.question,.question,.repeatIntro,.repeated,.repeated,.pause,.answerPrompt,.answer,.answerPrompt,.answer,.standings,.finish])
  let phones = Studio(draftURL: root.appendingPathComponent("phone-flow.quiz"))
  phones.timer?.invalidate(); phones.quiz = app.quiz; phones.phoneMode = true; phones.start()
  assert(phones.steps.map(\.kind) == [.question,.question,.answerPrompt,.answer,.answerPrompt,.answer,.standings,.finish])
  phones.stop(); assert(!phones.playing && phones.screen == .home)
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
  var score: Double = 0
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
  library.showLibrary(); assert(library.screen == .createLibrary)
  library.editQuiz(libraryFile); assert(library.screen == .editor && library.documentURL == libraryFile && library.quiz.rounds[0].intro?.text == "Правила раунда")
  library.removeFromLibrary(libraryFile); assert(library.recentQuizzes.isEmpty && FileManager.default.fileExists(atPath: libraryFile.path))
  let reloadedLibrary = Studio(draftURL: root.appendingPathComponent("library-reloaded.workspace"),libraryDefaults: preferences,nearbyFolder: libraryFolder); reloadedLibrary.timer?.invalidate()
  assert(reloadedLibrary.recentQuizzes.isEmpty)
  assert(reloadedLibrary.load(libraryFile)); assert(reloadedLibrary.recentQuizzes == [libraryFile.standardizedFileURL])
  reloadedLibrary.remember(libraryFile); assert(reloadedLibrary.recentQuizzes.count == 1)
  reloadedLibrary.showLibrary(); assert(reloadedLibrary.screen == .createLibrary)
  reloadedLibrary.newQuiz(); assert(reloadedLibrary.screen == .editor && reloadedLibrary.documentURL == nil && reloadedLibrary.quiz.title == "Новый квиз")
  let appSupport=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("QuizStudio")
  let seedDraft=appSupport.appendingPathComponent("ActiveDraftCheck-"+UUID().uuidString+".workspace")
  let activeSuite="QuizStudioActiveDraft-"+UUID().uuidString
  let activeDefaults=UserDefaults(suiteName:activeSuite)!
  var createdActivePath:String?
  defer { activeDefaults.removePersistentDomain(forName:activeSuite); try? FileManager.default.removeItem(at:seedDraft); if let path=createdActivePath { try? FileManager.default.removeItem(atPath:path) } }
  let nextLaunch=Studio(draftURL:seedDraft,libraryDefaults:activeDefaults,nearbyFolder:libraryFolder); nextLaunch.timer?.invalidate(); nextLaunch.newQuiz()
  let activeDraftPath = activeDefaults.string(forKey:"ActiveDraftWorkspace")!
  createdActivePath=activeDraftPath
  assert(nextLaunch.draft.path == activeDraftPath && nextLaunch.quiz.title == "Новый квиз")
  nextLaunch.quiz.rounds[0].questions[0].text="Черновик после запуска"; nextLaunch.autosave(); nextLaunch.flushAutosave { _ in }
  for _ in 0..<100 { if let saved=try? Data(contentsOf:nextLaunch.draft.appendingPathComponent("quiz.json")), let decoded=try? JSONDecoder().decode(Quiz.self,from:saved), decoded.rounds[0].questions[0].text=="Черновик после запуска" { break }; Thread.sleep(forTimeInterval:0.02) }
  let nextProcess = Studio(libraryDefaults:activeDefaults,nearbyFolder:libraryFolder); nextProcess.timer?.invalidate()
  assert(nextProcess.draft.path == activeDraftPath && nextProcess.quiz.rounds[0].questions[0].text == "Черновик после запуска")
  print("PASS: creation library, open for editing, non-destructive removal, hidden discovery after restart, explicit restore, duplicate prevention, play library and new blank quiz")


  let presentation = Studio(draftURL: root.appendingPathComponent("presentation.workspace")); presentation.timer?.invalidate()
  presentation.quiz.rounds[0].questions[0].text = "Вопрос"; presentation.quiz.rounds[0].questions[0].answer = "Ответ"
  presentation.quiz.rounds[0].repeatQuestions = true; presentation.quiz.rounds[0].repeatIntroSeconds = 2; presentation.quiz.rounds[0].standings = true
  presentation.quiz.teams = [Team(name: "Лидер",scores: ["r":10]),Team(name: "Вторая",scores: ["r":7]),Team(name: "Тоже вторая",scores: ["r":7]),Team(name: "Четвёртая",scores: ["r":2])]
  presentation.quiz.scoreRevealSeconds = 1
  presentation.start()
  let repeatedIndex = presentation.steps.firstIndex { $0.kind == .repeated }!
  assert(presentation.steps[repeatedIndex-1].kind == .repeatIntro && !presentation.steps[repeatedIndex-1].showsTimer)
  presentation.index = repeatedIndex-1; presentation.enter()
  for _ in 0..<12 { presentation.tick() }; assert(presentation.step!.kind == .repeated)
  presentation.index = presentation.steps.firstIndex { $0.kind == .standings }!; presentation.enter(); presentation.publishScores()
  assert(presentation.scoreRevealedIDs.isEmpty && presentation.nextScoreRank == 4)
  for _ in 0..<6 { presentation.tick() }; assert(presentation.scoreRevealedIDs.count == 1 && presentation.nextScoreRank == 2)
  presentation.paused = true
  for _ in 0..<50 { presentation.tick() }; assert(presentation.scoreRevealedIDs.count == 1)
  presentation.paused = false
  for _ in 0..<6 { presentation.tick() }; assert(presentation.scoreRevealedIDs.count == 3 && presentation.nextScoreRank == 1)
  for _ in 0..<6 { presentation.tick() }; assert(presentation.scoresFullyRevealed && presentation.scoreRevealedIDs.count == 4)
  presentation.publishScores(); presentation.revealAllScores(); assert(presentation.scoresFullyRevealed)
  presentation.back(); assert(!presentation.publishedScores && presentation.scoreRevealedIDs.isEmpty)
  assert(legacy.appearance == nil && legacy.scoreRevealSeconds == nil)
  let media = root.appendingPathComponent("theme-store/Media"); try FileManager.default.createDirectory(at: media,withIntermediateDirectories: true)
  let fontFiles = FileManager.default.enumerator(at: URL(fileURLWithPath: "/System/Library/Fonts"),includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
  let fontURL = fontFiles.first { ["ttf","otf","ttc"].contains($0.pathExtension.lowercased()) }!
  let embeddedFont = "custom." + fontURL.pathExtension
  try FileManager.default.copyItem(at: fontURL,to: media.appendingPathComponent(embeddedFont))
  try Data([1,2,3]).write(to: media.appendingPathComponent("background.png"))
  presentation.folder = media.deletingLastPathComponent()
  let fontName = presentation.registerFont(media.appendingPathComponent(embeddedFont))!
  presentation.quiz.appearance = QuizAppearance(fontName: fontName,fontFile: embeddedFont,background: "Лес",backgroundImage: "background.png",imageDimming: 0.6)
  let themedURL = root.appendingPathComponent("themed.quiz"); try presentation.write(to: themedURL)
  let themeArchive = try JSONDecoder().decode(QuizFile.self,from: Data(contentsOf: themedURL))
  assert(themeArchive.assets.count == 2 && themeArchive.quiz.appearance?.background == "Лес")
  let themed = Studio(draftURL: root.appendingPathComponent("themed.workspace")); themed.timer?.invalidate()
  assert(themed.load(themedURL) && themed.registeredFontName == fontName && themed.presentationFontName == fontName)
  assert(themed.quiz.appearance?.imageDimming == 0.6 && themed.referencedAssets.count == 2)
  themed.quiz.appearance = nil; assert(themed.presentationFontName == nil && themed.referencedAssets.isEmpty)
  print("PASS: repeat announcement and timing, suspense reveal from last place, simultaneous ties, paused reveal, reveal-all and reset, legacy appearance defaults, embedded custom font/background and font registration after import")


  let reorder = Studio(draftURL: root.appendingPathComponent("reorder.workspace")); reorder.timer?.invalidate()
  var a = Question(); a.text = "А"; a.answer = "Ответ А"
  var b = Question(); b.text = "Б"; b.answer = "Ответ Б"; b.explanation = "Объяснение Б"
  var c = Question(); c.text = "В"; c.answer = "Ответ В"
  var d = Question(); d.text = "Г"; d.answer = "Ответ Г"
  reorder.quiz.rounds = [Round(title: "Первый",questions: [a,b,c]),Round(title: "Второй",questions: [d])]
  let firstRound = reorder.quiz.rounds[0].id, secondRound = reorder.quiz.rounds[1].id
  let binding = reorder.questionBinding(b.id)
  assert(reorder.moveQuestion(c.id,toRound: firstRound,before: a.id)); assert(reorder.quiz.rounds[0].questions.map(\.id) == [c.id,a.id,b.id])
  assert(reorder.moveQuestion(b.id,toRound: secondRound,before: d.id)); assert(reorder.quiz.rounds[1].questions.map(\.id) == [b.id,d.id])
  assert(binding.wrappedValue == b)
  var modified = binding.wrappedValue; modified.text = "Б после переноса"; binding.wrappedValue = modified
  assert(reorder.quiz.rounds[1].questions[0].text == "Б после переноса" && reorder.quiz.rounds[0].questions[1].text == "А")
  assert(reorder.moveQuestion(d.id,toRound: firstRound)); assert(reorder.quiz.rounds[0].questions.last?.id == d.id)
  assert(reorder.moveQuestion(b.id,toRound: firstRound)); assert(reorder.quiz.rounds[1].questions.isEmpty)
  assert(Set(reorder.quiz.rounds.flatMap(\.questions).map(\.id)).count == 4)
  let snapshot = reorder.quiz; assert(!reorder.moveQuestion(a.id,toRound: UUID()) && reorder.quiz == snapshot)
  assert(!reorder.moveQuestion(a.id,toRound: firstRound,before: a.id))
  let reorderedFile = root.appendingPathComponent("reordered.quiz"); try reorder.write(to: reorderedFile)
  let reorderedLoad = Studio(draftURL: root.appendingPathComponent("reordered-load.workspace")); reorderedLoad.timer?.invalidate(); assert(reorderedLoad.load(reorderedFile))
  assert(reorderedLoad.quiz.rounds[1].questions.isEmpty && reorderedLoad.quiz.rounds[0].questions.map(\.id) == reorder.quiz.rounds[0].questions.map(\.id))
  reorderedLoad.start(); assert(!reorderedLoad.playing && !reorderedLoad.incompleteQuestions.isEmpty)
  reorderedLoad.roundIndex = 1; reorderedLoad.addQuestion(); assert(reorderedLoad.selectedQuestion != nil)
  reorderedLoad.deleteSelectedQuestion(); assert(reorderedLoad.selectedQuestion == nil)
  let validRange = try MediaRange.resolve(start: 10,end: 200,duration: 100); assert(validRange == MediaRange(start: 10,end: 100))
  assert(tryRange(start: 100,end: 0,duration: 100) == false && tryRange(start: .nan,end: 0,duration: 100) == false)
  print("PASS: drag reorder, cross-round move, stable editor binding, empty-round save/load, empty-round start validation, refill/delete empty round, media range clamping and invalid ranges")

  let modes = Studio(draftURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-modes.workspace"))
  modes.steps = [Step(kind: .question,round: 0,question: 0,duration: 2),Step(kind: .finish,round: 0,duration: 0)]
  modes.playing = true; modes.readBeforeTimer = true; modes.enter()
  for _ in 0..<30 { modes.tick() }
  assert(modes.awaitingQuestionStart && modes.remaining == 2 && modes.index == 0)
  assert(modes.handleKey(49)); assert(!modes.awaitingQuestionStart && !modes.paused)
  for _ in 0..<30 { modes.tick() }; assert(modes.index == 1)
  modes.automaticAdvance = false; modes.index = 0; modes.enter(); modes.startQuestionTimer()
  for _ in 0..<40 { modes.tick() }; assert(modes.remaining == 0 && modes.index == 0)
  modes.togglePause(); assert(modes.paused); modes.togglePause(); assert(!modes.paused)
  modes.handleKey(124); assert(modes.index == 1)
  modes.back(); assert(modes.awaitingQuestionStart && modes.remaining == 2)
  modes.readBeforeTimer = false; modes.enter(); assert(!modes.awaitingQuestionStart)
  for _ in 0..<40 { modes.tick() }; assert(modes.remaining == 0 && modes.index == 0)
  modes.steps = [Step(kind: .repeated,round: 0,question: 0,duration: 1),Step(kind: .finish,round: 0,duration: 0)]
  modes.readBeforeTimer = true; modes.enter(); assert(!modes.awaitingQuestionStart)
  for _ in 0..<20 { modes.tick() }; assert(modes.index == 0)
  modes.automaticAdvance = true; modes.tick(); assert(modes.index == 1)
  print("PASS: reading gate, space starts timer, automatic/manual advance, pause, next/back, repeat without reading gate")

  let reliable = Studio(draftURL: root.appendingPathComponent("reliable.workspace")); reliable.timer?.invalidate()
  reliable.quiz.rounds[0].questions = [Question(text: "Сохраняемый вопрос",answer: "Ответ",seconds: 30)]
  reliable.quiz.teams = [Team(name: "А",scores: ["r": 1.5]),Team(name: "Б",scores: ["r": -0.5])]
  reliable.start(); reliable.index = 2; reliable.enter(); reliable.remaining = 17
  reliable.checkpoint(); let expectedStep = reliable.step?.kind
  let resumed = Studio(draftURL: reliable.draft); resumed.timer?.invalidate(); assert(resumed.recoveryAvailable)
  resumed.restoreGame(); assert(resumed.playing && resumed.paused && resumed.remaining == 17 && resumed.step?.kind == expectedStep)
  assert(resumed.quiz.teams[0].total == 1.5 && resumed.quiz.teams[1].total == -0.5)
  resumed.stop(preserveRecovery: true); assert(resumed.recoveryAvailable && resumed.screen == .home)
  resumed.restoreGame(); resumed.stop(); assert(!resumed.recoveryAvailable)
  let undo = Studio(draftURL: root.appendingPathComponent("undo.workspace")); undo.timer?.invalidate(); undo.screen = .editor
  undo.quiz.rounds[0].questions[0].text = "До удаления"; undo.deleteSelectedQuestion(); assert(undo.selectedQuestion == nil)
  undo.undoEdit(); assert(undo.selectedQuestion?.text == "До удаления")
  var extra = Round(title: "Тайбрейк",questions: [Question(text: "Решающий",answer: "Да")]); extra.tieBreaker = true
  undo.quiz.rounds[0].questions[0].answer = "Ответ"
  undo.quiz.rounds.append(extra); undo.start()
  let extraIndex = undo.steps.firstIndex { $0.round == 1 && $0.kind == .question }!
  undo.index = extraIndex-1; undo.next(); assert(undo.step?.kind == .finish)
  undo.jump(to: extraIndex); assert(undo.paused && undo.currentQuestion?.text == "Решающий")
  undo.quiz.rounds[1].muteBackground = true; assert(undo.roundMutesBackground)
  field.stringValue = "-1,25"; delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,object: field)); assert(score == -1.25)
  let sheets = root.appendingPathComponent("answers.pdf"); try undo.exportSheets(to: sheets,answers: true)
  let pdfBytes = try Data(contentsOf: sheets); assert(pdfBytes.starts(with: Data("%PDF".utf8)))
  let pdf = PDFDocument(url: sheets)!; assert(pdf.pageCount == 2 && (pdf.string ?? "").contains("Решающий"))
  undo.quiz.rounds[0].questions[0].explanation = String(repeating: "Строка объяснения\n",count: 150) + "КОНЕЦ ОБЪЯСНЕНИЯ"
  try undo.exportSheets(to: sheets,answers: true)
  let longPDF = PDFDocument(url: sheets)!; assert(longPDF.pageCount > 2 && (longPDF.string ?? "").contains("КОНЕЦ ОБЪЯСНЕНИЯ"))
  try undo.exportSheets(to: root.appendingPathComponent("blank.pdf"),answers: false)
  assert(PDFDocument(url: root.appendingPathComponent("blank.pdf"))!.pageCount == 2)
  print("PASS: recovery paused with retained timer/scores, explicit recovery exit, undo deletion, optional tie-breaker skip/jump, round music suppression, decimal penalties and printable PDF")

  let librarySource = root.appendingPathComponent("library-source.quiz")
  undo.quiz.rounds[0].hostNotes = "Заметка о раунде"
  undo.quiz.rounds[0].questions[0].hostNotes = "Произнести слово правильно"
  undo.quiz.teams = [Team(name: "Команда",scores: ["r": 2.5])]
  try undo.write(to: librarySource); let originalBytes = try Data(contentsOf: librarySource)
  let currentBeforeCopy = undo.quiz
  let copiedURL = root.appendingPathComponent("library-copy.quiz")
  try undo.duplicateQuiz(from: librarySource,to: copiedURL)
  assert(undo.quiz == currentBeforeCopy && (tryData(librarySource)) == originalBytes)
  let copyArchive = try JSONDecoder().decode(QuizFile.self,from: Data(contentsOf: copiedURL))
  assert(copyArchive.quiz.title.hasSuffix("— копия") && copyArchive.quiz.teams[0].total == 0)
  assert(copyArchive.quiz.rounds[0].hostNotes == "Заметка о раунде" && copyArchive.quiz.rounds[0].questions[0].hostNotes == "Произнести слово правильно")
  undo.jump(to: undo.steps.firstIndex { $0.round == 0 && $0.kind == .question }!)
  assert(undo.hostNote.contains("Произнести") && undo.hostNote.contains("Заметка"))
  assert(!undo.publishedScores); undo.publishScores(); assert(undo.publishedScores)
  undo.jump(to: undo.steps.firstIndex { $0.kind == .standings }!); assert(!undo.publishedScores && !undo.showScoreInputLocally)
  do { try undo.duplicateQuiz(from: librarySource,to: librarySource); assertionFailure("Must not overwrite source") } catch {}
  print("PASS: quiz duplication without source/current edits, reset copied scores, portable host notes, standings remain private until publication")

  print("PASS: schedule, per-round defaults, pause, automatic transitions, back, untimed question, save/load, portable assets, scores")
 }
}

final class MockScoreField: SelectableScoreTextField {
    let editor: NSTextView
    init(editor: NSTextView) { self.editor = editor; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func currentEditor() -> NSText? { editor }
}

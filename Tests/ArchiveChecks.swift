struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct ArchiveChecks {
 @MainActor static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let app=Studio(draftURL:root.appendingPathComponent("Draft.workspace"));app.timer?.invalidate()
  var q=Question();q.text="Первый вопрос";q.answer="Верно";q.bankEntryID=UUID()
  var q2=Question();q2.text="Второй вопрос";q2.answer="Два"
  var q3=Question();q3.text="Третий вопрос";q3.answer="Три"
  app.quiz.rounds[0].questions=[q,q2,q3];app.quiz.rounds[0].breakSeconds=0
  app.quiz.teams=[Team(name:"Команда А"),Team(name:"Команда Б"),Team(name:"Команда В"),Team(name:"=1+1")]
  app.phoneMode=true;app.start();assert(app.playing && app.archiveRun != nil)
  let id=app.archiveRun!.id
  app.index=app.steps.firstIndex { $0.kind == .question && $0.question == 0 }!;app.enter()
  let teams=app.quiz.teams
  app.phoneRoom.answers=[PhoneAnswer(teamID:teams[0].id,questionID:q.id,roundID:app.quiz.rounds[0].id,display:"Верно",payload:Data(),points:1),PhoneAnswer(teamID:teams[1].id,questionID:q.id,roundID:app.quiz.rounds[0].id,display:"Ошибка",payload:Data(),points:0),PhoneAnswer(teamID:teams[2].id,questionID:q.id,roundID:app.quiz.rounds[0].id,display:"Проверьте меня",payload:Data(),points:nil)]
  app.checkpoint();app.next();app.checkpoint()
  let partial=app.gameArchive.games.first!;let stats=partial.stats(for:partial.questions[0]);assert(stats.correct==1 && stats.wrong==1 && stats.pending==1 && stats.missing==1 && stats.percent==25)
  assert(partial.stats(for:partial.questions[1]).shown && !partial.stats(for:partial.questions[1]).closed && partial.stats(for:partial.questions[1]).percent==nil)
  assert(!partial.stats(for:partial.questions[2]).shown && partial.stats(for:partial.questions[2]).percent==nil)
  assert(GameArchive.aggregate([partial]).isEmpty)
  app.stop(preserveRecovery:true);assert(app.gameArchive.games.first!.status=="paused" && app.gameArchive.games.count==1)
  let restored=Studio(draftURL:app.draft);restored.timer?.invalidate();restored.restoreGame();assert(restored.playing && restored.archiveRun?.id==id)
  // A phone room without a listening port cannot be recovered; verify archived answers survive regardless.
  restored.phoneMode=true;restored.phoneRoom.answers=app.phoneRoom.answers
  restored.index=restored.steps.firstIndex { $0.kind == .finish }!;restored.enter()
  assert(restored.gameArchive.games.count==1 && restored.gameArchive.games[0].status=="completed")
  let completed=restored.gameArchive.games[0];assert(completed.answers.count==3 && completed.closed.contains(q2.id) && !completed.shown.contains(q3.id))
  var noted=completed; noted.notes="Задержка оборудования"; noted.questions[0].notes="Спорный вопрос"; try restored.gameArchive.save(noted)
  let notedReload=GameArchive(root:restored.gameArchive.root).games.first { $0.id==id }!; assert(notedReload.notes=="Задержка оборудования" && notedReload.questions[0].notes=="Спорный вопрос")
  var legacyObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(completed)) as! [String:Any]; legacyObject.removeValue(forKey:"notes"); legacyObject.removeValue(forKey:"sourcePath")
  legacyObject["questions"]=(legacyObject["questions"] as! [[String:Any]]).map { item in var copy=item; copy.removeValue(forKey:"notes"); return copy }
  let legacy=try JSONDecoder().decode(ArchivedGame.self,from:JSONSerialization.data(withJSONObject:legacyObject)); assert(legacy.notes==nil && legacy.sourcePath==nil && legacy.questions[0].notes==nil)
  let aggregate=GameArchive.aggregate([completed]);assert(aggregate.count==2 && aggregate.first { $0.question.id==q.id }!.percent==25)
  restored.phoneRoom.grade(restored.phoneRoom.answers[2].id,points:1)
  assert(restored.gameArchive.games[0].stats(for:completed.questions[0]).pending==0 && restored.gameArchive.games[0].stats(for:completed.questions[0]).correct==2)
  let csv=GameArchive.scoresCSV(completed);assert(csv.contains("'=1+1"))
  let questionsCSV=GameArchive.questionsCSV(completed);assert(questionsCSV.contains("Нужна проверка") && questionsCSV.contains("Не показан"))
  let archivedBytes=try Data(contentsOf:restored.gameArchive.root.appendingPathComponent(id.uuidString+".game"));assert(!String(decoding:archivedBytes,as:UTF8.self).contains("registrationKey"))
  restored.stop()
  // Repeating the same quiz creates a new run, preserving the original result snapshot.
  let firstText=restored.gameArchive.games.first!.questions[0].text
  restored.phoneMode=false;restored.quiz.rounds[0].questions[0].text="Новая редакция"
  let roundID=restored.quiz.rounds[0].id.uuidString
  restored.quiz.teams[0].scores=[roundID:1.25];restored.quiz.teams[1].scores=[roundID: -2];restored.quiz.teams[2].scores=[roundID:1.25]
  restored.start()
  assert(restored.archiveRun!.id != id);restored.stop()
  assert(restored.gameArchive.games.count==2 && restored.gameArchive.games.first { $0.id==id }!.questions[0].text==firstText)
  let reloaded=GameArchive(root:restored.gameArchive.root);assert(reloaded.games.count==2)
  assert(reloaded.games.contains { $0.status=="stopped" && !$0.phone })
  let paper=reloaded.games.first { !$0.phone }!
  assert(paper.sortedTeams[0].total==1.25 && paper.sortedTeams[1].total==1.25 && paper.sortedTeams.last!.total == -2)
  assert(GameArchive.scoresCSV(paper).components(separatedBy:"\r\n").filter { $0.hasPrefix("\"1\",") }.count==2)
  restored.quiz.teams[0].scores=[roundID:99];assert(paper.teams[0].total==1.25)
  let finished=reloaded.games.first { $0.id==id }!
  let snapshot=GameArchive.aggregate([finished]);assert(snapshot.first { $0.question.id==q.id }!.correct==2)
  let transition=Studio(draftURL:root.appendingPathComponent("ArchiveTransition.workspace"));transition.timer?.invalidate()
  var transitionQuestion=Question(text:"Из архива",answer:"Ответ");transitionQuestion.id=UUID()
  transition.quiz.rounds[0].questions=[transitionQuestion];let transitionSource=root.appendingPathComponent("Archive-source.quiz")
  try transition.write(to:transitionSource);assert(transition.load(transitionSource));transition.start()
  transition.index=transition.steps.firstIndex{$0.kind == .finish}!;transition.enter()
  let transitionGame=transition.gameArchive.games.first!;let transitionQuestionSnapshot=transitionGame.questions.first!
  GameArchiveView(studio:transition).openQuestion(game:transitionGame,question:transitionQuestionSnapshot)
  assert(!transition.playing && transition.screen == .editor && transition.focusEditorQuestionID == transitionQuestion.id && transition.gameArchive.games.first{$0.id==transitionGame.id}?.status=="completed")
  let preview=Studio(draftURL:root.appendingPathComponent("Preview.workspace"));preview.timer?.invalidate();preview.beginEditorPreview(from:restored,mode:.round);preview.persistArchive();assert(preview.archiveRun==nil);preview.endEditorPreview()
  var changed=q;changed.answer="Другой ответ";assert(ArchivedQuestion(q,round:app.quiz.rounds[0]).analysisKey != ArchivedQuestion(changed,round:app.quiz.rounds[0]).analysisKey)
  if CommandLine.arguments.count>2 {
   _ = NSApplication.shared
   let target=URL(fileURLWithPath:CommandLine.arguments[2]);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
   let host=NSHostingView(rootView:ArchivedGameDetail(game:finished,export:{ _ in }).padding(20).background(Color.white).environment(\.colorScheme,.light))
   host.frame=NSRect(x:0,y:0,width:900,height:1000);host.layoutSubtreeIfNeeded()
   let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:target.appendingPathComponent("Archive-detail.png"))
  }
  print("PASS: independent runs and immutable snapshots; correct/wrong/pending/missing statistics, unshown/open exclusions, completed-only aggregation; finish and post-finish grading; paused recovery keeps run ID; portable local reload; CSV escaping/formula protection; no credentials or media copied; preview excluded")
 }
}

struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct EditorChecks {
 @MainActor static func wait(_ predicate: () -> Bool) async throws {
  for _ in 0..<100 { if predicate() { return }; try await Task.sleep(nanoseconds:50_000_000) }
  throw SIQError(message:"Preview media preparation timed out")
 }
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let studio=Studio(draftURL:root.appendingPathComponent("Draft.workspace"));studio.timer?.invalidate();studio.screen = .editor
  let rehearsalOwner=Studio(draftURL:root.appendingPathComponent("RehearsalOwner.workspace"));rehearsalOwner.timer?.invalidate();var rehearsalQuiz=Quiz();rehearsalQuiz.rounds[0].questions=[Question()];rehearsalOwner.quiz=rehearsalQuiz;let rehearsalRecovery=rehearsalOwner.recoveryURL
  rehearsalOwner.beginRehearsal();assert(!rehearsalOwner.playing && rehearsalOwner.rehearsalSession?.playing==true && rehearsalOwner.quiz==rehearsalQuiz)
  let isolated=rehearsalOwner.rehearsalSession!;assert(!FileManager.default.fileExists(atPath:rehearsalRecovery.path));isolated.endRehearsal();assert(rehearsalOwner.rehearsalSession==nil && rehearsalOwner.quiz==rehearsalQuiz && !FileManager.default.fileExists(atPath:rehearsalRecovery.path))
  rehearsalOwner.beginRehearsal();let liveRehearsal=rehearsalOwner.rehearsalSession!;assert(liveRehearsal.timer != nil && liveRehearsal.steps.filter{$0.kind == .introduction}.isEmpty);liveRehearsal.endRehearsal()
  let repairGame=Studio(draftURL:root.appendingPathComponent("RepairGame.workspace"));repairGame.timer?.invalidate();var repairQuiz=Quiz();repairQuiz.rounds[0].questions=[Question(text:"Q",answer:"A")];repairQuiz.teams=[Team(name:"T")];repairGame.quiz=repairQuiz;repairGame.start();repairGame.jump(to:repairGame.steps.firstIndex{$0.kind == .question}!);repairGame.paused=false;repairGame.beginQuestionRepair();repairGame.repairDraft?.answer="B";repairGame.applyQuestionRepair();assert(!repairGame.paused)
  repairGame.paused=true;repairGame.beginQuestionRepair();repairGame.cancelQuestionRepair();assert(repairGame.paused,"cancel should preserve pause: paused=\(repairGame.paused), remembered=\(repairGame.repairWasPaused)")
  repairGame.awaitingQuestionStart=true;repairGame.paused=false;repairGame.beginQuestionRepair();repairGame.applyQuestionRepair()
  assert(repairGame.awaitingQuestionStart);assert(!repairGame.paused);repairGame.stop()
  assert(Question.cleanTags(" кино, музыка;КИНО\n космос ")==["кино","музыка","космос"])
  var q=Question();q.text="Назовите исполнителя";q.answer="Ответ";q.tags=["музыка","кино"];q.difficulty="Средний"
  let entry=try studio.questionBank.save(q,assets:[:]);try studio.insertBankQuestions([entry])
  // A blank placeholder is allowed while editing but must not affect previewing the selected question.
  studio.questionIndex=1
  let inserted=studio.quiz.rounds[0].questions[1];assert(inserted.tags==q.tags && inserted.bankEntryID==entry.id)
  let file=root.appendingPathComponent("Quiz.quiz");try studio.write(to:file)
  let firstHistory=studio.questionBank.entries.first!.history!;assert(firstHistory.count==1 && !firstHistory[0].played)
  try studio.write(to:file);assert(studio.questionBank.entries.first!.history!.count==1)
  studio.recordBankUsage(played:true);assert(studio.questionBank.entries.first!.history!.first!.played)
  let saved=QuestionBank(root:studio.questionBank.root);assert(saved.entries.first!.history!.count==1 && saved.entries.first!.question.difficulty=="Средний")
  print("PASS: tags normalize, metadata survives bank insertion, saved/played history persists without duplicate quiz entries")
  var other=Round();other.questions=[q];studio.quiz.rounds.append(other)
  let selected=Set([inserted.id,other.questions[0].id]);let before=studio.quiz;studio.undoHistory=[]
  studio.applyBulk(ids:selected,seconds:25,afterMedia:false,answerSeconds:35)
  assert(studio.quiz.rounds[0].questions[0].seconds==before.rounds[0].questions[0].seconds)
  assert(studio.quiz.rounds[0].questions[1].seconds==25 && studio.quiz.rounds[1].questions[0].answerSeconds==35 && !studio.quiz.rounds[1].questions[0].afterMedia)
  assert(studio.quiz.rounds[0].questions[1].text==inserted.text && studio.undoHistory.count==1)
  studio.undoEdit();assert(studio.quiz==before)
  let music=RoundTemplate.builtins[1];studio.undoHistory=[];studio.applyTemplate(music,roundID:studio.quiz.rounds[0].id)
  assert(studio.quiz.rounds[0].questions.count==2 && studio.quiz.rounds[0].questions[1].audioOnly && studio.quiz.rounds[0].questions[1].answerSeconds==30)
  assert(studio.undoHistory.count==1);studio.addQuestion();assert(studio.selectedQuestion!.seconds==30 && studio.selectedQuestion!.audioOnly && studio.selectedQuestion!.answerSeconds==30)
  try studio.roundTemplates.save(name:"Мой раунд",round:studio.quiz.rounds[0]);let templates=RoundTemplateStore(url:studio.roundTemplates.url);assert(templates.custom.count==1 && templates.custom[0].audioOnly==true)
  let templateID=templates.custom[0].id;try templates.save(name:"Мой раунд",round:other);assert(templates.custom.count==1 && templates.custom[0].id==templateID)
  print("PASS: bulk selection across rounds preserves unselected questions, one-step undo, template settings/undo, new-question defaults and custom template restart/update")
  studio.questionIndex=1;studio.quiz.rounds[0].repeatQuestions=true;studio.quiz.rounds[0].standings=true
  studio.folder=root;try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
  try FileManager.default.copyItem(at:root.appendingPathComponent("tone.wav"),to:root.appendingPathComponent("Media/tone.wav"))
  studio.quiz.rounds[0].questions[1].media="tone.wav";studio.quiz.rounds[0].questions[1].questionClip=ClipSettings(start:0.5,end:1.0)
  studio.quiz.rounds[0].questions[1].answerClip=ClipSettings(start:1.5,end:2.2)
  let originalQuiz=studio.quiz;let originalDraft=try Data(contentsOf:studio.draft.appendingPathComponent("quiz.json"));let history=studio.questionBank.entries.first!.history
  let preview=Studio(draftURL:root.appendingPathComponent("Preview.workspace"));preview.timer?.invalidate()
  preview.beginEditorPreview(from:studio,mode:.question);preview.togglePause()
  try await wait { !preview.playback.loading };assert(preview.playback.error==nil && preview.step?.kind == .question)
  assert(abs(preview.player!.currentTime().seconds-0.5)<0.1)
  preview.player?.volume=0;preview.checkpoint(copyAssets:true);assert(!FileManager.default.fileExists(atPath:preview.recoveryURL.path))
  preview.beginEditorPreview(from:studio,mode:.answer);preview.togglePause();try await wait { !preview.playback.loading };assert(preview.playback.error==nil && preview.step?.kind == .answer)
  assert(abs(preview.player!.currentTime().seconds-1.5)<0.1)
  preview.beginEditorPreview(from:studio,mode:.round);assert(preview.steps.filter { $0.kind == .question }.count==3)
  assert(preview.steps.contains { $0.kind == .repeatIntro } && preview.steps.contains { $0.kind == .answerPrompt } && !preview.steps.contains { $0.kind == .standings })
  preview.next();preview.back();preview.endEditorPreview()
  let afterDraft=try Data(contentsOf:studio.draft.appendingPathComponent("quiz.json"))
  assert(studio.quiz==originalQuiz && afterDraft==originalDraft && studio.questionBank.entries.first!.history==history && !preview.playing)
  print("PASS: incomplete editor quiz can preview selected question/answer, actual AVPlayer uses separate clip ranges, round sequence includes repeat and answer reveal, source draft/scores/history/recovery untouched, cleanup stops preview")
 }
}

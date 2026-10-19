struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct BankChecks {
 @MainActor static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let bank=QuestionBank(root:root.appendingPathComponent("QuestionBank"))
  var q=Question();q.text="Идея";q.media="original.mp3";q.questionClip=ClipSettings();q.explanation="Пояснение"
  let data=Data("audio-data".utf8)
  let idea=try bank.save(q,assets:["original.mp3":data]);assert(idea.question.bankCategories==["Аудио / видео","Открытые вопросы"] && !idea.question.issues.isEmpty)
  q.kind="Один из четырёх";q.choices=["A","B","C","D"];q.selectedChoice=1
  let updated=try bank.save(q,assets:["original.mp3":data],existing:idea)
  assert(updated.id==idea.id && bank.entries.count==1 && updated.question.bankCategories==["Аудио / видео","4 варианта"])
  let reload=QuestionBank(root:bank.root);let restored=try reload.record(updated);assert(reload.entries==bank.entries && restored.assets["original.mp3"]==data)
  try bank.setArchived(updated,true);assert(bank.entries[0].archived)
  try bank.setArchived(bank.entries[0],false);assert(!bank.entries[0].archived)
  let studio=Studio(draftURL:root.appendingPathComponent("Draft.workspace"));studio.timer?.invalidate()
  studio.screen = .editor
  try studio.insertBankQuestions([updated]);try studio.insertBankQuestions([updated])
  let a=studio.quiz.rounds[0].questions[1],b=studio.quiz.rounds[0].questions[2]
  assert(a.id != b.id && a.id != q.id && a.media != b.media && a.media != q.media)
  assert(a.questionClip==q.questionClip && a.explanation==q.explanation && a.correctAnswer=="B")
  let insertedData=try Data(contentsOf:studio.asset(a.media)!);assert(insertedData==data)
  let output=root.appendingPathComponent("portable.quiz");try studio.write(to:output)
  let portable=try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:output));assert(portable.assets.count==2)
  studio.quiz.rounds[0].questions[1].text="Changed";let original=try bank.record(updated);assert(original.entry.question.text=="Идея")
  do { _=try bank.save(q,assets:[:]);fatalError("Missing media accepted") } catch {}
  var pairs=Question();pairs.kind="Сопоставление";pairs.matchPairs=[MatchPair(left:"1",right:"A"),MatchPair(left:"2",right:"B")]
  assert(pairs.bankCategories==["Сопоставление"])
  print("PASS: automatic overlapping categories, incomplete ideas, atomic persistence/reload, edits retain ID, archive/restore, missing media rejection, independent quiz IDs/media, portable clips and explanations")
  if CommandLine.arguments.count>2 {
   let result=try SIQImporter.load(URL(fileURLWithPath:CommandLine.arguments[2]));let count=try bank.importSIQ(result);assert(count==97)
   let repeated=try bank.importSIQ(result);assert(repeated==0)
   let split=try SIQImporter.load(URL(fileURLWithPath:CommandLine.arguments[2]),themesAsRounds:true);let regrouped=try bank.importSIQ(split);assert(regrouped==0)
   let restarted=QuestionBank(root:bank.root);assert(restarted.entries.count==98)
   for entry in restarted.entries where entry.originKey != nil { let record=try restarted.record(entry);assert(record.entry.question.bankAssets.allSatisfy { record.assets[$0] != nil }) }
   print("PASS: 97 SIQ questions persisted with media; repeat import and alternate round grouping create zero duplicates")
  }
 }
}

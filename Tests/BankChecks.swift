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
  let brokenURL=bank.root.appendingPathComponent("broken.bankitem");try Data("broken".utf8).write(to:brokenURL)
  let partialReload=QuestionBank(root:bank.root);assert(partialReload.entries.count==1 && partialReload.message.contains("broken.bankitem"))
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
  let beforeMediaImport=bank.entries.count
  do { _=try bank.importQuestions([Question(),q],origin:"test");fatalError("Media import accepted without assets") } catch { assert(error.localizedDescription.contains("не поддерживается")) }
  assert(bank.entries.count==beforeMediaImport)
  let mediaLess=Question();let draft=try bank.saveDraftQuestion(mediaLess,origin:"draft");assert(draft.question.bankAssets.isEmpty)
  do { _=try bank.saveDraftQuestion(q);fatalError("Media draft accepted without assets") } catch { assert(error.localizedDescription.contains("Черновик")) }
  let imported=try bank.importQuestions([mediaLess],origin:"test");assert(imported.added==1)
  var reviewed=mediaLess;reviewed.id=UUID();reviewed.editorialReviewStatus = .reviewed;reviewed.editorialReviewNote="Checked"
  let reviewedImport=try bank.importQuestions([reviewed],origin:"again");assert(reviewedImport.added==0)
  var distinct=mediaLess;distinct.kind="Один из четырёх";distinct.choices=["A","B","C","D"];distinct.selectedChoice=1
  let distinctImport=try bank.importQuestions([distinct],origin:"distinct");assert(distinctImport.added==1)
  var tagged=mediaLess;tagged.tags=["История"]
  let taggedImport=try bank.importQuestions([tagged],origin:"tagged");assert(taggedImport.added==1)
  var sequenceA=Question();sequenceA.kind="Порядок событий";sequenceA.sequenceItems=[SequenceItem(text:"Начало"),SequenceItem(text:"Конец")]
  var sequenceB=sequenceA;sequenceB.id=UUID();sequenceB.sequenceItems=sequenceA.sequenceItems?.map { SequenceItem(text:$0.text) }
  let sequenceImport=try bank.importQuestions([sequenceA,sequenceB],origin:"sequence");assert(sequenceImport.added==1)
  var missing=updated;missing.id=UUID();missing.question.media="gone.mp3"
  let missingRecord=BankRecord(entry:missing,assets:[:]);try JSONEncoder().encode(missingRecord).write(to:bank.root.appendingPathComponent(missing.id.uuidString+".bankitem"))
  let emptyStudio=Studio(draftURL:root.appendingPathComponent("MissingAsset.workspace"));emptyStudio.timer?.invalidate()
  let existingWorkspace=root.appendingPathComponent("Existing.workspace");try FileManager.default.createDirectory(at:existingWorkspace,withIntermediateDirectories:true)
  let sentinel=existingWorkspace.appendingPathComponent("keep.txt");try Data("keep".utf8).write(to:sentinel);emptyStudio.folder=existingWorkspace
  do { _=try emptyStudio.copyBankQuestions([missing]);fatalError("Missing asset copied") } catch { assert(error.localizedDescription.contains("отсутствует медиафайл")) }
  assert(FileManager.default.fileExists(atPath:sentinel.path) && !FileManager.default.fileExists(atPath:existingWorkspace.appendingPathComponent("Media").path))
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

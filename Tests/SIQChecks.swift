struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct SIQChecks {
 @MainActor static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let legacy=try SIQImporter.load(root.appendingPathComponent("legacy.siq"))
  assert(legacy.quiz.rounds.count==1 && legacy.questionCount==1 && legacy.assets.count==2)
  let q=legacy.quiz.rounds[0].questions[0]
  assert(q.text.contains("Question") && !q.text.contains("Explanation") && q.answer=="Answer" && q.acceptedAnswers==["Answer","Alternative"])
  assert(q.explanation!.contains("Explanation") && q.explanation!.contains("Comment") && q.image != nil && q.explanationImage != nil)
  assert(q.hostNotes!.contains("300") && legacy.warnings.contains{ $0.contains("auction") })
  let video=try SIQImporter.load(root.appendingPathComponent("video.siq"))
  assert(video.quiz.rounds[0].questions[0].media != nil && video.assets.values.contains(Data("video".utf8)))
  if let folder=ProcessInfo.processInfo.environment["QUIZ_SIQ_OFFICIAL_FIXTURES"] {
   for file in ["SIGameTest.siq","SIGameTestNew.siq","Pack3_2.siq"] {
    let pack=try SIQImporter.load(URL(fileURLWithPath:folder).appendingPathComponent(file))
    assert(pack.questionCount>0)
    print("PASS: official fixture",file,"questions",pack.questionCount,"assets",pack.assets.count)
   }
  }
  let modern=try SIQImporter.load(root.appendingPathComponent("modern.siq"));let first=modern.quiz.rounds[0].questions[0]
  assert(first.kind=="Один из четырёх" && first.selectedChoice==2 && first.correctAnswer=="Three")
  assert(modern.warnings.contains{ $0.contains("missing.png") } && modern.warnings.contains{ $0.contains("html") })
  assert(modern.quiz.rounds[0].questions[1].issues.contains("Не указан правильный ответ"))
  for file in ["traversal.siq","absolute.siq","duplicate.siq","doctype.siq","badxml.siq","future.siq","link.siq"] {
   do { _=try SIQImporter.load(root.appendingPathComponent(file));fatalError("Unsafe or invalid package accepted: "+file) } catch {}
  }
  print("PASS: legacy marker/URI-encoded media, answer alternatives, modern multiple-choice, missing/external/HTML warnings, archive path/link/collision protection, DTD and malformed XML rejection")
  if CommandLine.arguments.count>2 {
   let source=URL(fileURLWithPath:CommandLine.arguments[2]);let before=try Data(contentsOf:source)
   let actual=try SIQImporter.load(source)
   assert(actual.originalRounds==4 && actual.quiz.rounds.count==4 && actual.themes==25 && actual.questionCount==97)
   assert(!actual.warnings.contains{ $0.contains("не найдено вложение") })
   let many=actual.quiz.rounds[0].questions[5];assert(many.images(answer:false).count==5)
   assert(actual.quiz.rounds[0].questions[13].media != nil)
   for r in actual.quiz.rounds { for q in r.questions { assert(q.issues.isEmpty && !q.answer.isEmpty) } }
   for r in actual.quiz.rounds { for q in r.questions { for name in q.images(answer:false)+q.images(answer:true) { assert(actual.assets[name] != nil) } } }
   let split=try SIQImporter.load(source,themesAsRounds:true)
   assert(split.quiz.rounds.count==25 && split.questionCount==97)
   let studio=Studio(draftURL:root.appendingPathComponent("draft.quiz"));studio.timer?.invalidate()
   let output=root.appendingPathComponent("converted.quiz");try studio.saveSIQImport(actual,to:output)
   assert(studio.screen == .editor && studio.quiz.rounds.count==4 && studio.referencedAssets.count==actual.assets.count)
   let linked=studio.quiz.rounds.flatMap(\.questions).compactMap(\.bankEntryID)
   assert(linked.count==97 && Set(linked).count==97 && studio.questionBank.entries.count==97)
   assert(studio.questionBank.entries.allSatisfy { ($0.history ?? []).count==1 && !($0.history ?? [])[0].played })
   let archive=try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:output))
   assert(archive.assets==actual.assets && archive.quiz.rounds[0].questions[5].imageGallery?.count==4 && archive.quiz.importNotes != nil)
   let after=try Data(contentsOf:source);assert(after==before)
   if CommandLine.arguments.count>3 { try FileManager.default.copyItem(at:output,to:URL(fileURLWithPath:CommandLine.arguments[3])) }
   print("PASS: real user pack 4 rounds / 25 themes / 97 questions; all referenced media resolved, galleries retained, theme split, portable quiz and source unchanged; assets",actual.assets.count,"warnings",actual.warnings.count)
  }
 }
}

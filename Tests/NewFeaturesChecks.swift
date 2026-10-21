struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct NewFeaturesChecks {
 @MainActor static func wait(_ condition: () -> Bool) async throws {
  for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds:50_000_000) }
  throw SIQError(message:"HTTP room timeout")
 }
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  var numeric=Question();numeric.text="Сколько?";numeric.kind="Числовой ответ";numeric.numericAnswer=100;numeric.numericTolerance=5
  assert(numeric.issues.isEmpty && numeric.correctAnswer=="100 ± 5")
  let lower=try numeric.gradeExtra(["text":"95"]),upper=try numeric.gradeExtra(["text":"105"]),outside=try numeric.gradeExtra(["text":"105,1"])
  assert(lower?.points==1 && upper?.points==1 && outside?.points==0)
  do { _=try numeric.gradeExtra(["text":"NaN"]);fatalError("Nonfinite accepted") } catch {}
  var multiple=Question();multiple.text="Чётные";multiple.kind="Несколько вариантов";multiple.choices=["2","3","4","5"];multiple.correctChoices=[0,2]
  let exact=try multiple.gradeExtra(["choices":[2,0]]),partial=try multiple.gradeExtra(["choices":[0]]),extra=try multiple.gradeExtra(["choices":[0,1,2]])
  assert(multiple.issues.isEmpty && exact?.points==1 && partial?.points==0 && extra?.points==0)
  do { _=try multiple.gradeExtra(["choices":[0,0]]);fatalError("Duplicate accepted") } catch {}
  var ordered=Question();ordered.text="Порядок";ordered.kind="Порядок событий";ordered.sequenceItems=[SequenceItem(text:"Сначала"),SequenceItem(text:"Потом"),SequenceItem(text:"В конце")]
  let order=ordered.sequenceItems!.map { item in ordered.displayedSequence.firstIndex { $0.id==item.id }! }
  let orderGrade=try ordered.gradeExtra(["order":order]);let wrongOrder=try ordered.gradeExtra(["order":Array(order.reversed())])
  assert(ordered.issues.isEmpty && orderGrade?.points==1 && wrongOrder?.points==0 && ordered.displayedSequence==ordered.displayedSequence && order != [0,1,2])
  do { _=try ordered.gradeExtra(["order":[0,0,1]]);fatalError("Duplicate order accepted") } catch {}
  let roundtrip=try JSONDecoder().decode([Question].self,from:JSONEncoder().encode([numeric,multiple,ordered]));assert(roundtrip==[numeric,multiple,ordered])
  var masked=numeric;masked.image="photo.jpg";masked.questionImageMasks=[ImageMask(x:0.1,y:0.2,width:0.3,height:0.4)];masked.answerImageMasks=[]
  let maskedRoundtrip=try JSONDecoder().decode(Question.self,from:JSONEncoder().encode(masked));assert(maskedRoundtrip.questionImageMasks==masked.questionImageMasks && maskedRoundtrip.answerImageMasks==[])
  var wager=numeric;wager.correctPoints=1;wager.wrongPoints=0;wager.wagerEnabled=true;wager.wagerCorrectPoints=2;wager.wagerWrongPoints = -2
  assert(wager.awardedPoints(correct:true,wagered:false)==1 && wager.awardedPoints(correct:false,wagered:false)==0 && wager.awardedPoints(correct:true,wagered:true)==2 && wager.awardedPoints(correct:false,wagered:true) == -2)
  var category=Question();category.text="Распределите";category.kind="Категоризация";category.partialPoints=0.5;category.categoryGroups=["Животные","Растения"];category.categoryItems=[CategoryItem(text:"Кот",category:0),CategoryItem(text:"Дуб",category:1),CategoryItem(text:"Пёс",category:0)]
  assert(category.extraAnswer == "Кот — Животные\nДуб — Растения\nПёс — Животные")
  var incompleteCategory=category;incompleteCategory.categoryGroups=nil
  assert(incompleteCategory.extraAnswer == "Кот — \nДуб — \nПёс — ")
  incompleteCategory.categoryGroups=[]
  assert(incompleteCategory.extraAnswer == "Кот — \nДуб — \nПёс — ")
  incompleteCategory.categoryGroups=["Животные"]
  assert(incompleteCategory.extraAnswer == "Кот — Животные\nДуб — \nПёс — Животные")
  let categoryOrder=category.displayedCategoryItems,categoryExact=Dictionary(uniqueKeysWithValues:categoryOrder.enumerated().map{(String($0.offset),$0.element.category)})
  let categoryExactGrade=try category.gradeExtra(["categories":categoryExact]);assert(category.issues.isEmpty && categoryExactGrade?.points==1)
  var categoryPartial=categoryExact;categoryPartial["0"]=categoryPartial["0"]==0 ? 1:0;let categoryPartialGrade=try category.gradeExtra(["categories":categoryPartial]);assert(categoryPartialGrade?.points==2)
  let roster=TeamRoster(url:root.appendingPathComponent("Teams.json"));roster.add(["Знатоки","знатоки","Эрудиты"]);assert(roster.teams.count==2 && TeamRoster(url:roster.url).teams.count==2)
  var blockRound=Round(title:"С блоками",questions:[numeric]);blockRound.blocks=[PresentationBlock(kind:"Голосование",title:"Выберите",text:"Тема",seconds:10,beforeQuestion:0,options:["Кино","Музыка"])]
  let blockRoundtrip=try JSONDecoder().decode(Round.self,from:JSONEncoder().encode(blockRound));assert(blockRoundtrip.blocks==blockRound.blocks)
  print("PASS: new-type validation, exact multiple/order grading, numeric inclusive tolerance and nonfinite rejection, portable metadata")
  let csv=try QuestionTextImport.file(root.appendingPathComponent("questions.csv"));assert(csv.rows.count==3)
  assert(csv.rows[0].question.kind=="Числовой ответ" && csv.rows[0].question.numericTolerance==2 && csv.rows[0].question.explanation!.contains("\n"))
  assert(csv.rows[1].question.correctChoices==[0,2] && csv.rows[2].question.sequenceItems?.count==3 && csv.rows.allSatisfy(\.selected))
  let xlsx=try QuestionTextImport.file(root.appendingPathComponent("questions.xlsx"));assert(xlsx.rows.count==3 && xlsx.rows[0].question.text=="Сколько планет?" && xlsx.rows[1].question.correctChoices==[0,2])
  assert(!xlsx.rows[2].selected && xlsx.rows[2].warnings.contains { $0.contains("формулу") } && xlsx.rows[2].question.siqReviewRequired==true)
  let semicolon=try QuestionTextImport.parse("Вопрос;Ответ;Объяснение\n\"Вопрос; с разделителем\";Ответ;\"Пояснение с \"\"кавычками\"\"\"")
  assert(semicolon.rows[0].question.text=="Вопрос; с разделителем" && semicolon.rows[0].question.explanation=="Пояснение с \"кавычками\"")
  let blocks=try QuestionTextImport.parse("Вопрос: Один\nПродолжение\nОтвет: Ответ\nОбъяснение: Почему\n\nВопрос: Два\nОтвет: Второй")
  assert(blocks.rows.count==2 && blocks.rows[0].question.text.contains("Продолжение"))
  let dash=try QuestionTextImport.parse("Что, где? — Там — Потому что");assert(dash.rows.count==1 && dash.rows[0].question.answer=="Там")
  do { _=try QuestionTextImport.parse("Вопрос,Ответ\n\"сломано");fatalError("Malformed CSV accepted") } catch {}
  do { _=try QuestionTextImport.file(root.appendingPathComponent("unsafe.xlsx"));fatalError("Traversal accepted") } catch {}
  print("PASS: CSV/BOM/multiline/escaped quotes, semicolon and labelled/free text, XLSX shared/inline strings, formulas require review, malformed CSV and unsafe ZIP rejection")
  let app=Studio(draftURL:root.appendingPathComponent("Draft.workspace"));app.timer?.invalidate()
  let imported=try app.questionBank.importQuestions(csv.rows.map(\.question),origin:"CSV");assert(imported.added==3)
  let repeated=try app.questionBank.importQuestions(csv.rows.map(\.question),origin:"CSV again");assert(repeated.added==0)
  let duplicate=try app.questionBank.importQuestions([numeric,numeric],origin:"Duplicates");assert(duplicate.entries.count==1 && duplicate.added==1)
  var archived=try app.questionBank.save(multiple,assets:[:]);try app.questionBank.setArchived(archived,true);archived.archived=true
  let used=try app.questionBank.save(ordered,assets:[:]);try app.questionBank.recordUse(questionIDs:[used.id],quizID:UUID(),title:"Already used",played:true)
  var rules=QuizAssemblyRules();rules.rounds=1;rules.perRound=2;rules.unusedOnly=true
  let eligible=rules.candidates(app.questionBank.entries);assert(!eligible.contains { $0.id==archived.id || $0.id==used.id })
  let picked=try rules.select(app.questionBank.entries);assert(picked.count==2 && Set(picked.map(\.id)).count==2)
  let original=app.quiz;rules.perRound=50
  do { _=try rules.select(app.questionBank.entries);fatalError("Shortage accepted") } catch {}
  assert(app.quiz==original);rules.perRound=2
  try app.assembleQuiz(picked,rules:rules,title:"Из банка");assert(app.quiz.rounds.count==1 && app.quiz.rounds[0].questions.count==2 && app.quiz.rounds[0].questions.allSatisfy { $0.bankEntryID != nil })
  assert(app.questionBank.entries.filter { picked.map(\.id).contains($0.id) }.allSatisfy { ($0.history ?? []).isEmpty })
  let file=root.appendingPathComponent("Generated.quiz");try app.write(to:file);let saved=try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:file));assert(saved.quiz.rounds[0].questions.count==2)
  print("PASS: repeat import deduplication, no repeated bank IDs, archived/used exclusion, shortage keeps source quiz, independent assembled questions, history only after save")
  numeric.wagerEnabled=true;numeric.wagerCorrectPoints=2;numeric.wagerWrongPoints = -2
  let pollBlock=PresentationBlock(kind:"Голосование",title:"Тема",text:"Выберите",seconds:0,beforeQuestion:0,options:["Кино","Музыка"])
  app.quiz.rounds=[Round(title:"Новые типы",questions:[numeric,multiple,ordered],blocks:[pollBlock])];app.quiz.teams=[];app.phoneMode=true;app.phoneRoom.start()
  try await wait { app.phoneRoom.running };app.phoneRoom.selectedHost="127.0.0.1"
  let base="http://127.0.0.1:\(app.phoneRoom.port)/\(app.phoneRoom.roomKey)"
  func call(_ endpoint: String,token: String="",body:[String:Any]?=nil) async throws -> (Int,[String:Any]) {
   var req=URLRequest(url:URL(string:base+endpoint)!);req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
   if let body { req.httpMethod="POST";req.httpBody=try JSONSerialization.data(withJSONObject:body);req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
   let (data,response)=try await URLSession.shared.data(for:req);return ((response as! HTTPURLResponse).statusCode,(try JSONSerialization.jsonObject(with:data)) as! [String:Any])
  }
  let joined=try await call("/join",body:["name":"Тест","device":String(repeating:"a",count:40)]);let token=joined.1["token"] as! String
  app.beginGame();assert(app.playing)
  app.jump(to:app.steps.firstIndex{$0.kind == .block}!);app.paused=false;let blockState=try await call("/state",token:token);assert(blockState.1["blockKind"] as? String=="Голосование")
  let blockResult=try await call("/block",token:token,body:["block":pollBlock.id.uuidString,"value":"Кино"]);assert(blockResult.0==200 && app.phoneRoom.blockResponses[pollBlock.id]?[app.quiz.teams[0].id]=="Кино")
  for (qi,payload) in [["text":"104,9","wager":true],["choices":[0,2]],["order":order]].enumerated() {
   app.jump(to:app.steps.firstIndex { $0.kind == .question && $0.question==qi }!);app.paused=false
   let state=try await call("/state",token:token);let publicJSON=String(data:try JSONSerialization.data(withJSONObject:state.1),encoding:.utf8)!
   assert(!publicJSON.contains("numericAnswer") && !publicJSON.contains("correctChoices") && state.1["correct"]==nil)
   if qi==2 { assert(state.1["sequence"] as? [String] == ordered.displayedSequence.map(\.text));let bad=try await call("/answer",token:token,body:["question":state.1["question"]!,"answer":["order":[0,0,1]]]);assert(bad.0==400) }
   let result=try await call("/answer",token:token,body:["question":state.1["question"]!,"answer":payload]);assert(result.0==200)
  }
  assert(app.phoneRoom.answers.count==3 && app.phoneRoom.answers.map(\.points)==[2,1,1] && app.quiz.teams[0].total==4)
  app.stop();print("PASS: local HTTP grades new types and wager, accepts interactive block, rejects malformed order, hides grading metadata; team total is 4")
 }
}

import SwiftUI
import UniformTypeIdentifiers

struct CategoryItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var text = ""
    var category = 0
}

struct PresentationBlock: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind = "Слайд"
    var title = ""
    var text = ""
    var image: String? = nil
    var seconds = 0
    var beforeQuestion = 0
    var options: [String]? = nil
    static let kinds = ["Слайд","Объявление","Голосование","Облако слов","Выбор темы","Случайная команда","Партнёрская заставка"]
}
func selectedRandomTeam(_ block:PresentationBlock,teams:[Team]) -> String {
    guard !teams.isEmpty else { return block.title }
    let index=block.id.uuidString.utf8.reduce(0) { ($0+Int($1)) % teams.count }
    return teams[index].name
}

extension Question {
    var baseCorrectPoints: Double { correctPoints ?? 1 }
    var baseWrongPoints: Double { wrongPoints ?? 0 }
    func awardedPoints(correct: Bool,wagered: Bool) -> Double {
        wagered && wagerEnabled == true ? (correct ? (wagerCorrectPoints ?? 2) : (wagerWrongPoints ?? -2)) : (correct ? baseCorrectPoints : baseWrongPoints)
    }
    func awardedPoints(grade:Int,wagered:Bool) -> Double { grade == 1 ? awardedPoints(correct:true,wagered:wagered) : grade == 2 ? (partialPoints ?? baseWrongPoints) : awardedPoints(correct:false,wagered:wagered) }
    var scoringSummary: String {
        var result = "Верно: \(scoreText(baseCorrectPoints)) · неверно: \(scoreText(baseWrongPoints))"
        if let partialPoints { result += " · частично: \(scoreText(partialPoints))" }
        if wagerEnabled == true { result += " · ставка: +\(scoreText(wagerCorrectPoints ?? 2)) / \(scoreText(wagerWrongPoints ?? -2))" }
        return result
    }
    var displayedCategoryItems: [CategoryItem] {
        let source = categoryItems ?? []
        var result = source.sorted { $0.id.uuidString < $1.id.uuidString }
        if result.count > 1 && result == source { result.append(result.removeFirst()) }
        return result
    }
}

struct ScoringRulesEditor: View {
    @Binding var question: Question
    var body: some View {
        DisclosureGroup("Баллы и ставка") {
            VStack(alignment:.leading,spacing:10) {
                VStack(alignment:.leading,spacing:8) {
                    number("За правильный ответ",value:Binding(get:{ question.correctPoints ?? 1 },set:{ question.correctPoints=$0 }))
                    number("За неправильный",value:Binding(get:{ question.wrongPoints ?? 0 },set:{ question.wrongPoints=$0 }))
                    number("За частичный",value:Binding(get:{ question.partialPoints ?? 0 },set:{ question.partialPoints=$0 }))
                }
                Toggle("Разрешить команде сделать ставку",isOn:Binding(get:{ question.wagerEnabled ?? false },set:{ question.wagerEnabled=$0 }))
                if question.wagerEnabled == true {
                    VStack(alignment:.leading,spacing:8) {
                        number("Верно со ставкой",value:Binding(get:{ question.wagerCorrectPoints ?? 2 },set:{ question.wagerCorrectPoints=$0 }))
                        number("Ошибка со ставкой",value:Binding(get:{ question.wagerWrongPoints ?? -2 },set:{ question.wagerWrongPoints=$0 }))
                    }
                    Text("Команда выбирает ставку до отправки ответа. Баллы могут стать отрицательными.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top,8)
        }
    }
    private func number(_ title:String,value:Binding<Double>) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title,value:value,format:.number.precision(.fractionLength(0...2))).frame(maxWidth:.infinity)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct CategoryQuestionEditor: View {
    @Binding var question: Question
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Создайте категории и укажите правильную категорию каждого элемента.").font(.caption).foregroundStyle(.secondary)
            ForEach((question.categoryGroups ?? []).indices,id:\.self) { i in
                HStack { TextField("Категория \(i+1)",text:Binding(get:{ question.categoryGroups?[i] ?? "" },set:{ question.categoryGroups?[i]=$0 })); Button("Удалить") { removeGroup(i) }.disabled((question.categoryGroups?.count ?? 0)<=2) }
            }
            Button("Добавить категорию") { question.categoryGroups=(question.categoryGroups ?? [])+[""] }.disabled((question.categoryGroups?.count ?? 0)>=6)
            Divider()
            ForEach(Array((question.categoryItems ?? []).enumerated()),id:\.element.id) { i,item in
                HStack {
                    TextField("Элемент \(i+1)",text:Binding(get:{ question.categoryItems?[i].text ?? "" },set:{ question.categoryItems?[i].text=$0 }))
                    Picker("Категория",selection:Binding(get:{ question.categoryItems?[i].category ?? 0 },set:{ question.categoryItems?[i].category=$0 })) { ForEach((question.categoryGroups ?? []).indices,id:\.self) { n in Text(question.categoryGroups?[n].isEmpty == false ? question.categoryGroups![n] : "Категория \(n+1)").tag(n) } }.frame(width:220)
                    Button("Удалить") { question.categoryItems?.remove(at:i) }.disabled((question.categoryItems?.count ?? 0)<=2)
                }
            }
            Button("Добавить элемент") { question.categoryItems=(question.categoryItems ?? [])+[CategoryItem()] }.disabled((question.categoryItems?.count ?? 0)>=20)
        }
    }
    private func removeGroup(_ index:Int) {
        question.categoryGroups?.remove(at:index)
        for i in (question.categoryItems ?? []).indices { if question.categoryItems![i].category == index { question.categoryItems![i].category=0 } else if question.categoryItems![i].category > index { question.categoryItems![i].category -= 1 } }
    }
}

final class TeamRoster: ObservableObject {
    @Published var teams: [String] = []
    let url: URL
    init(url:URL) { self.url=url; if let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode([String].self,from:data) { teams=saved } }
    func add(_ names:[String]) { for raw in names { let name=raw.trimmingCharacters(in:.whitespacesAndNewlines); if !name.isEmpty && !teams.contains(where:{ $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) { teams.append(name) } }; teams.sort { $0.localizedStandardCompare($1) == .orderedAscending }; save() }
    func remove(_ name:String) { teams.removeAll{$0==name};save() }
    private func save() { try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); if let data=try? JSONEncoder().encode(teams) { try? data.write(to:url,options:.atomic) } }
}

struct PresentationBlocksEditor: View {
    @ObservedObject var studio: Studio
    @Binding var round: Round
    var body: some View {
        DisclosureGroup("Вставные блоки (\((round.blocks ?? []).count))") {
            VStack(alignment:.leading,spacing:10) {
                Text("Блок появляется перед выбранным вопросом и не начисляет баллы.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array((round.blocks ?? []).enumerated()),id:\.element.id) { i,_ in
                    GroupBox {
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Picker("Тип",selection:binding(i,\.kind)) { ForEach(PresentationBlock.kinds,id:\.self) { Text($0) } }.frame(width:230)
                                Picker("Позиция",selection:binding(i,\.beforeQuestion)) { ForEach(0...round.questions.count,id:\.self) { n in Text(n<round.questions.count ? "Перед вопросом \(n+1)" : "После вопросов").tag(n) } }.frame(width:210)
                                Stepper("\(round.blocks?[i].seconds ?? 0) сек",value:binding(i,\.seconds),in:0...600,step:5)
                                Spacer();Button("Удалить",role:.destructive) { round.blocks?.remove(at:i) }
                            }
                            TextField("Заголовок",text:binding(i,\.title))
                            TextEditor(text:binding(i,\.text)).frame(height:60)
                            HStack { Button(round.blocks?[i].image == nil ? "Добавить изображение" : "Заменить изображение") { attachImage(i) };if round.blocks?[i].image != nil { Button("Убрать") { round.blocks?[i].image=nil } } }
                            if ["Голосование","Выбор темы"].contains(round.blocks?[i].kind ?? "") { TextField("Варианты через ;",text:Binding(get:{ (round.blocks?[i].options ?? []).joined(separator:"; ") },set:{ round.blocks?[i].options=$0.split(separator:";").map{String($0).trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty} })) }
                        }.padding(6)
                    }
                }
                Button("Добавить блок",systemImage:"rectangle.on.rectangle.angled") { round.blocks=(round.blocks ?? [])+[PresentationBlock(beforeQuestion:round.questions.count)] }
            }.padding(.top,8)
        }
    }
    private func binding<T>(_ index:Int,_ keyPath:WritableKeyPath<PresentationBlock,T>) -> Binding<T> {
        Binding(get:{ round.blocks![index][keyPath:keyPath] },set:{ round.blocks![index][keyPath:keyPath]=$0 })
    }
    private func attachImage(_ index:Int) { let panel=NSOpenPanel();panel.allowedContentTypes=[.image];guard panel.runModal() == .OK,let source=panel.url else{return};do{let root=studio.folder ?? studio.draft,dir=root.appendingPathComponent("Media");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);let name=UUID().uuidString+"."+source.pathExtension;try FileManager.default.copyItem(at:source,to:dir.appendingPathComponent(name));studio.folder=root;round.blocks?[index].image=name}catch{studio.status=error.localizedDescription} }
}

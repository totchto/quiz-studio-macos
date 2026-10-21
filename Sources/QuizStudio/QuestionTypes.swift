import SwiftUI

struct SequenceItem: Codable, Equatable, Identifiable { var id = UUID(); var text = "" }
extension Question {
    static let kinds = ["Открытый вопрос","Один из четырёх","Сопоставление","Числовой ответ","Порядок событий","Несколько вариантов","Категоризация"]
    var isChoiceQuestion: Bool { kind == "Один из четырёх" || kind == "Несколько вариантов" }
    var extraAnswer: String? {
        switch kind {
        case "Числовой ответ":
            guard let value = numericAnswer else { return "" }
            let tolerance = numericTolerance ?? 0
            return Self.numberText(value)+(tolerance > 0 ? " ± "+Self.numberText(tolerance) : "")
        case "Порядок событий": return (sequenceItems ?? []).enumerated().map { "\($0.offset+1). \($0.element.text)" }.joined(separator:"\n")
        case "Несколько вариантов": return (correctChoices ?? []).sorted().compactMap { choices.indices.contains($0) ? choices[$0] : nil }.joined(separator:"; ")
        case "Категоризация":
            let groups = categoryGroups ?? []
            return (categoryItems ?? []).map { item in
                let name = groups.indices.contains(item.category) ? groups[item.category] : ""
                return item.text + " — " + name
            }.joined(separator:"\n")
        default: return nil
        }
    }
    static func number(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:",",with:".")
        guard !clean.isEmpty, let n = Double(clean), n.isFinite else { return nil }; return n
    }
    static func numberText(_ n: Double) -> String { n.isFinite && abs(n) < 1e15 && n.rounded() == n ? String(format:"%.0f",n) : String(n) }
    var extraIssues: [String]? {
        switch kind {
        case "Числовой ответ":
            var issues: [String] = []
            if numericAnswer?.isFinite != true { issues.append("Укажите числовой ответ") }
            if let tolerance = numericTolerance, !tolerance.isFinite || tolerance < 0 { issues.append("Погрешность должна быть неотрицательной") }
            return issues
        case "Порядок событий":
            let items = sequenceItems ?? []
            return (items.count < 2 || items.count > 12 ? ["Добавьте от 2 до 12 событий"] : []) + (items.contains { $0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ? ["Заполните все события"] : []) + (Set(items.map { $0.text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }).count != items.count ? ["События должны различаться"] : [])
        case "Несколько вариантов":
            let selected = correctChoices ?? []
            return (choices.count < 2 || choices.count > 8 || choices.contains { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ? ["Заполните от 2 до 8 вариантов"] : []) + (selected.isEmpty || Set(selected).count != selected.count || selected.contains { !choices.indices.contains($0) } ? ["Отметьте правильные варианты"] : [])
        case "Категоризация":
            let groups=categoryGroups ?? [],items=categoryItems ?? []
            return (groups.count < 2 || groups.count > 6 || groups.contains { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ? ["Заполните от 2 до 6 категорий"] : []) + (items.count < 2 || items.count > 20 || items.contains { $0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !groups.indices.contains($0.category) } ? ["Заполните элементы и их категории"] : [])
        default: return nil
        }
    }
    // Stable across TV, phone reloads and recovery; the displayed order never contains grading metadata.
    var displayedSequence: [SequenceItem] {
        let correct = sequenceItems ?? []
        var shuffled = correct.sorted { $0.id.uuidString < $1.id.uuidString }
        if shuffled.count > 1 && shuffled == correct { shuffled.append(shuffled.removeFirst()) }
        return shuffled
    }
    func gradeExtra(_ payload: [String:Any]) throws -> (display:String,points:Int)? {
        switch kind {
        case "Числовой ответ":
            guard let text = payload["text"] as? String, text.count <= 100, let actual = Self.number(text), let expected = numericAnswer, expected.isFinite else { throw SIQError(message:"Введите корректное число") }
            let tolerance = numericTolerance ?? 0
            let epsilon = tolerance > 0 ? max(1,abs(actual),abs(expected))*Double.ulpOfOne*4 : 0
            return (text,abs(actual-expected) <= tolerance+epsilon ? 1 : 0)
        case "Несколько вариантов":
            guard let selected = payload["choices"] as? [Int], !selected.isEmpty, Set(selected).count == selected.count, selected.allSatisfy({ choices.indices.contains($0) }) else { throw SIQError(message:"Выберите варианты ответа") }
            let exact=Set(selected) == Set(correctChoices ?? []),partial = !Set(selected).intersection(Set(correctChoices ?? [])).isEmpty
            return (selected.sorted().map { choices[$0] }.joined(separator:"; "),exact ? 1 : partial && partialPoints != nil ? 2 : 0)
        case "Порядок событий":
            let displayed = displayedSequence
            guard let order = payload["order"] as? [Int], order.count == displayed.count, Set(order).count == displayed.count, order.allSatisfy({ displayed.indices.contains($0) }) else { throw SIQError(message:"Укажите порядок всех событий без повторений") }
            let chosen = order.map { displayed[$0] }
            let expected=sequenceItems ?? [],exact=chosen.map(\.id)==expected.map(\.id),partial=zip(chosen,expected).contains{$0.id==$1.id}
            return (chosen.enumerated().map { "\($0.offset+1). \($0.element.text)" }.joined(separator:"\n"),exact ? 1 : partial && partialPoints != nil ? 2 : 0)
        case "Категоризация":
            let shown=displayedCategoryItems
            guard let raw=payload["categories"] as? [String:Any],raw.count==shown.count else { throw SIQError(message:"Распределите все элементы") }
            var chosen:[Int]=[]
            for i in shown.indices { guard let value=raw[String(i)] as? Int,(categoryGroups ?? []).indices.contains(value) else { throw SIQError(message:"Распределите все элементы") };chosen.append(value) }
            let count=zip(shown,chosen).filter{$0.category==$1}.count,correct=count==shown.count
            let display=zip(shown,chosen).map{$0.text+" — "+(categoryGroups ?? [])[$1]}.joined(separator:"\n")
            return (display,correct ? 1 : count>0 && partialPoints != nil ? 2 : 0)
        default: return nil
        }
    }
}
struct ExtraQuestionFields: View {
    @Binding var question: Question
    @State private var number = ""
    @State private var tolerance = ""
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if question.kind == "Числовой ответ" {
                HStack {
                    TextField("Правильное число",text:$number).onChange(of:number) { _,text in question.numericAnswer = Question.number(text) }
                    TextField("Допустимая погрешность ±",text:$tolerance).onChange(of:tolerance) { _,text in question.numericTolerance = text.isEmpty ? 0 : Question.number(text) ?? -1 }
                }
                Text("При погрешности 2 и ответе 10 засчитываются числа от 8 до 12 включительно. Ноль — точное совпадение.").font(.caption).foregroundStyle(.secondary)
            } else if question.kind == "Несколько вариантов" {
                Text("Отметьте все правильные варианты. Один балл — за полный набор без лишних вариантов.").font(.caption)
                ForEach(question.choices.indices,id:\.self) { i in
                    HStack {
                        Toggle("Верный",isOn:Binding(get:{ (question.correctChoices ?? []).contains(i) },set:{ value in var selected = Set(question.correctChoices ?? []); if value { selected.insert(i) } else { selected.remove(i) }; question.correctChoices = selected.sorted() })).labelsHidden()
                        TextField("Вариант \(i+1)",text:$question.choices[i])
                        Button("Убрать") { question.choices.remove(at:i); question.correctChoices = (question.correctChoices ?? []).filter { $0 != i }.map { $0 > i ? $0-1 : $0 } }.disabled(question.choices.count <= 2)
                    }
                }
                Button("Добавить вариант") { question.choices.append("") }.disabled(question.choices.count >= 8)
            } else if question.kind == "Порядок событий" {
                Text("Заполните события в правильном порядке. В игре они будут перемешаны. Балл — только за полный правильный порядок.").font(.caption)
                ForEach(Array((question.sequenceItems ?? []).enumerated()),id:\.element.id) { i,item in
                    HStack {
                        Text("\(i+1).")
                        TextField("Событие",text:Binding(get:{ question.sequenceItems?.first { $0.id == item.id }?.text ?? "" },set:{ value in if let index = question.sequenceItems?.firstIndex(where:{ $0.id == item.id }) { question.sequenceItems?[index].text = value } }))
                        Button("↑") { question.sequenceItems?.swapAt(i,i-1) }.disabled(i == 0)
                        Button("↓") { question.sequenceItems?.swapAt(i,i+1) }.disabled(i == (question.sequenceItems?.count ?? 0)-1)
                        Button("Убрать") { question.sequenceItems?.removeAll { $0.id == item.id } }.disabled((question.sequenceItems?.count ?? 0) <= 2)
                    }
                }
                Button("Добавить событие") { question.sequenceItems = (question.sequenceItems ?? [])+[SequenceItem()] }.disabled((question.sequenceItems?.count ?? 0) >= 12)
            } else if question.kind == "Категоризация" {
                CategoryQuestionEditor(question:$question)
            }
        }.onAppear { number = question.numericAnswer.map(Question.numberText) ?? ""; tolerance = question.numericTolerance.map(Question.numberText) ?? "0" }
    }
}

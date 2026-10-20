import SwiftUI
import AppKit

struct PhoneJoinScreen: View {
    @ObservedObject var room: PhoneRoom
    var body: some View {
        ZStack {
            Color(red:0.07,green:0.07,blue:0.18)
            VStack(spacing:22) {
                Text("Подключайтесь к квизу").font(.system(size:48,weight:.bold)).foregroundStyle(.white)
                if let qr = room.qrImage { Image(nsImage:qr).interpolation(.none).resizable().scaledToFit().frame(width:320,height:320).padding(18).background(.white,in:RoundedRectangle(cornerRadius:20)) }
                Text("Один телефон на команду · общая Wi-Fi-сеть").font(.title2).foregroundStyle(.white)
                Text(room.address ?? "Ожидаем подключения к сети…").font(.system(size:18,design:.monospaced)).foregroundStyle(.white.opacity(0.7))
                Text("Подключилось команд: \(room.joinedTeams.count)").font(.title2).foregroundStyle(.orange)
            }.padding(40)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
struct PhoneLobby: View {
    @ObservedObject var studio: Studio
    @ObservedObject var room: PhoneRoom
    var body: some View {
        GroupBox("Локальная комната · один телефон на команду") {
            VStack(alignment:.leading,spacing:12) {
                Text("Mac и телефоны должны быть в одной Wi-Fi-сети. Интернет не нужен. Если сеть заведения изолирует устройства, используйте отдельный роутер.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if !room.running {
                        Button("Открыть комнату и QR-код") { room.start() }.disabled(room.starting)
                    } else {
                        Button("Показать QR на ТВ") { studio.showTV() }
                        Button("Обновить адреса") { room.refreshHosts() }
                        Button("Закрыть комнату") { room.stop(); studio.tv?.close(); studio.tv = nil }
                    }
                    if room.starting { ProgressView().controlSize(.small) }
                }
                Text(room.message).font(.caption).foregroundStyle(.secondary)
                if room.running {
                    HStack(alignment:.top,spacing:20) {
                        if let qr = room.qrImage { Image(nsImage:qr).interpolation(.none).resizable().scaledToFit().frame(width:170,height:170).padding(8).background(.white,in:RoundedRectangle(cornerRadius:12)) }
                        VStack(alignment:.leading,spacing:8) {
                            if room.hosts.count > 1 { Picker("Адрес сети",selection:$room.selectedHost) { ForEach(room.hosts,id:\.self) { Text($0).tag($0) } } }
                            if let address = room.address {
                                Text(address).font(.caption.monospaced()).textSelection(.enabled)
                                Button("Скопировать ссылку") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address,forType:.string) }
                            }
                            Text("Подключилось: \(room.joinedTeams.count)").bold()
                            ForEach(room.joinedTeams) { team in Label(team.name,systemImage:"iphone") }
                        }
                    }
                }
                Text("При старте участвуют только подключившиеся команды. После старта новая регистрация закрывается; ранее подключённые телефоны возвращаются автоматически в том же браузере.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}
struct PhoneAnswerReview: View {
    @ObservedObject var studio: Studio
    @ObservedObject var room: PhoneRoom
    @Environment(\.dismiss) var dismiss
    var displayed: [PhoneAnswer] {
        let through = studio.step?.round ?? studio.quiz.rounds.count-1
        let ids = Set(studio.quiz.rounds.prefix(through+1).map(\.id))
        return room.answers.filter { ids.contains($0.roundID) }.sorted { a,b in
            if (a.points == nil) != (b.points == nil) { return a.points == nil }
            return a.id < b.id
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("Ответы с телефонов").font(.title.bold()); Spacer(); Button("Готово") { dismiss() } }
            Text("Формализованные ответы проверяются автоматически по правилам вопроса. Свободный ответ с иной формулировкой нужно подтвердить. Можно засчитать его полностью, частично (если задан частичный балл) или отклонить; сумма пересчитается сразу.").font(.caption).foregroundStyle(.secondary)
            if displayed.isEmpty { Text("Пока нет отправленных ответов") }
            List(displayed) { answer in
                VStack(alignment:.leading,spacing:8) {
                    let question=studio.quiz.rounds.flatMap(\.questions).first(where: { $0.id == answer.questionID })
                    Text(studio.quiz.teams.first { $0.id == answer.teamID }?.name ?? "Команда").bold()
                    if let q = question {
                        Text(q.text).foregroundStyle(.secondary)
                        Text("Правильный ответ: " + q.correctAnswer).font(.caption)
                    }
                    Text(answer.display).textSelection(.enabled)
                    HStack {
                        Text(answer.points.map { "\($0) балл" } ?? "Нужна проверка").foregroundStyle(answer.points == nil ? .orange : .secondary)
                        Spacer()
                        Button("Засчитать · \(scoreText(question?.baseCorrectPoints ?? 1))") { room.grade(answer.id,points:1) }
                        if let partial=question?.partialPoints { Button("Частично · \(scoreText(partial))") { room.grade(answer.id,points:2) } }
                        Button("Не засчитать · \(scoreText(question?.baseWrongPoints ?? 0))") { room.grade(answer.id,points:0) }
                    }
                }.padding(.vertical,8)
            }
        }.padding(24).frame(width:720,height:580)
        .onAppear {
            if studio.step?.kind == .question { studio.paused = true; studio.playback.setPaused(true); studio.bleep?.stop() }
        }
    }
}

import Foundation
import Network
import Darwin
import SwiftUI
import CoreImage.CIFilterBuiltins

struct LANRequest {
    var method: String
    var path: String
    var headers: [String:String]
    var body: Data
    static func parse(_ data: Data) throws -> LANRequest? {
        guard data.count <= 49152 else { throw CocoaError(.fileReadTooLarge) }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw CocoaError(.fileReadCorruptFile) }; return nil
        }
        guard boundary.lowerBound <= 16384, let head = String(data: data[..<boundary.lowerBound],encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw CocoaError(.fileReadCorruptFile) }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw CocoaError(.fileReadCorruptFile) }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw CocoaError(.fileReadCorruptFile) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw CocoaError(.fileReadCorruptFile) }
        let length: Int
        if let raw = headers["content-length"] { guard let n = Int(raw), n >= 0, n <= 16384 else { throw CocoaError(.fileReadCorruptFile) }; length = n } else { length = 0 }
        guard data.count >= boundary.upperBound+length else { return nil }
        return LANRequest(method: String(first[0]),path: String(first[1]).components(separatedBy: "?")[0],headers: headers,body: Data(data[boundary.upperBound..<(boundary.upperBound+length)]))
    }
}
struct LANResponse {
    var status: Int = 200
    var type = "application/json; charset=utf-8"
    var data: Data
    static func json(_ object: [String:Any],status: Int = 200) -> LANResponse {
        LANResponse(status: status,data: (try? JSONSerialization.data(withJSONObject: object,options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    var wire: Data {
        let headers = "HTTP/1.1 \(status) Response\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n"
        return Data(headers.utf8)+data
    }
}
final class LANHTTPServer {
    let queue = DispatchQueue(label: "QuizStudio.LAN")
    private var listener: NWListener?
    private var clients: [UUID:NWConnection] = [:]
    var handle: (@MainActor (LANRequest) -> LANResponse)?
    var ready: (@MainActor (UInt16) -> Void)?
    var failed: (@MainActor (String) -> Void)?
    func start(port: UInt16 = 0) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters,on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self,weak listener] state in
            guard let self else { return }
            if case .ready = state, let port = listener?.port?.rawValue { Task { @MainActor in self.ready?(port) } }
            if case .failed(let error) = state { Task { @MainActor in self.failed?(error.localizedDescription) } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.clients.count < 96 else { connection.cancel(); return }
            let id = UUID(); self.clients[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.clients.removeValue(forKey: id) }
                if case .failed = state { self?.clients.removeValue(forKey: id) }
            }
            connection.start(queue: self.queue)
            self.read(connection,data: Data())
            self.queue.asyncAfter(deadline: .now()+10) { [weak connection] in connection?.cancel() }
        }
        listener.start(queue: queue)
    }
    private func read(_ connection: NWConnection,data: Data) {
        connection.receive(minimumIncompleteLength: 1,maximumLength: 16384) { [weak self] chunk,_,complete,error in
            guard let self else { connection.cancel(); return }
            var accumulated = data; if let chunk { accumulated.append(chunk) }
            do {
                if let request = try LANRequest.parse(accumulated) {
                    Task { @MainActor in
                        let response = self.handle?(request) ?? .json(["error":"Комната закрыта"],status:503)
                        connection.send(content:response.wire,completion:.contentProcessed { _ in connection.cancel() })
                    }
                } else if error != nil || complete { connection.cancel() }
                else { self.read(connection,data: accumulated) }
            } catch {
                connection.send(content:LANResponse.json(["error":"Некорректный запрос"],status:400).wire,completion:.contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func stop() {
        listener?.cancel(); listener = nil
        queue.async { for c in self.clients.values { c.cancel() }; self.clients.removeAll() }
    }
    deinit { listener?.cancel() }
}
struct PhoneSession: Codable {
    var token: String
    var teamID: UUID
    var registrationKey: String? = nil
}
struct PhoneAnswer: Codable, Identifiable {
    var id: String { teamID.uuidString + ":" + questionID.uuidString }
    var teamID: UUID
    var questionID: UUID
    var roundID: UUID
    var display: String
    var payload: Data
    var points: Double?
    var outcome: String? = nil
    var manuallyGraded = false
    enum CodingKeys: String, CodingKey { case teamID,questionID,roundID,display,payload,points,outcome,manuallyGraded }
    init(teamID:UUID,questionID:UUID,roundID:UUID,display:String,payload:Data,points:Double?,outcome:String?=nil,manuallyGraded:Bool=false) {
        self.teamID=teamID; self.questionID=questionID; self.roundID=roundID; self.display=display; self.payload=payload; self.points=points; self.outcome=outcome; self.manuallyGraded=manuallyGraded
    }
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        teamID=try values.decode(UUID.self,forKey:.teamID); questionID=try values.decode(UUID.self,forKey:.questionID)
        roundID=try values.decode(UUID.self,forKey:.roundID); display=try values.decode(String.self,forKey:.display)
        payload=try values.decode(Data.self,forKey:.payload); points=try values.decodeIfPresent(Double.self,forKey:.points)
        outcome=try values.decodeIfPresent(String.self,forKey:.outcome); manuallyGraded=try values.decodeIfPresent(Bool.self,forKey:.manuallyGraded) ?? false
    }
}
struct PhoneRecovery: Codable {
    var roomKey: String
    var port: UInt16
    var sessions: [PhoneSession]
    var answers: [PhoneAnswer]
    var baseline: [UUID:[String:Double]]
    var revision: Int
    var blockResponses: [UUID:[UUID:String]]? = nil
}
@MainActor final class PhoneRoom: ObservableObject {
    weak var studio: Studio?
    @Published var running = false
    @Published var starting = false
    @Published var blockResponses: [UUID:[UUID:String]] = [:]
    @Published var message = ""
    @Published var port: UInt16 = 0
    @Published var hosts: [String] = []
    @Published var selectedHost = ""
    @Published var sessions: [PhoneSession] = []
    @Published var answers: [PhoneAnswer] = []
    var roomKey = UUID().uuidString.replacingOccurrences(of: "-",with: "").lowercased()
    var baseline: [UUID:[String:Double]] = [:]
    var revision = 0
    var lastSeen: [UUID:Date] = [:]
    private var server: LANHTTPServer?
    var joinedTeams: [Team] { guard let studio else { return [] }; let ids = Set(sessions.map(\.teamID)); return studio.quiz.teams.filter { ids.contains($0.id) } }
    var address: String? { running && !selectedHost.isEmpty ? "http://\(selectedHost):\(port)/\(roomKey)/" : nil }
    var qrImage: NSImage? {
        guard let address else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(address.utf8); filter.correctionLevel = "M"
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9,y: 9)), let cg = CIContext().createCGImage(ci,from:ci.extent) else { return nil }
        return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
    }
    static func localHosts() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }; defer { freeifaddrs(pointer) }
        var result: [String] = []; var current = pointer
        while let node = current {
            defer { current = node.pointee.ifa_next }
            let name = String(cString:node.pointee.ifa_name)
            guard (name.hasPrefix("en") || name.hasPrefix("bridge")), let addr = node.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), (node.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var buffer = [CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(addr,socklen_t(addr.pointee.sa_len),&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST) == 0 { result.append(String(cString:buffer)) }
        }
        return Array(Set(result)).sorted()
    }
    func refreshHosts() { hosts = Self.localHosts(); if !hosts.contains(selectedHost) { selectedHost = hosts.first ?? "" } }
    func start(restoring: PhoneRecovery? = nil) {
        stop(clear: restoring == nil)
        if let saved = restoring { roomKey = saved.roomKey; port = saved.port; sessions = saved.sessions; answers = saved.answers; baseline = saved.baseline; revision = saved.revision; blockResponses=saved.blockResponses ?? [:] }
        refreshHosts(); starting = true; message = "Запускаем локальную комнату…"
        let server = LANHTTPServer(); self.server = server
        server.handle = { [weak self] request in self?.handle(request) ?? .json(["error":"Комната закрыта"],status:503) }
        server.ready = { [weak self,weak server] port in
            guard let self, self.server === server else { return }
            self.port = port; self.running = true; self.starting = false
            self.message = self.hosts.isEmpty ? "Подключите Mac к Wi-Fi или роутеру и обновите адреса." : "Комната открыта. Телефоны должны быть в одной сети с Mac."
        }
        server.failed = { [weak self,weak server] message in guard let self, self.server === server else { return }; self.running = false; self.starting = false; self.message = "Не удалось открыть комнату: " + message }
        do { try server.start(port: restoring?.port ?? 0) } catch { starting = false; message = error.localizedDescription }
    }
    func stop(clear: Bool = true) {
        server?.stop(); server = nil; running = false; starting = false
        if clear { sessions = []; answers = []; blockResponses=[:]; baseline = [:]; lastSeen = [:]; revision = 0; roomKey = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(); port = 0 }
    }
    var recovery: PhoneRecovery? { guard port > 0 else { return nil }; return PhoneRecovery(roomKey:roomKey,port:port,sessions:sessions,answers:answers,baseline:baseline,revision:revision,blockResponses:blockResponses) }
    func beginGame() {
        answers = [];blockResponses=[:]; baseline = Dictionary(uniqueKeysWithValues:joinedTeams.map { ($0.id,$0.scores) }); revision += 1
    }
    func questionChanged() { revision += 1 }
    var canAccept: Bool {
        guard running, let studio, studio.phoneMode, studio.playing, let step = studio.step, step.kind == .question else { return false }
        return !studio.paused && !studio.awaitingQuestionStart && (step.duration == 0 || studio.remaining > 0 || studio.waitingForMedia)
    }
    var questionToken: String { guard let q = studio?.currentQuestion else { return "" }; return q.id.uuidString + ":" + String(revision) }
    func pending(through round: Int) -> [PhoneAnswer] {
        guard let studio else { return [] }; let ids = Set(studio.quiz.rounds.prefix(round+1).map(\.id))
        return answers.filter { $0.points == nil && ids.contains($0.roundID) }
    }
    func updateScores() {
        guard let studio else { return }
        for i in studio.quiz.teams.indices {
            let teamID = studio.quiz.teams[i].id
            guard sessions.contains(where: { $0.teamID == teamID }) else { continue }
            var scores = baseline[teamID] ?? [:]
            for answer in answers where answer.teamID == teamID { scores[answer.roundID.uuidString,default:0] += answer.points ?? 0 }
            studio.quiz.teams[i].scores = scores
        }
    }
    func questionRulesChanged(questionID: UUID) {
        guard let question = studio?.quiz.rounds.flatMap(\.questions).first(where: { $0.id == questionID }) else { return }
        var changed = false
        for index in answers.indices where answers[index].questionID == questionID {
            // Keep human decisions. Automatically graded decisions are invalidated against the new key.
            guard !answers[index].manuallyGraded, answers[index].points != nil, answers[index].outcome != nil else { continue }
            let oldPoints=answers[index].points, oldOutcome=answers[index].outcome
            let payload = (try? JSONSerialization.jsonObject(with: answers[index].payload)) as? [String:Any] ?? [:]
            let wagered = question.wagerEnabled == true && payload["wager"] as? Bool == true
            if let text = payload["text"] as? String {
                if question.extraIssues != nil {
                    if let result = try? question.gradeExtra(["text":text]) {
                        answers[index].points = question.awardedPoints(grade:result.points,wagered:wagered)
                        answers[index].outcome = result.points == 1 ? "correct" : result.points == 2 ? "partial" : "wrong"
                    } else { answers[index].points = nil; answers[index].outcome = nil }
                } else {
                    let allowed = [question.correctAnswer] + (question.acceptedAnswers ?? [])
                    let correct = allowed.contains { Self.normalize($0) == Self.normalize(text) }
                    answers[index].points = correct ? question.awardedPoints(correct:true,wagered:wagered) : nil
                    answers[index].outcome = correct ? "correct" : nil
                }
            } else if let choices = payload["choices"] as? [Int], let correct = question.correctChoices {
                let selected = Set(choices), expected = Set(correct), all = selected == expected
                let count = selected.intersection(expected).count
                answers[index].points = all ? question.awardedPoints(correct:true,wagered:wagered) : count > 0 ? (question.partialPoints ?? question.awardedPoints(correct:false,wagered:wagered)) : question.awardedPoints(correct:false,wagered:wagered)
                answers[index].outcome = all ? "correct" : count > 0 && question.partialPoints != nil ? "partial" : "wrong"
            } else if let choice = payload["choice"] as? Int {
                let correct = question.selectedChoice ?? question.choices.firstIndex(of:question.correctAnswer)
                let isCorrect = choice == correct
                answers[index].points = question.awardedPoints(correct:isCorrect,wagered:wagered)
                answers[index].outcome = isCorrect ? "correct" : "wrong"
            } else if let matches = payload["matches"] as? [String:String], let pairs = question.matchPairs {
                let layout = studio?.matchLayouts[questionID]
                var correctCount=0
                if let layout {
                    for (i,leftID) in layout.left.enumerated() {
                        guard let rightValue=matches["l\(i)"],let rightIndex=Int(rightValue.dropFirst()),layout.right.indices.contains(rightIndex) else { continue }
                        if layout.right[rightIndex] == leftID { correctCount += 1 }
                    }
                }
                let all = correctCount == pairs.count
                answers[index].points = all ? question.awardedPoints(correct:true,wagered:wagered) : correctCount > 0 ? (question.partialPoints ?? question.awardedPoints(correct:false,wagered:wagered)) : question.awardedPoints(correct:false,wagered:wagered)
                answers[index].outcome = all ? "correct" : correctCount > 0 && question.partialPoints != nil ? "partial" : "wrong"
            } else if let order = payload["order"] as? [Int], let items = question.sequenceItems {
                let expected = items.map(\.id)
                let correctOrder = order.compactMap { question.displayedSequence.indices.contains($0) ? question.displayedSequence[$0].id : nil }
                let all = correctOrder == expected
                let partial = zip(correctOrder,expected).contains { $0 == $1 }
                answers[index].points = question.awardedPoints(grade:all ? 1 : partial && question.partialPoints != nil ? 2 : 0,wagered:wagered)
                answers[index].outcome = all ? "correct" : partial && question.partialPoints != nil ? "partial" : "wrong"
            } else if let categories = payload["categories"] as? [String:Int] {
                let items = question.displayedCategoryItems
                let correctCount = items.indices.filter { categories[String($0)] == items[$0].category }.count
                let all = correctCount == items.count
                answers[index].points = question.awardedPoints(grade:all ? 1 : correctCount > 0 && question.partialPoints != nil ? 2 : 0,wagered:wagered)
                answers[index].outcome = all ? "correct" : correctCount > 0 && question.partialPoints != nil ? "partial" : "wrong"
            } else {
                answers[index].points = nil; answers[index].outcome = nil
            }
            if oldPoints != answers[index].points || oldOutcome != answers[index].outcome { changed = true }
        }
        updateScores()
        if changed { revision += 1 }
        studio?.checkpoint()
    }
    func grade(_ id: String,points: Int) {
        guard let i = answers.firstIndex(where: { $0.id == id }), [0,1,2].contains(points) else { return }
        let q=studio?.quiz.rounds.flatMap(\.questions).first { $0.id == answers[i].questionID }
        guard points != 2 || q?.partialPoints != nil else { return }
        let payload=(try? JSONSerialization.jsonObject(with:answers[i].payload)) as? [String:Any]
        answers[i].points = points == 2 ? q?.partialPoints : q?.awardedPoints(correct:points==1,wagered:q?.wagerEnabled == true && payload?["wager"] as? Bool == true) ?? Double(points)
        answers[i].outcome = points == 1 ? "correct" : points == 2 ? "partial":"wrong"
        answers[i].manuallyGraded = true
        updateScores(); studio?.checkpoint()
    }
    nonisolated static func normalize(_ text: String) -> String { text.lowercased().replacingOccurrences(of:"ё",with:"е").split(whereSeparator: { $0.isWhitespace }).joined(separator:" ") }
    func handle(_ request: LANRequest) -> LANResponse {
        guard running, let studio else { return .json(["error":"Комната закрыта"],status:503) }
        let base = "/" + roomKey
        guard request.path == base || request.path.hasPrefix(base + "/") else { return .json(["error":"Комната не найдена"],status:404) }
        if let origin = request.headers["origin"], origin != "http://" + (request.headers["host"] ?? "") { return .json(["error":"Неверный источник запроса"],status:403) }
        if request.method == "GET" && [base,base+"/"].contains(request.path) {
            return LANResponse(type:"text/html; charset=utf-8",data:Data(Self.page.utf8))
        }
        if request.method == "GET",request.path.hasPrefix(base+"/asset/") {
            let rawName=String(request.path.dropFirst((base+"/asset/").count))
            guard let name=rawName.removingPercentEncoding,name == rawName,name.range(of:"^[A-Za-z0-9._-]{1,255}$",options:.regularExpression) != nil,name != ".",name != ".." else { return .json(["error":"Изображение не найдено"],status:404) }
            let allowed=Set(studio.currentQuestion?.choiceImages?.compactMap{$0} ?? [])
            guard allowed.contains(name),let url=studio.asset(name),let folder=studio.folder else { return .json(["error":"Изображение не найдено"],status:404) }
            let mediaRoot=folder.appendingPathComponent("Media",isDirectory:true).standardizedFileURL
            let fileURL=url.standardizedFileURL
            guard fileURL.deletingLastPathComponent() == mediaRoot,let data=try? Data(contentsOf:fileURL),data.count<=12_000_000 else { return .json(["error":"Изображение не найдено"],status:404) }
            let ext=url.pathExtension.lowercased(),type=ext=="png" ? "image/png" : ext=="webp" ? "image/webp" : "image/jpeg";return LANResponse(type:type,data:data)
        }
        let object = (try? JSONSerialization.jsonObject(with:request.body)) as? [String:Any] ?? [:]
        if request.method == "POST" && request.path == base+"/join" {
            let registrationKey = object["device"] as? String ?? ""
            guard registrationKey.count >= 32, registrationKey.count <= 100 else { return .json(["error":"Обновите страницу подключения"],status:400) }
            if let old = sessions.first(where: { $0.registrationKey == registrationKey }), let team = studio.quiz.teams.first(where: { $0.id == old.teamID }) {
                return .json(["token":old.token,"name":team.name])
            }
            guard !studio.playing else { return .json(["error":"Игра уже идёт. Вернитесь с телефона, с которого подключалась команда."],status:409) }
            guard sessions.count < 100 else { return .json(["error":"В комнате уже 100 команд"],status:409) }
            var name = (object["name"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard name.count <= 60 else { return .json(["error":"Название не длиннее 60 символов"],status:400) }
            if name.isEmpty { var n = sessions.count+1; repeat { name = "Команда \(n)"; n += 1 } while studio.quiz.teams.contains { Self.normalize($0.name) == Self.normalize(name) } }
            let existing = studio.quiz.teams.first { Self.normalize($0.name) == Self.normalize(name) }
            if let existing, sessions.contains(where: { $0.teamID == existing.id }) { return .json(["error":"Это название уже занято подключённой командой"],status:409) }
            let team = existing ?? Team(name:name)
            if existing == nil { studio.quiz.teams.append(team) }
            let session = PhoneSession(token:UUID().uuidString+UUID().uuidString,teamID:team.id,registrationKey:registrationKey)
            sessions.append(session); lastSeen[team.id] = Date(); studio.objectWillChange.send()
            return .json(["token":session.token,"name":team.name])
        }
        let token = request.headers["authorization"]?.replacingOccurrences(of:"Bearer ",with:"") ?? ""
        guard let session = sessions.first(where: { $0.token == token }), let team = studio.quiz.teams.first(where: { $0.id == session.teamID }) else { return .json(["error":"Подключитесь к комнате заново"],status:401) }
        lastSeen[team.id] = Date()
        if request.method == "GET" && request.path == base+"/state" { return .json(state(for:team)) }
        if request.method == "POST" && request.path == base+"/block" {
            guard studio.playing,!studio.paused,let step=studio.step,step.kind == .block,let bi=step.block,(studio.quiz.rounds[step.round].blocks ?? []).indices.contains(bi) else { return .json(["error":"Приём ответов закрыт"],status:409) }
            let block=studio.quiz.rounds[step.round].blocks![bi]
            guard object["block"] as? String == block.id.uuidString else { return .json(["error":"Этот блок уже закрыт"],status:409) }
            let value=(object["value"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty,value.count<=200 else { return .json(["error":"Введите ответ"],status:400) }
            if ["Голосование","Выбор темы"].contains(block.kind),!(block.options ?? []).contains(value) { return .json(["error":"Выберите предложенный вариант"],status:400) }
            if let old=blockResponses[block.id]?[team.id] { return old==value ? .json(["accepted":true]) : .json(["error":"Ответ уже отправлен"],status:409) }
            blockResponses[block.id,default:[:]][team.id]=value;studio.objectWillChange.send();studio.checkpoint();return .json(["accepted":true])
        }
        if request.method == "POST" && request.path == base+"/answer" {
            guard canAccept, let step = studio.step, let q = studio.currentQuestion, object["question"] as? String == questionToken else { return .json(["error":"Приём ответов на этот вопрос закрыт"],status:409) }
            let payload = object["answer"] as? [String:Any] ?? [:]
            guard let canonical = try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys) else { return .json(["error":"Неверный ответ"],status:400) }
            if let old = answers.first(where: { $0.teamID == team.id && $0.questionID == q.id }) {
                return old.payload == canonical ? .json(["accepted":true]) : .json(["error":"Ответ уже отправлен и сохранён"],status:409)
            }
            var points: Double?; var display = "";var outcome:String?
            let wagered = q.wagerEnabled == true && (payload["wager"] as? Bool == true)
            if q.extraIssues != nil {
                do { guard let result = try q.gradeExtra(payload) else { throw SIQError(message:"Неверный ответ") }; display = result.display; points = q.awardedPoints(grade:result.points,wagered:wagered);outcome=result.points==1 ? "correct" : result.points==2 ? "partial":"wrong" } catch { return .json(["error":error.localizedDescription],status:400) }
            } else if q.kind == "Один из четырёх" {
                guard let n = payload["choice"] as? Int, q.choices.indices.contains(n) else { return .json(["error":"Выберите вариант"],status:400) }
                display = q.choices[n]
                let correct = q.selectedChoice ?? q.choices.firstIndex(of:q.correctAnswer)
                let right=n == correct;points = q.awardedPoints(correct:right,wagered:wagered);outcome=right ? "correct":"wrong"
            } else if q.kind == "Сопоставление", let pairs = q.matchPairs, let layout = studio.matchLayouts[q.id] {
                let matches = payload["matches"] as? [String:String] ?? [:]
                let expectedKeys = Set(layout.left.indices.map { "l\($0)" })
                guard layout.left.count == pairs.count, layout.right.count == pairs.count,
                      matches.count == pairs.count, Set(matches.keys) == expectedKeys,
                      Set(matches.values).count == pairs.count else { return .json(["error":"Сопоставьте все пары, без повторений"],status:400) }
                var allCorrect = true; var lines: [String] = []
                var correctCount = 0
                for (i,leftID) in layout.left.enumerated() {
                    guard let raw = matches["l\(i)"], raw.hasPrefix("r"), let j = Int(raw.dropFirst()), "r\(j)" == raw, layout.right.indices.contains(j), let left = pairs.first(where: { $0.id == leftID }), let right = pairs.first(where: { $0.id == layout.right[j] }) else { return .json(["error":"Неверная пара"],status:400) }
                    let correct = leftID == layout.right[j]
                    allCorrect = allCorrect && correct
                    if correct { correctCount += 1 }
                    lines.append(left.left + " — " + right.right)
                }
                display = lines.joined(separator:"\n"); points = allCorrect ? q.awardedPoints(correct:true,wagered:wagered) : correctCount>0 ? (q.partialPoints ?? q.awardedPoints(correct:false,wagered:wagered)) : q.awardedPoints(correct:false,wagered:wagered);outcome=allCorrect ? "correct" : correctCount>0 && q.partialPoints != nil ? "partial":"wrong"
            } else {
                let text = (payload["text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 1000 else { return .json(["error":"Введите ответ, не длиннее 1000 символов"],status:400) }
                display = text
                let allowed = [q.correctAnswer] + (q.acceptedAnswers ?? [])
                let right=allowed.contains { Self.normalize($0) == Self.normalize(text) };points = right ? q.awardedPoints(correct:true,wagered:wagered) : nil;outcome=right ? "correct":nil
            }
            answers.append(PhoneAnswer(teamID:team.id,questionID:q.id,roundID:studio.quiz.rounds[step.round].id,display:display,payload:canonical,points:points,outcome:outcome))
            updateScores(); studio.checkpoint()
            return .json(["accepted":true])
        }
        return .json(["error":"Не найдено"],status:404)
    }
    func state(for team: Team) -> [String:Any] {
        guard let studio else { return [:] }
        var state: [String:Any] = ["team":team.name,"title":studio.quiz.title,"phase":"lobby","message":"Ожидаем начала игры","open":false]
        guard studio.playing, let step = studio.step else { return state }
        state["phase"] = step.kind.rawValue
        state["message"] = studio.paused ? "Пауза ведущего" : studio.awaitingQuestionStart ? "Ведущий читает вопрос" : "Смотрите на экран"
        if step.kind == .block,let bi=step.block,(studio.quiz.rounds[step.round].blocks ?? []).indices.contains(bi) {
            let block=studio.quiz.rounds[step.round].blocks![bi];state["block"]=block.id.uuidString;state["blockKind"]=block.kind;state["text"]=block.title+"\n"+block.text
            state["blockOptions"]=block.options ?? [];state["open"] = !studio.paused && ["Голосование","Облако слов","Выбор темы"].contains(block.kind);if let sent=blockResponses[block.id]?[team.id] { state["blockSent"]=sent };return state
        }
        if [.question,.repeated,.answerPrompt,.answer].contains(step.kind), let q = studio.currentQuestion {
            state["question"] = questionToken; state["text"] = q.text; state["kind"] = q.kind
            state["round"] = studio.quiz.rounds[step.round].title
            state["open"] = canAccept
            if step.kind == .question && !studio.awaitingQuestionStart && !studio.waitingForMedia && step.duration > 0 { state["seconds"] = studio.remaining }
            if q.isChoiceQuestion { state["choices"] = q.choices;state["choiceImages"]=(q.choiceImages ?? []).map{$0.map{"/"+roomKey+"/asset/"+$0} ?? ""} }
            if q.kind == "Порядок событий" { state["sequence"] = q.displayedSequence.map(\.text) }
            if q.kind == "Категоризация" { state["categoryGroups"] = q.categoryGroups ?? []; state["categoryItems"] = q.displayedCategoryItems.map(\.text) }
            state["scoring"] = q.scoringSummary;if q.wagerEnabled == true { state["wager"] = true }
            if q.kind == "Сопоставление", let pairs = q.matchPairs, let layout = studio.matchLayouts[q.id] {
                state["left"] = layout.left.enumerated().map { i,id in ["key":"l\(i)","text":pairs.first { $0.id == id }?.left ?? ""] }
                state["right"] = layout.right.enumerated().map { i,id in ["key":"r\(i)","text":pairs.first { $0.id == id }?.right ?? ""] }
            }
            if let sent = answers.first(where: { $0.teamID == team.id && $0.questionID == q.id }) { state["sent"] = sent.display }
            if step.kind == .answer {
                state["correct"] = q.kind == "Сопоставление" ? (q.matchPairs ?? []).map { $0.left + " — " + $0.right }.joined(separator:"\n") : q.correctAnswer
                if q.kind == "Один из четырёх",let choice=q.selectedChoice,let images=q.choiceImages,images.indices.contains(choice),let name=images[choice] { state["correctImage"]="/"+roomKey+"/asset/"+name }
                state["explanation"] = q.explanation ?? ""
            }
        }
        if step.kind == .standings {
            state["message"] = studio.publishedScores ? "Результаты" : "Перерыв. Ведущий проверяет ответы и баллы."
            if studio.publishedScores { state["scores"] = studio.scoreSnapshot.filter { studio.scoreRevealedIDs.contains($0.id) }.map { row in ["name":row.name,"points":row.total,"place":1+studio.scoreSnapshot.filter { $0.total > row.total }.count] as [String:Any] } }
        }
        if step.kind == .finish { state["message"] = "Квиз завершён. Спасибо за игру!" }
        return state
    }
    static var page: String { PhonePage.html }
}

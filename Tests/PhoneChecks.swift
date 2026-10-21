struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct PhoneChecks {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds:100_000_000) }
        throw NSError(domain:"PhoneChecks",code:1,userInfo:[NSLocalizedDescriptionKey:"Timed out"])
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = Studio(draftURL:root.appendingPathComponent("Draft.workspace")); app.timer?.invalidate()
        var choice = Question(text:"Выберите ответ",kind:"Один из четырёх",choices:["А","Б","Верный","Г"],answer:"Верный",seconds:30)
        choice.selectedChoice = 2; choice.hostNotes = "SECRET_HOST_NOTE"
        var matching = Question(text:"Сопоставьте пары",kind:"Сопоставление",seconds:30)
        matching.matchPairs = [MatchPair(left:"Франция",right:"Париж"),MatchPair(left:"Италия",right:"Рим"),MatchPair(left:"Япония",right:"Токио")]
        var open = Question(text:"Назовите город",answer:"Санкт-Петербург",seconds:30); open.acceptedAnswers = ["Питер"]
        app.quiz.rounds = [Round(title:"Раунд",questions:[choice,matching,open])]
        app.quiz.rounds[0].standings = true
        app.phoneMode = true; app.readBeforeTimer = true
        app.phoneRoom.start(); try await wait { app.phoneRoom.running }
        app.phoneRoom.selectedHost = "127.0.0.1"
        let qr = app.phoneRoom.qrImage!
        let qrCI = CIImage(data:qr.tiffRepresentation!)!
        let detector = CIDetector(ofType:CIDetectorTypeQRCode,context:nil,options:[CIDetectorAccuracy:CIDetectorAccuracyHigh])!
        let decodedQR = detector.features(in:qrCI).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        assert(decodedQR.contains(app.phoneRoom.address!))
        let port = app.phoneRoom.port; let path = "/"+app.phoneRoom.roomKey
        let origin = "http://127.0.0.1:\(port)"
        if CommandLine.arguments.count > 1 {
            let marker = URL(fileURLWithPath:CommandLine.arguments[1])
            try (origin+path+"/").write(to:marker,atomically:true,encoding:.utf8)
            while FileManager.default.fileExists(atPath:marker.path) {
                if !app.playing && !app.phoneRoom.joinedTeams.isEmpty {
                    app.beginGame(); app.jump(to:app.steps.firstIndex { $0.kind == .question }!); app.startQuestionTimer(); app.remaining = 120
                }
                try await Task.sleep(nanoseconds:200_000_000)
            }
            app.stop(); return
        }
        func call(_ endpoint: String,token: String = "",body: [String:Any]? = nil,foreignOrigin: Bool = false) async throws -> (Int,[String:Any]) {
            var request = URLRequest(url:URL(string:origin+path+endpoint)!)
            request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            if foreignOrigin { request.setValue("http://untrusted.test",forHTTPHeaderField:"Origin") }
            if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject:body); request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
            let (data,response) = try await URLSession.shared.data(for:request)
            return ((response as! HTTPURLResponse).statusCode,(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:])
        }
        let (html,response) = try await URLSession.shared.data(from:URL(string:origin+path+"/")!)
        assert((response as! HTTPURLResponse).statusCode == 200 && String(data:html,encoding:.utf8)!.contains("<html"))
        let unauthorized = try await call("/state"); assert(unauthorized.0 == 401)
        let crossSite = try await call("/join",body:["name":"evil","device":String(repeating:"f",count:40)],foreignOrigin:true); assert(crossSite.0 == 403)
        var tokens: [String] = []
        for n in 0..<40 {
            let result = try await call("/join",body:["name":"Команда \(n)","device":String(repeating:"d",count:32)+String(n)])
            assert(result.0 == 200); tokens.append(result.1["token"] as! String)
        }
        assert(app.phoneRoom.joinedTeams.count == 40)
        let repeatJoin = try await call("/join",body:["name":"Потерянный ответ регистрации","device":String(repeating:"d",count:32)+"0"])
        assert(repeatJoin.1["token"] as? String == tokens[0] && app.quiz.teams.count == 40)
        let duplicate = try await call("/join",body:["name":"Команда 0","device":String(repeating:"x",count:40)]); assert(duplicate.0 == 409)
        app.documentURL = root.appendingPathComponent("Game.quiz"); try app.write(to:app.documentURL!)
        app.beginGame(); assert(app.playing && app.quiz.teams.count == 40)
        let q0 = app.steps.firstIndex { $0.kind == .question && $0.question == 0 }!
        app.jump(to:q0); assert(!app.phoneRoom.canAccept)
        let reading = try await call("/state",token:tokens[0]); assert(reading.1["seconds"] == nil && reading.1["open"] as? Bool == false)
        app.startQuestionTimer()
        let state = try await call("/state",token:tokens[0]); let epoch = state.1["question"] as! String
        assert(state.1["correct"] == nil && state.1["selectedChoice"] == nil)
        let publicState = String(data:try JSONSerialization.data(withJSONObject:state.1),encoding:.utf8)!; assert(!publicState.contains("SECRET_HOST_NOTE"))
        let lateJoin = try await call("/join",body:["name":"Новая","device":String(repeating:"z",count:40)]); assert(lateJoin.0 == 409)
        let outcomes = try await withThrowingTaskGroup(of:Int.self) { group in
            for n in 0..<40 { group.addTask { let result = try await call("/answer",token:tokens[n],body:["question":epoch,"answer":["choice":n%4]]); return result.0 } }
            var results: [Int] = []; for try await status in group { results.append(status) }; return results
        }
        assert(outcomes.allSatisfy { $0 == 200 } && app.phoneRoom.answers.count == 40)
        assert(app.quiz.teams.map(\.total).reduce(0,+) == 10)
        let beforeResults = try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:app.documentURL!))
        assert(beforeResults.quiz.teams.map(\.total).reduce(0,+) == 0)
        let same = try await call("/answer",token:tokens[2],body:["question":epoch,"answer":["choice":2]]); assert(same.0 == 200 && app.phoneRoom.answers.count == 40)
        let changed = try await call("/answer",token:tokens[2],body:["question":epoch,"answer":["choice":1]]); assert(changed.0 == 409)
        let mIndex = app.steps.firstIndex { $0.kind == .question && $0.question == 1 }!
        app.jump(to:mIndex); app.startQuestionTimer()
        let oldRequest = try await call("/answer",token:tokens[0],body:["question":epoch,"answer":["choice":2]]); assert(oldRequest.0 == 409)
        let matchState = try await call("/state",token:tokens[0]); let matchEpoch = matchState.1["question"] as! String
        let layout = app.matchLayouts[matching.id]!
        var correct: [String:String] = [:]
        for (i,id) in layout.left.enumerated() { correct["l\(i)"] = "r\(layout.right.firstIndex(of:id)!)" }
        var wrong = correct; wrong["l0"] = correct["l1"]; wrong["l1"] = correct["l0"]
        let right = try await call("/answer",token:tokens[0],body:["question":matchEpoch,"answer":["matches":correct]])
        let bad = try await call("/answer",token:tokens[1],body:["question":matchEpoch,"answer":["matches":wrong]])
        assert(right.0 == 200 && bad.0 == 200)
        assert(app.phoneRoom.answers.first { $0.teamID == app.quiz.teams[0].id && $0.questionID == matching.id }!.points == 1)
        assert(app.phoneRoom.answers.first { $0.teamID == app.quiz.teams[1].id && $0.questionID == matching.id }!.points == 0)
        let missing = try await call("/answer",token:tokens[2],body:["question":matchEpoch,"answer":["matches":["l0":"r0"]]]); assert(missing.0 == 400)
        let empty = try await call("/answer",token:tokens[3],body:["question":matchEpoch,"answer":["matches":[:] as [String:String]]]); assert(empty.0 == 400)
        var extra = correct; extra["l99"] = "r0"
        let extraKey = try await call("/answer",token:tokens[4],body:["question":matchEpoch,"answer":["matches":extra]]); assert(extraKey.0 == 400)
        var badRight = correct; badRight["l0"] = "r99"
        let invalidRight = try await call("/answer",token:tokens[5],body:["question":matchEpoch,"answer":["matches":badRight]]); assert(invalidRight.0 == 400)
        var wrongKey = correct; wrongKey.removeValue(forKey:"l0"); wrongKey["l99"] = "r0"
        let invalidLeft = try await call("/answer",token:tokens[6],body:["question":matchEpoch,"answer":["matches":wrongKey]]); assert(invalidLeft.0 == 400)
        var paddedRight = correct; paddedRight["l0"] = "r0" + String(repeating:"0",count:1)
        let nonCanonicalRight = try await call("/answer",token:tokens[7],body:["question":matchEpoch,"answer":["matches":paddedRight]]); assert(nonCanonicalRight.0 == 400)
        var signedRight = correct; signedRight["l0"] = "r+0"
        let signedIndex = try await call("/answer",token:tokens[8],body:["question":matchEpoch,"answer":["matches":signedRight]]); assert(signedIndex.0 == 400)
        let reordered = Dictionary(uniqueKeysWithValues:correct.sorted { $0.key > $1.key })
        let reorderedAnswer = try await call("/answer",token:tokens[9],body:["question":matchEpoch,"answer":["matches":reordered]])
        assert(reorderedAnswer.0 == 200)
        let publicMatching = String(data:try JSONSerialization.data(withJSONObject:matchState.1),encoding:.utf8)!
        assert(!(matching.matchPairs ?? []).contains { publicMatching.contains($0.id.uuidString) })
        app.jump(to:app.steps.firstIndex { $0.kind == .question && $0.question == 2 }!); app.startQuestionTimer()
        let freeEpoch = app.phoneRoom.questionToken
        let accepted = try await call("/answer",token:tokens[0],body:["question":freeEpoch,"answer":["text":"  питЕР  "]]); assert(accepted.0 == 200)
        let pending = try await call("/answer",token:tokens[1],body:["question":freeEpoch,"answer":["text":"Санкт Петербурх"]]); assert(pending.0 == 200)
        assert(app.phoneRoom.pending(through:0).count == 1)
        app.paused = true; let paused = try await call("/answer",token:tokens[2],body:["question":freeEpoch,"answer":["text":"Питер"]]); assert(paused.0 == 409)
        app.paused = false; app.remaining = 0; let expired = try await call("/answer",token:tokens[2],body:["question":freeEpoch,"answer":["text":"Питер"]]); assert(expired.0 == 409)
        app.index = app.steps.firstIndex { $0.kind == .standings }!; app.publishedScores = false
        app.publishScores(); assert(!app.publishedScores && app.showPhoneReview)
        let breakState = try await call("/state",token:tokens[0]); assert(breakState.1["scores"] == nil)
        app.phoneRoom.grade(app.phoneRoom.pending(through:0)[0].id,points:1)
        app.publishScores(); assert(app.publishedScores)
        let savedResults = try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:app.documentURL!))
        assert(savedResults.quiz.teams.map(\.total) == app.quiz.teams.map(\.total))
        app.revealAllScores(); let scoreState = try await call("/state",token:tokens[0]); assert((scoreState.1["scores"] as? [[String:Any]])?.count == 40)
        app.index = app.steps.firstIndex { $0.kind == .answerPrompt && $0.question == 2 }!; assert(app.phoneRoom.state(for:app.quiz.teams[0])["correct"] == nil)
        app.index = app.steps.firstIndex { $0.kind == .answer && $0.question == 2 }!; assert(app.phoneRoom.state(for:app.quiz.teams[0])["correct"] as? String == "Санкт-Петербург")
        app.checkpoint(); let savedAnswers = app.phoneRoom.answers.count
        app.phoneRoom.stop(clear:false); try await Task.sleep(nanoseconds:200_000_000)
        let restored = Studio(draftURL:app.draft); restored.timer?.invalidate(); restored.restoreGame()
        try await wait { restored.phoneRoom.running }
        assert(restored.phoneMode && restored.paused && restored.phoneRoom.port == port && restored.phoneRoom.answers.count == savedAnswers)
        let reconnected = try await call("/state",token:tokens[0]); assert(reconnected.0 == 200 && reconnected.1["team"] as? String == "Команда 0")
        restored.stop(); app.stop()
        let incomplete = try LANRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\n{".utf8)); assert(incomplete == nil)
        do { _ = try LANRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)); assertionFailure() } catch {}
        print("PASS: real local HTTP server, QR page, 40 teams/parallel submissions, join retries, reconnect and persisted room")
        print("PASS: exact choice grading, matching all pairs = one point, partial matching = zero, manual free-text review and score publication")
        print("PASS: hidden correct answers/notes/UUID mappings, auth/origin checks, pause/deadline/stale-answer rejection and bounded HTTP parsing")
    }
}

import SwiftUI
import AVFoundation
import AppKit

struct YouTubeImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
enum YouTubeLink {
    static func canonical(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count <= 2048, let c = URLComponents(string:text.contains("://") ? text : "https://"+text),
              ["https","http"].contains(c.scheme?.lowercased() ?? ""),c.user == nil,c.password == nil,c.port == nil || c.port == 443 else {
            throw YouTubeImportError(message:"Вставьте ссылку на один ролик YouTube.")
        }
        let host = c.host?.lowercased() ?? ""
        let parts = c.path.split(separator:"/").map(String.init)
        let id: String?
        if ["youtu.be","www.youtu.be"].contains(host), parts.count == 1 { id = parts.first }
        else if ["youtube.com","www.youtube.com","m.youtube.com","music.youtube.com"].contains(host) {
            if c.path == "/watch" { let ids = (c.queryItems ?? []).filter { $0.name == "v" }; id = ids.count == 1 ? ids[0].value : nil }
            else if parts.count == 2 && ["shorts","embed","live"].contains(parts[0]) { id = parts[1] }
            else { id = nil }
        } else { id = nil }
        guard let id, id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else {
            throw YouTubeImportError(message:"Нужна ссылка на отдельное видео YouTube, Shorts или youtu.be.")
        }
        return URL(string:"https://www.youtube.com/watch?v="+id)!
    }
}
struct YouTubeFormat: Decodable {
    var format_id: String
    var ext: String?
    var vcodec: String?
    var acodec: String?
    var height: Double?
    var abr: Double?
    var tbr: Double?
    var has_drm: Bool?
    var `protocol`: String?
    var hasVideo: Bool { vcodec != nil && vcodec != "none" }
    var hasAudio: Bool { acodec != nil && acodec != "none" }
}
struct YouTubeMetadata: Decodable {
    var id: String
    var title: String
    var duration: Double?
    var is_live: Bool?
    var live_status: String?
    var formats: [YouTubeFormat]
    func selection(audioOnly: Bool,height: Int) throws -> [YouTubeFormat] {
        guard is_live != true, live_status != "is_live", live_status != "is_upcoming", let duration, duration.isFinite, duration > 0, duration <= 7200 else {
            throw YouTubeImportError(message:"Поддерживаются завершённые записи длительностью до двух часов. Прямые эфиры не загружаются.")
        }
        let allowed = formats.filter { ["https","http"].contains($0.protocol ?? "https") && $0.has_drm != true && $0.format_id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil }
        let audios = allowed.filter { !$0.hasVideo && $0.hasAudio && $0.ext == "m4a" && ($0.acodec?.hasPrefix("mp4a") == true || $0.acodec == "aac") }
            .sorted { ($0.abr ?? $0.tbr ?? 0) > ($1.abr ?? $1.tbr ?? 0) }
        if audioOnly {
            guard let audio = audios.first else { throw YouTubeImportError(message:"У ролика нет доступной совместимой аудиодорожки AAC. Попробуйте загрузить видео или выбрать другой ролик.") }
            return [audio]
        }
        let videos = allowed.filter { $0.hasVideo && $0.ext == "mp4" && ($0.vcodec?.hasPrefix("avc1") == true || $0.vcodec == "h264") && ($0.height ?? 0) > 0 && ($0.height ?? 0) <= Double(height) && (!$0.hasAudio || $0.acodec?.hasPrefix("mp4a") == true || $0.acodec == "aac") }
            .sorted { if $0.height != $1.height { return ($0.height ?? 0) > ($1.height ?? 0) }; return ($0.tbr ?? 0) > ($1.tbr ?? 0) }
        guard let video = videos.first else { throw YouTubeImportError(message:"Нет доступного MP4/H.264 в выбранном качестве. Попробуйте увеличить качество или выбрать другой ролик.") }
        if video.hasAudio { return [video] }
        guard let audio = audios.first else { throw YouTubeImportError(message:"Не найдена доступная аудиодорожка AAC для этого ролика.") }
        return [video,audio]
    }
}

private final class ImportProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        process = p; try p.run()
    }
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning {
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline:.now()+2) { if p.isRunning { p.terminate() } }
        }
    }
}
enum ImportProcess {
    static func run(executable: URL,args: [String],directory: URL,timeout: Double = 600,onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [String] {
        let control = ImportProcessControl()
        return try await withTaskCancellationHandler(operation: {
            let task = Task.detached(priority:.userInitiated) { () throws -> [String] in
                let process = Process(); let pipe = Pipe()
                process.executableURL = executable; process.arguments = args; process.currentDirectoryURL = directory
                var env = ProcessInfo.processInfo.environment
                env["DENO_DIR"] = directory.appendingPathComponent("deno-cache").path; env["PYTHONUNBUFFERED"] = "1"; env["NO_COLOR"] = "1"
                process.environment = env; process.standardOutput = pipe; process.standardError = pipe
                try control.start(process)
                let timer = DispatchWorkItem { control.cancel() }
                DispatchQueue.global().asyncAfter(deadline:.now()+timeout,execute:timer)
                defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
                var buffer = Data(); var lines: [String] = []; var total = 0
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    total += data.count
                    if total > 16*1024*1024 { control.cancel(); throw YouTubeImportError(message:"Загрузчик вернул слишком большой ответ.") }
                    buffer.append(data)
                    while let i = buffer.firstIndex(of:10) {
                        let line = String(decoding:buffer[..<i],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
                        buffer.removeSubrange(...i); lines.append(line); onLine(line)
                    }
                }
                if !buffer.isEmpty { let line = String(decoding:buffer,as:UTF8.self); lines.append(line); onLine(line) }
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let diagnostics = lines.filter { $0.contains("ERROR:") }.suffix(2).joined(separator:"\n")
                    throw YouTubeImportError(message:diagnostics.isEmpty ? "Загрузка прервана или время ожидания истекло. Проверьте сеть и доступность ролика." : String(diagnostics.suffix(1500)))
                }
                return lines
            }
            let result = try await task.value
            try Task.checkCancellation()
            return result
        },onCancel: { control.cancel() })
    }
}

@MainActor final class YouTubeImporter: ObservableObject {
    @Published var busy = false
    @Published var message = ""
    @Published var progress: Double = 0
    @Published var title = ""
    @Published var failure: String?
    private var task: Task<Void,Never>?
    private var token = UUID()
    let toolsFolder: URL
    init(toolsFolder: URL? = nil) {
        self.toolsFolder = toolsFolder ?? Bundle.main.resourceURL!.appendingPathComponent("ImportTools")
    }
    var available: Bool { ["yt-dlp","deno"].allSatisfy { FileManager.default.isExecutableFile(atPath:toolsFolder.appendingPathComponent($0).path) } }
    func cancel() { token = UUID(); task?.cancel(); task = nil; busy = false; message = "Загрузка отменена" }
    func start(link: String,audioOnly: Bool,height: Int,onComplete: @escaping (URL,String) throws -> Void) {
        guard !busy else { return }
        failure = nil; title = ""; progress = 0
        let url: URL
        do { url = try YouTubeLink.canonical(link) } catch { failure = error.localizedDescription; return }
        guard available else { failure = "В этой сборке нет компонентов импорта YouTube. Используйте полную сборку приложения."; return }
        busy = true; message = "Получаем информацию о ролике…"; let job = UUID(); token = job
        task = Task { [weak self] in
            guard let self else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuizYouTube-"+UUID().uuidString,isDirectory:true)
            defer { try? FileManager.default.removeItem(at:dir); if self.token == job { self.busy = false } }
            do {
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                let base = ["--ignore-config","--no-plugin-dirs","--no-remote-components","--no-js-runtimes","--js-runtimes","deno:"+toolsFolder.appendingPathComponent("deno").path,"--no-cache-dir","--no-playlist","--no-colors","--encoding","utf-8","--socket-timeout","20","--retries","2","--fragment-retries","2"]
                let lines = try await ImportProcess.run(executable:toolsFolder.appendingPathComponent("yt-dlp"),args:base+["--dump-single-json","--skip-download","--",url.absoluteString],directory:dir,timeout:90)
                try Task.checkCancellation()
                guard let json = lines.last(where: { $0.hasPrefix("{") }), let data = json.data(using:.utf8) else { throw YouTubeImportError(message:"Не удалось получить сведения о ролике.") }
                let metadata = try JSONDecoder().decode(YouTubeMetadata.self,from:data)
                let formats = try metadata.selection(audioOnly:audioOnly,height:height)
                self.title = metadata.title
                var downloaded: [URL] = []
                for (index,format) in formats.enumerated() {
                    try Task.checkCancellation()
                    let output = dir.appendingPathComponent("track-\(index).\(format.ext ?? "mp4")")
                    self.message = "Загружаем \(index+1) из \(formats.count)…"
                    _ = try await ImportProcess.run(executable:toolsFolder.appendingPathComponent("yt-dlp"),args:base+["--no-simulate","--no-part","--fixup","never","--max-filesize","1G","--newline","--progress","--progress-delta","0.2","--progress-template","download:QUIZ_PROGRESS:%(progress._percent_str)s","--format",format.format_id,"--output",output.path,"--",url.absoluteString],directory:dir,onLine:{ [weak self] line in
                        guard line.hasPrefix("QUIZ_PROGRESS:"), let value = Double(line.replacingOccurrences(of:"QUIZ_PROGRESS:",with:"").replacingOccurrences(of:"%",with:"").trimmingCharacters(in:.whitespaces)) else { return }
                        Task { @MainActor in guard let self, self.token == job else { return }; self.progress = (Double(index)+min(1,max(0,value/100)))/Double(formats.count)*0.85 }
                    })
                    guard FileManager.default.fileExists(atPath:output.path) else { throw YouTubeImportError(message:"Запись не загрузилась. Возможно, размер файла больше 1 ГБ или ролик недоступен.") }
                    downloaded.append(output)
                }
                try Task.checkCancellation(); self.message = "Подготавливаем запись для редактора…"; self.progress = 0.85
                let result = try await Self.prepare(files:downloaded,audioOnly:audioOnly,directory:dir) { [weak self] value in
                    guard let self, self.token == job else { return }; self.progress = 0.85+0.15*value
                }
                try Task.checkCancellation(); guard self.token == job else { return }
                try onComplete(result,metadata.title)
                self.progress = 1; self.message = "Запись добавлена"; self.busy = false
            } catch {
                guard self.token == job, !Task.isCancelled else { return }
                self.failure = error.localizedDescription; self.message = "Не удалось загрузить запись"
            }
        }
    }
    static func prepare(files: [URL],audioOnly: Bool,directory: URL,progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        let composition = AVMutableComposition()
        var addedVideo = false; var addedAudio = false
        for file in files {
            try Task.checkCancellation()
            let asset = AVURLAsset(url:file)
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite && duration.seconds > 0 else { throw YouTubeImportError(message:"Загружен пустой или повреждённый файл.") }
            if !audioOnly && !addedVideo, let track = try await asset.loadTracks(withMediaType:.video).first {
                let output = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
                try output.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:track,at:.zero)
                output.preferredTransform = try await track.load(.preferredTransform); addedVideo = true
            }
            if !addedAudio, let track = try await asset.loadTracks(withMediaType:.audio).first {
                let output = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
                try output.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:track,at:.zero); addedAudio = true
            }
        }
        guard addedAudio && (audioOnly || addedVideo) else { throw YouTubeImportError(message:"В файле отсутствует нужная звуковая или видеодорожка.") }
        if !audioOnly {
            let ends = composition.tracks.map { CMTimeRangeGetEnd($0.timeRange).seconds }.filter { $0.isFinite && $0 > 0 }
            if let common = ends.min(), common < composition.duration.seconds {
                composition.removeTimeRange(CMTimeRange(start:CMTime(seconds:common,preferredTimescale:60000),end:composition.duration))
            }
        }
        let output = directory.appendingPathComponent(audioOnly ? "import.m4a" : "import.mp4")
        guard let exporter = AVAssetExportSession(asset:composition,presetName:audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough) else { throw YouTubeImportError(message:"Не удалось подготовить запись.") }
        let fileType: AVFileType = audioOnly ? .m4a : .mp4
        let ticker = Task { @MainActor in
            if #available(macOS 15.0, *) {
                for await state in exporter.states(updateInterval:0.15) {
                    if Task.isCancelled { return }
                    if case .exporting(let value) = state { progress(value.fractionCompleted) }
                }
            } else {
                while !Task.isCancelled { progress(Double(exporter.progress)); try? await Task.sleep(nanoseconds:150_000_000) }
            }
        }
        defer { ticker.cancel() }
        try await exporter.export(to:output,as:fileType)
        try Task.checkCancellation()
        let asset = AVURLAsset(url:output)
        guard try await asset.load(.isPlayable) else { throw YouTubeImportError(message:"Полученная запись не поддерживается macOS.") }
        progress(1); return output
    }
    deinit { task?.cancel() }
}

struct YouTubeImportView: View {
    let onImport: (URL,String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer = YouTubeImporter()
    @State private var link = ""
    @State private var audioOnly = false
    @State private var height = 720
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Добавить с YouTube").font(.title2.bold())
            TextField("Ссылка на видео или Shorts",text:$link).textFieldStyle(.roundedBorder).disabled(importer.busy)
            Picker("Загрузить",selection:$audioOnly) { Text("Видео со звуком").tag(false); Text("Только аудио").tag(true) }.pickerStyle(.segmented).disabled(importer.busy)
            if !audioOnly { Picker("Качество не выше",selection:$height) { Text("360p").tag(360); Text("720p").tag(720); Text("1080p").tag(1080) }.disabled(importer.busy) }
            Text("После загрузки запись откроется в редакторе и сохранится внутри квиза. Для игры интернет уже не понадобится.").font(.callout)
            Text("Загружайте записи, которые вам разрешено скачивать и использовать. Закрытые ролики и прямые эфиры не поддерживаются. Доступность зависит от YouTube и сети.").font(.caption).foregroundStyle(.secondary)
            if !importer.title.isEmpty { Text(importer.title).bold().lineLimit(2) }
            if importer.busy { ProgressView(value:importer.progress); Text(importer.message).font(.caption) }
            if let error = importer.failure { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(importer.busy ? "Отменить загрузку" : "Закрыть") { importer.cancel(); dismiss() }
                Spacer()
                Button("Загрузить и открыть редактор") {
                    importer.start(link:link,audioOnly:audioOnly,height:height) { url,title in try onImport(url,title); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(importer.busy || link.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width:620).interactiveDismissDisabled(importer.busy).onDisappear { importer.cancel() }
    }
}

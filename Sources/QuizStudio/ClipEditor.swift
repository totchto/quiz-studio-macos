import SwiftUI
import AVFoundation
import AppKit

struct CensorRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var silence = false
}
struct ClipSettings: Codable, Equatable {
    var start: Double = 0
    var end: Double = 0
    var volume: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var regions: [CensorRegion] = []
    static func legacy(_ text: String) -> [CensorRegion] {
        text.split(separator: ",").compactMap { part in
            let values = part.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 2, values[0].isFinite, values[1].isFinite, values[0] >= 0, values[1] > values[0] else { return nil }
            return CensorRegion(start: values[0],end: values[1])
        }
    }
    func gain(at time: Double,range: MediaRange) -> Float {
        guard time.isFinite else { return 0 }
        let fadeA = fadeIn > 0 ? min(1,max(0,(time-range.start)/fadeIn)) : 1
        let fadeB = fadeOut > 0 ? min(1,max(0,(range.end-time)/fadeOut)) : 1
        return Float(min(1,max(0,volume)) * min(fadeA,fadeB))
    }
    func censor(at time: Double) -> CensorRegion? { regions.first { time >= $0.start && time < $0.end } }
    func audioMix(tracks: [AVAssetTrack],range: MediaRange) -> AVAudioMix {
        // Audio ramps run on the media timeline, independently of UI timer scheduling.
        var cuts = [range.start,range.end]
        if fadeIn > 0 { cuts.append(min(range.end,range.start+fadeIn)) }
        if fadeOut > 0 { cuts.append(max(range.start,range.end-fadeOut)) }
        if fadeIn > 0 && fadeOut > 0 { cuts.append((fadeOut*range.start+fadeIn*range.end)/(fadeIn+fadeOut)) }
        for r in regions { cuts += [max(range.start,min(range.end,r.start)),max(range.start,min(range.end,r.end))] }
        cuts = Array(Set(cuts.filter { $0.isFinite })).sorted()
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let params = AVMutableAudioMixInputParameters(track:track)
            params.setVolume(0,at:.zero)
            for (a,b) in zip(cuts,cuts.dropFirst()) where b > a {
                let mute = censor(at:(a+b)/2) != nil
                params.setVolumeRamp(fromStartVolume:mute ? 0 : gain(at:a,range:range),toEndVolume:mute ? 0 : gain(at:b,range:range),timeRange:CMTimeRange(start:CMTime(seconds:a,preferredTimescale:44100),end:CMTime(seconds:b,preferredTimescale:44100)))
            }
            params.setVolume(0,at:CMTime(seconds:range.end,preferredTimescale:44100))
            return params
        }
        return mix
    }
    func bounded(to duration: Double) -> ClipSettings {
        var copy = self
        copy.start = start.isFinite ? min(max(0,start),max(0,duration-0.001)) : 0
        copy.end = end.isFinite && end > 0 ? min(duration,max(copy.start+0.001,end)) : duration
        copy.volume = volume.isFinite ? min(1,max(0,volume)) : 1
        copy.fadeIn = fadeIn.isFinite ? min(max(0,fadeIn),copy.end-copy.start) : 0
        copy.fadeOut = fadeOut.isFinite ? min(max(0,fadeOut),copy.end-copy.start) : 0
        copy.regions = regions.compactMap { r in
            guard r.start.isFinite, r.end.isFinite else { return nil }
            var v = r; v.start = max(copy.start,r.start); v.end = min(copy.end,r.end)
            return v.end > v.start ? v : nil
        }
        return copy
    }
}
extension Question {
    func settings(answer: Bool) -> ClipSettings {
        if answer { return answerClip ?? (explanationMedia != nil ? ClipSettings() : ClipSettings(start:start,end:end)) }
        return questionClip ?? ClipSettings(start:start,end:end,regions:ClipSettings.legacy(bleepRanges))
    }
}
struct WaveformData {
    var duration: Double
    var peaks: [Float]
    var thumbnails: [NSImage]
    var hasAudio: Bool
    var hasVideo = false
    var frameStep: Double = 1/25
    static func read(_ url: URL) async throws -> WaveformData {
        let asset = AVURLAsset(url:url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        let tracks = try await asset.loadTracks(withMediaType:.audio)
        var peaks = [Float](repeating:0,count:2400)
        if let track = tracks.first {
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let bytes = CMBlockBufferGetDataLength(block)
                var data = [Float](repeating:0,count:bytes/4)
                let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { continue }
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let span = CMSampleBufferGetDuration(sample).seconds
                for (i,value) in data.enumerated() where value.isFinite {
                    let t = start + (span.isFinite ? span : 0) * Double(i)/Double(max(1,data.count))
                    let bin = min(peaks.count-1,max(0,Int(t/duration*Double(peaks.count))))
                    peaks[bin] = max(peaks[bin],abs(value))
                }
            }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        }
        var thumbnails: [NSImage] = []
        let videoTracks = try await asset.loadTracks(withMediaType:.video)
        var frameStep: Double = 1/25
        if let track = videoTracks.first {
            let minimum = try await track.load(.minFrameDuration).seconds
            let rate = try await track.load(.nominalFrameRate)
            if minimum.isFinite && minimum > 0 { frameStep = minimum }
            else if rate.isFinite && rate > 0 { frameStep = 1/Double(rate) }
            let generator = AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width:160,height:90)
            for i in 0..<10 {
                try Task.checkCancellation()
                if let image = try? generator.copyCGImage(at:CMTime(seconds:duration*Double(i)/10,preferredTimescale:600),actualTime:nil) { thumbnails.append(NSImage(cgImage:image,size:.zero)) }
            }
        }
        let maximum = peaks.max() ?? 0
        if maximum > 0 { peaks = peaks.map { sqrt($0/maximum) } }
        return WaveformData(duration:duration,peaks:peaks,thumbnails:thumbnails,hasAudio:!tracks.isEmpty,hasVideo:!videoTracks.isEmpty,frameStep:frameStep)
    }
}

struct ClipEditor: View {
    @Binding var question: Question
    let questionURL: URL
    let answerURL: URL
    var initialAnswer = false
    @Environment(\.dismiss) var dismiss
    @StateObject private var preview = MediaSession()
    @StateObject private var scrubber = VideoScrubber()
    @State private var answer = false
    @State private var questionAudioOnly = false
    @State private var answerShowsVideo = true
    @State private var snapToFrames = true
    @State private var frames: [VideoFrame] = []
    @State private var framesLoading = false
    @State private var analysisCache: [URL: WaveformData] = [:]
    @State private var questionDraft = ClipSettings()
    @State private var answerDraft = ClipSettings()
    @State private var wave: WaveformData?
    @State private var loadError: String?
    @State private var zoom: Double = 1
    @State private var cropView = false
    @State private var censorMode = false
    @State private var silence = false
    @State private var loop = false
    @State private var cursor: Double = 0
    @State private var selection: ClosedRange<Double>?
    @State private var history: [(ClipSettings,ClipSettings)] = []
    @State private var dragSaved = false
    @State private var dragRange: ClosedRange<Double>?
    @State private var loader: Task<Void,Never>?
    var draft: ClipSettings { answer ? answerDraft : questionDraft }
    var sourceURL: URL { answer ? answerURL : questionURL }
    var visibleRange: ClosedRange<Double> {
        if let dragRange { return dragRange }
        guard let wave else { return 0...1 }
        let clip = draft.bounded(to:wave.duration)
        return cropView ? clip.start...clip.end : 0...wave.duration
    }
    func remember() { history.append((questionDraft,answerDraft)); if history.count > 100 { history.removeFirst() } }
    func update(_ value: ClipSettings) { if answer { answerDraft = value } else { questionDraft = value } }
    func load() {
        preview.stop(); scrubber.clear(); frames = []; loader?.cancel(); wave = nil; loadError = nil; selection = nil; zoom = 1; cropView = false; dragRange = nil; dragSaved = false
        let url = sourceURL
        loader = Task { @MainActor in
            do {
                let value: WaveformData
                if let cached = analysisCache[url] { value = cached }
                else {
                    let task = Task.detached(priority:.userInitiated) { try await WaveformData.read(url) }
                    value = try await withTaskCancellationHandler(operation: { try await task.value },onCancel: { task.cancel() })
                }
                guard !Task.isCancelled else { return }
                analysisCache[url] = value; wave = value; update(draft.bounded(to:value.duration)); cursor = draft.start
                if value.hasVideo { scrub(to:cursor,immediate:true) }
                preview.start(url:url,start:draft.start,end:draft.end,autoplay:false,effects:draft)
            } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
    }
    func play(from time: Double? = nil) {
        guard let wave else { return }
        let c = draft.bounded(to:wave.duration)
        let from = min(c.end-0.0001,max(c.start,time ?? c.start))
        preview.start(url:sourceURL,start:from,end:c.end,effects:c)
    }
    func prepareAtCursor() {
        guard let wave else { return }
        let c = draft.bounded(to:wave.duration)
        preview.start(url:sourceURL,start:min(c.end-0.0001,max(c.start,cursor)),end:c.end,autoplay:false,effects:c)
    }
    func timelineTime(_ value: Double) -> Double {
        guard let wave else { return value }
        if wave.hasVideo && snapToFrames { return min(wave.duration,max(0,(value/wave.frameStep).rounded()*wave.frameStep)) }
        return min(wave.duration,max(0,value))
    }
    func scrub(to time: Double,immediate: Bool = false) {
        guard let wave, wave.hasVideo else { return }
        scrubber.seek(url:sourceURL,time:VideoFrames.clamped(time,duration:wave.duration,step:wave.frameStep),immediate:immediate)
    }
    func moveCursor(_ time: Double) {
        preview.stop(); cursor = timelineTime(time); scrub(to:cursor,immediate:true)
    }
    func setBoundary(end: Bool) {
        guard let wave else { return }; remember(); var c = draft
        if end { c.end = max(c.start+0.001,min(wave.duration,cursor+wave.frameStep)) }
        else { c.start = min(c.end-0.001,max(0,cursor)) }
        update(c.bounded(to:wave.duration)); preview.stop(); scrub(to:cursor,immediate:true)
    }
    var stripIdentity: String {
        guard let wave, wave.hasVideo else { return "audio" }
        return "\(sourceURL.path)|\(visibleRange.lowerBound)|\(visibleRange.upperBound)|\(Int(ceil(zoom)))"
    }
    @ViewBuilder func videoPreview(_ wave: WaveformData) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Label("Видео · \(1/wave.frameStep,specifier:"%.2f") кадр/с",systemImage:"film")
                Spacer()
                if answer { Toggle("Показывать видео в ответе",isOn:$answerShowsVideo).toggleStyle(.checkbox) }
                else { Toggle("В вопросе только звук",isOn:$questionAudioOnly).toggleStyle(.checkbox) }
            }.font(.caption)
            ZStack {
                Color.black
                if let player = preview.player, !preview.finished { NativeMediaView(player:player,controls:false) }
                else if let frame = scrubber.frame { Image(nsImage:frame.image).resizable().scaledToFit() }
                else { Text("Загружаем кадр…").foregroundStyle(.white) }
                if scrubber.loading { ProgressView().padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing).padding(8) }
            }.frame(height:220).clipShape(RoundedRectangle(cornerRadius:8))
            if let error = scrubber.error { Text("Не удалось показать кадр: " + error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("◀ Кадр") { moveCursor((preview.player != nil ? preview.position : cursor)-wave.frameStep) }
                Button("Кадр ▶") { moveCursor((preview.player != nil ? preview.position : cursor)+wave.frameStep) }
                Text("Курсор: \(cursor,specifier:"%.3f") с").monospacedDigit()
                Spacer()
                Button("Начало здесь") { setBoundary(end:false) }
                Button("Конец после кадра") { setBoundary(end:true) }
                Toggle("Привязка к кадрам",isOn:$snapToFrames).toggleStyle(.checkbox)
            }.font(.caption)
            Text("Изображение видно для монтажа. В игре используется выбранный режим: \((answer ? !answerShowsVideo : questionAudioOnly) ? "только звук" : "видео со звуком").").font(.caption).foregroundStyle(.secondary)
            if !wave.hasAudio { Label("В этом видео нет звуковой дорожки",systemImage:"speaker.slash").font(.caption).foregroundStyle(.secondary) }
        }
    }
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading) { Text("Редактор аудио и видео").font(.title2.bold()); Text(sourceURL.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить") {
                    question.questionClip = questionDraft; question.answerClip = answerDraft
                    question.audioOnly = questionAudioOnly; question.answerVideo = answerShowsVideo
                    question.start = questionDraft.start; question.end = questionDraft.end
                    question.bleepRanges = questionDraft.regions.filter { !$0.silence }.map { "\($0.start)-\($0.end)" }.joined(separator:", ")
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(wave == nil)
            }
            Picker("Фрагмент",selection:$answer) { Text("Вопрос").tag(false); Text("Ответ").tag(true) }.pickerStyle(.segmented)
            Text(answer ? "Отдельный фрагмент для ответа. Если добавлен файл объяснения, редактируется он." : "Выделите фрагмент мышью или двигайте его границы. Оригинал сохраняется целиком.").font(.caption).foregroundStyle(.secondary)
            if let error = loadError { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red); Button("Повторить") { load() } }
            else if let wave {
                if wave.hasVideo { videoPreview(wave) }
                HStack {
                    Button { if let last = history.popLast() { questionDraft = last.0; answerDraft = last.1; preview.stop() } } label: { Label("Отменить действие",systemImage:"arrow.uturn.backward") }.disabled(history.isEmpty)
                    Spacer()
                    Toggle("Только фрагмент",isOn:$cropView).toggleStyle(.checkbox)
                    Text("Масштаб"); Slider(value:$zoom,in:1...12).frame(width:120)
                }
                ScrollView(.horizontal) {
                    timeline(wave).frame(width:860*zoom,height:wave.hasVideo ? 210 : 150)
                }.frame(height:wave.hasVideo ? 225 : 165).background(.black.opacity(0.15),in:RoundedRectangle(cornerRadius:10))
                .task(id:stripIdentity) {
                    guard wave.hasVideo else { return }; framesLoading = true
                    do {
                        let result = try await VideoFrames.strip(url:sourceURL,range:visibleRange,count:Int(ceil(zoom))*10)
                        guard !Task.isCancelled else { return }; frames = result; framesLoading = false
                    } catch { if !Task.isCancelled { framesLoading = false } }
                }
                if framesLoading { Text("Обновляем кадры дорожки…").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("▶ С начала фрагмента") { play() }
                    Button("▶ От курсора") { play(from:cursor) }
                    Button("Пауза") { preview.setPaused(true) }
                    Button("Продолжить") { preview.setPaused(false) }.disabled(preview.finished)
                    Button("Стоп") { preview.stop() }
                    Toggle("Повтор",isOn:$loop).toggleStyle(.checkbox)
                    Spacer(); Text("\(preview.position,specifier:"%.2f") / \(wave.duration,specifier:"%.2f") с").monospacedDigit()
                }.font(.caption)
                HStack {
                    Text("Начало"); timeField(\.start)
                    Text("Конец"); timeField(\.end)
                    Text("Длина: \(max(0,draft.end-draft.start),specifier:"%.2f") с").foregroundStyle(.secondary)
                    if answer && answerURL == questionURL { Button("Как в вопросе") { remember(); var c = questionDraft; c.regions = []; update(c.bounded(to:wave.duration)); preview.stop() } }
                    Spacer()
                    Button("Вся запись") { remember(); var c = draft; c.start = 0; c.end = wave.duration; update(c); cropView = false; preview.stop() }
                }
                HStack {
                    Text("Громкость"); Slider(value:Binding(get:{draft.volume},set:{ v in remember(); var c = draft; c.volume = v; update(c); preview.stop() }),in:0...1).frame(width:160)
                    Text("\(Int(draft.volume*100))%")
                    Text("Нарастание, с"); timeField(\.fadeIn)
                    Text("Затухание, с"); timeField(\.fadeOut)
                }.font(.caption)
                HStack {
                    Toggle("Выделять участок для заглушки",isOn:$censorMode).toggleStyle(.checkbox)
                    Toggle("Тишина вместо сигнала",isOn:$silence).toggleStyle(.checkbox)
                    Button("Добавить участок") {
                        guard let selection else { return }; remember(); var c = draft
                        c.regions.append(CensorRegion(start:selection.lowerBound,end:selection.upperBound,silence:silence)); update(c.bounded(to:wave.duration)); self.selection = nil; preview.stop()
                    }.disabled(selection == nil)
                }.font(.caption)
                ScrollView {
                    VStack(alignment:.leading,spacing:6) {
                        ForEach(draft.regions) { region in
                            HStack { Label(region.silence ? "Тишина" : "Сигнал",systemImage:region.silence ? "speaker.slash" : "waveform"); Text("\(region.start-draft.start,specifier:"%.2f") – \(region.end-draft.start,specifier:"%.2f") с фрагмента").monospacedDigit(); Spacer(); Button("Удалить") { remember(); var c = draft; c.regions.removeAll { $0.id == region.id }; update(c); preview.stop() } }.font(.caption)
                        }
                    }
                }.frame(maxHeight:85)
                Text("Оранжевые участки — заглушки. Щелчок по дорожке ставит курсор; выделение задаёт фрагмент или участок заглушки. Предпросмотр учитывает громкость, плавные края и заглушки.").font(.caption).foregroundStyle(.secondary)
            } else if loadError == nil { Spacer(); ProgressView("Строим звуковую дорожку и кадры…").frame(maxWidth:.infinity); Spacer() }
            if let error = preview.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24)
        }.frame(width:940,height:min(850,(NSScreen.main?.visibleFrame.height ?? 950)-100)).textFieldStyle(.roundedBorder)
        .onAppear { questionDraft = question.settings(answer:false); answerDraft = question.settings(answer:true); questionAudioOnly = question.audioOnly; answerShowsVideo = question.answerVideo; if initialAnswer { answer = true } else { load() } }
        .onChange(of:answer) { _,_ in load() }
        .onChange(of:preview.finished) { old,done in if !old && done && loop && preview.player != nil && preview.error == nil { play() } }
        .onDisappear { loader?.cancel(); scrubber.clear(); preview.stop() }
    }
    func timeField(_ key: WritableKeyPath<ClipSettings,Double>) -> some View {
        TextField("Секунды",value:Binding(get:{ draft[keyPath:key] },set:{ v in
            guard let wave, v.isFinite else { return }; remember(); var c = draft; c[keyPath:key] = v; update(c.bounded(to:wave.duration)); preview.stop(); cursor = key == \.end ? c.end : c.start; scrub(to:cursor,immediate:true)
        }),format:.number.precision(.fractionLength(0...2))).frame(width:75)
    }
    func timeline(_ wave: WaveformData) -> some View {
        GeometryReader { geo in
            let range = visibleRange
            let span = max(0.001,range.upperBound-range.lowerBound)
            let width = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat(($0-range.lowerBound)/span)*width }
            let y: CGFloat = wave.hasVideo ? 95 : 35
            ZStack(alignment:.topLeading) {
                Canvas { ctx,size in
                    if wave.hasVideo {
                        for (i,frame) in frames.enumerated() {
                            let next = i+1 < frames.count ? frames[i+1].time : range.upperBound
                            ctx.draw(Image(nsImage:frame.image),in:CGRect(x:x(frame.time),y:0,width:max(1,x(next)-x(frame.time)),height:70))
                        }
                    }
                    var path = Path()
                    let count = max(1,Int(size.width/2))
                    for i in 0..<count {
                        let time = range.lowerBound + Double(i)/Double(count)*span
                        let bin = min(wave.peaks.count-1,max(0,Int(time/wave.duration*Double(wave.peaks.count))))
                        let h = CGFloat(max(0.015,wave.peaks[bin]))*38
                        let px = CGFloat(i)*size.width/CGFloat(count)
                        path.move(to:CGPoint(x:px,y:y+40-h)); path.addLine(to:CGPoint(x:px,y:y+40+h))
                    }
                    ctx.stroke(path,with:.color(.cyan),lineWidth:1)
                    ctx.fill(Path(CGRect(x:x(draft.start),y:y-5,width:x(draft.end)-x(draft.start),height:90)),with:.color(.indigo.opacity(0.22)))
                    for r in draft.regions {
                        ctx.fill(Path(CGRect(x:x(r.start),y:y-5,width:max(2,x(r.end)-x(r.start)),height:90)),with:.color(.orange.opacity(0.6)))
                    }
                    if let selection { ctx.fill(Path(CGRect(x:x(selection.lowerBound),y:y-5,width:x(selection.upperBound)-x(selection.lowerBound),height:90)),with:.color(.yellow.opacity(0.4))) }
                    for i in 0...10 {
                        let t = range.lowerBound+Double(i)/10*span
                        ctx.draw(Text(String(format:"%.1f",t)).font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:CGFloat(i)/10*size.width,y:size.height-10))
                    }
                    for t in [cursor,preview.position] where t >= range.lowerBound && t <= range.upperBound {
                        var line = Path(); line.move(to:CGPoint(x:x(t),y:y-5)); line.addLine(to:CGPoint(x:x(t),y:y+85)); ctx.stroke(line,with:.color(t == cursor ? .yellow : .white),lineWidth:1.5)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { event in
                    if !dragSaved { remember(); preview.stop(); dragRange = range; dragSaved = true }
                    let a = range.lowerBound+min(1,max(0,event.startLocation.x/width))*span
                    let b = range.lowerBound+min(1,max(0,event.location.x/width))*span
                    cursor = timelineTime(b); scrub(to:cursor)
                    if abs(event.translation.width) > 3 {
                        if censorMode { selection = max(draft.start,min(a,b))...max(max(draft.start,min(a,b)),min(draft.end,max(a,b))) }
                        else { var c = draft; c.start = timelineTime(min(a,b)); c.end = timelineTime(max(a,b)); update(c.bounded(to:wave.duration)) }
                    }
                }.onEnded { _ in dragSaved = false; dragRange = nil; if let selection, selection.upperBound-selection.lowerBound < 0.02 { self.selection = nil }; scrub(to:cursor,immediate:true); prepareAtCursor() })
                ForEach([false,true],id:\.self) { endHandle in
                    let t = endHandle ? draft.end : draft.start
                    RoundedRectangle(cornerRadius:3).fill(.indigo).frame(width:10,height:90).offset(x:min(width-10,max(0,x(t)-5)),y:y-5)
                        .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("clipTimeline")).onChanged { event in
                            if !dragSaved { remember(); preview.stop(); dragRange = range; dragSaved = true }
                            let t = timelineTime(range.lowerBound + min(1,max(0,event.location.x/width))*span)
                            var c = draft
                            if endHandle { c.end = max(c.start+0.001,t) } else { c.start = min(c.end-0.001,t) }
                            update(c.bounded(to:wave.duration)); cursor = t; scrub(to:t)
                        }.onEnded { _ in dragSaved = false; dragRange = nil; scrub(to:cursor,immediate:true); prepareAtCursor() })
                }
            }.clipped().coordinateSpace(name:"clipTimeline")
        }
    }
}

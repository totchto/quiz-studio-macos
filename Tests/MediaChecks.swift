import ImageIO
struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct MediaChecks {
 @MainActor static func wait(_ name: String,_ predicate: () -> Bool) async throws {
  for _ in 0..<150 { if predicate() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
  throw NSError(domain: "MediaChecks",code: 1,userInfo: [NSLocalizedDescriptionKey:"Timeout: " + name])
 }
 @MainActor static func video(_ url: URL,portrait: Bool = false) async throws {
  let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 160,AVVideoHeightKey: 120])
  if portrait { input.transform = CGAffineTransform(rotationAngle:.pi/2) }
  if #available(macOS 26.0, *) {
   let receiver = writer.inputPixelBufferReceiver(for:input,pixelBufferAttributes:nil)
   try writer.start(); writer.startSession(atSourceTime:.zero)
   for frame in 0..<60 {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,nil,&buffer) == kCVReturnSuccess, let buffer else { throw CocoaError(.fileWriteUnknown) }
    CVPixelBufferLockBaseAddress(buffer,[])
    let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    for i in stride(from: 0,to: count,by: 4) { address[i]=UInt8(frame*3); address[i+1]=80; address[i+2]=120; address[i+3]=255 }
    CVPixelBufferUnlockBaseAddress(buffer,[])
    try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer:buffer),with:CMTime(value:Int64(frame),timescale:30))
   }
   receiver.finish()
  } else {
   let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:160,kCVPixelBufferHeightKey as String:120])
   writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime:.zero)
   for frame in 0..<60 {
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds:5_000_000) }
    var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)
    guard let buffer else { fatalError("pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer,[])
    let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
    let count = CVPixelBufferGetBytesPerRow(buffer)*CVPixelBufferGetHeight(buffer)
    for i in stride(from:0,to:count,by:4) { address[i]=UInt8(frame*3); address[i+1]=80; address[i+2]=120; address[i+3]=255 }
    CVPixelBufferUnlockBaseAddress(buffer,[])
    guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else { throw writer.error! }
   }
   input.markAsFinished()
  }
  await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error! }
 }
 @MainActor static func check(_ file: URL,start: Double,end: Double,expectVideo: Bool) async throws {
  let session = MediaSession(); session.start(url:file,start:start,end:end,autoplay:false)
  try await wait("prepare " + file.pathExtension) { !session.loading }
  guard session.error == nil else { throw NSError(domain:"MediaChecks",code:2,userInfo:[NSLocalizedDescriptionKey:session.error!]) }
  assert(session.hasVideo == expectVideo && !session.finished)
  assert(abs(session.player!.currentTime().seconds-start) < 0.08)
  session.player!.volume = 0 // Silent test: exercise decoding and the playback clock without playing music aloud.
  let host = NSHostingView(rootView: MediaPreview(session:session)); host.frame = NSRect(x:0,y:0,width:500,height:260); host.layoutSubtreeIfNeeded()
  session.setPaused(false)
  try await wait("advance " + file.pathExtension) { session.player!.currentTime().seconds > start+0.2 }
  session.setPaused(true); let pausedTime=session.player!.currentTime().seconds
  try await Task.sleep(nanoseconds: 350_000_000)
  assert(abs(session.player!.currentTime().seconds-pausedTime) < 0.08)
  session.setPaused(false)
  try await wait("clip end " + file.pathExtension) { session.finished }
  assert(abs(session.player!.currentTime().seconds-end) < 0.15)
  assert(session.error == nil)
  session.stop(); assert(session.player == nil && !session.loading)
  print("PASS: " + file.pathExtension + " ready, native preview render, seek, playback clock, pause/resume, exact fragment end, cleanup")
 }
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let wav=root.appendingPathComponent("tone.wav")
  try await check(wav,start:0.4,end:1.3,expectVideo:false)
  if CommandLine.arguments.count>2 { try await check(URL(fileURLWithPath:CommandLine.arguments[2]),start:10,end:11.2,expectVideo:false) }
  let movie=root.appendingPathComponent("test.mp4"); try await video(movie); try await check(movie,start:0.3,end:1.2,expectVideo:true)
  let waveform = try await Task.detached { try await WaveformData.read(wav) }.value
  assert(abs(waveform.duration-3) < 0.01 && waveform.hasAudio && waveform.peaks.count == 2400 && waveform.peaks.max()! > 0.9)
  let videoWave = try await Task.detached { try await WaveformData.read(movie) }.value
  assert(!videoWave.hasAudio && !videoWave.thumbnails.isEmpty)
  assert(videoWave.hasVideo && abs(videoWave.frameStep-1/30) < 0.0001)
  let frameA = try await VideoFrames.image(url:movie,time:0.2)
  let frameB = try await VideoFrames.image(url:movie,time:1.2)
  assert(abs(frameA.time-0.2) < 0.034 && abs(frameB.time-1.2) < 0.034 && frameA.image.tiffRepresentation != frameB.image.tiffRepresentation)
  let strip = try await VideoFrames.strip(url:movie,range:0.3...1.5,count:20)
  assert(strip.count == 20 && abs(strip[0].time-0.3) < 0.001 && strip.last!.time < 1.5)
  let portrait = root.appendingPathComponent("portrait.mov"); try await video(portrait,portrait:true)
  let portraitFrame = try await VideoFrames.image(url:portrait,time:0.4)
  assert(portraitFrame.image.size.height > portraitFrame.image.size.width)
  let cancelledFrames = Task { try await VideoFrames.strip(url:movie,range:0...1.9,count:96) }
  cancelledFrames.cancel()
  do { _ = try await cancelledFrames.value; fatalError("cancelled frames completed") } catch is CancellationError {} catch { /* cancelled AVFoundation read may report its own cancellation */ }
  assert(VideoFrames.clamped(2,duration:2,step:1/30) < 2)
  let scrub = VideoScrubber(); scrub.seek(url:movie,time:0.2); scrub.seek(url:movie,time:1.2,immediate:true)
  try await wait("latest requested video frame") { !scrub.loading && scrub.frame != nil }
  assert(abs(scrub.frame!.time-1.2) < 0.034); scrub.clear(); assert(scrub.frame == nil && !scrub.loading)
  // Create a real video+audio file so both tracks and censorship are exercised together.
  let composition = AVMutableComposition()
  let videoAsset = AVURLAsset(url:movie); let audioAsset = AVURLAsset(url:wav)
  let vTrack = try await videoAsset.loadTracks(withMediaType:.video).first!
  let aTrack = try await audioAsset.loadTracks(withMediaType:.audio).first!
  try composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:1.8,preferredTimescale:600)),of:vTrack,at:.zero)
  try composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:1.8,preferredTimescale:600)),of:aTrack,at:.zero)
  let avFile = root.appendingPathComponent("with-sound.mp4")
  let export = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality)!
  try await export.export(to:avFile,as:.mp4)
  let avWave = try await Task.detached { try await WaveformData.read(avFile) }.value
  assert(avWave.hasVideo && avWave.hasAudio && avWave.peaks.max()! > 0.9)
  let avSession = MediaSession(); let avSettings = ClipSettings(start:0.2,end:1.5,regions:[CensorRegion(start:0.6,end:0.9,silence:true)])
  avSession.start(url:avFile,start:0.2,end:1.5,autoplay:false,effects:avSettings)
  try await wait("video plus edited audio") { !avSession.loading }
  assert(avSession.hasVideo && avSession.error == nil && avSession.player?.currentItem?.audioMix != nil)
  avSession.stop()
  var modes = Question(); modes.audioOnly = true; modes.answerVideo = true
  assert(!modes.showsVideo(answer:false) && modes.showsVideo(answer:true))
  modes.explanationMedia = "different.mp4"; modes.answerVideo = false
  assert(!modes.showsVideo(answer:true))
  if let path = ProcessInfo.processInfo.environment["QUIZ_VIDEO_FIXTURE"] { try FileManager.default.copyItem(at:avFile,to:URL(fileURLWithPath:path)) }
  print("PASS: frame-accurate video scrubbing, adaptive filmstrip, portrait transform, cancellation, real video+audio editing, question audio-only and hidden answer video")
  let settings = ClipSettings(start:0.2,end:2.8,volume:0.6,fadeIn:0.3,fadeOut:0.3,regions:[CensorRegion(start:0.8,end:1.1),CensorRegion(start:1.6,end:1.9,silence:true)])
  let range = try MediaRange.resolve(start:settings.start,end:settings.end,duration:3)
  assert(settings.gain(at:0.2,range:range) == 0 && abs(settings.gain(at:0.35,range:range)-0.3) < 0.001)
  assert(settings.censor(at:0.9) != nil && settings.censor(at:1.1) == nil && settings.censor(at:1.7)?.silence == true)
  let asset = AVURLAsset(url:wav); let tracks = try await asset.loadTracks(withMediaType:.audio)
  let reader = try AVAssetReader(asset:asset)
  let audio = AVAssetReaderAudioMixOutput(audioTracks:tracks,audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
  audio.audioMix = settings.audioMix(tracks:tracks,range:range)
  var mutePeak: Float = 0; var normalPeak: Float = 0
  func inspect(_ sample: CMSampleBuffer) {
   guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
   let count = CMBlockBufferGetDataLength(block)/4
   var data = [Float](repeating:0,count:count)
   _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count*4,destination:$0.baseAddress!) }
   let base = CMSampleBufferGetPresentationTimeStamp(sample).seconds
   for (i,v) in data.enumerated() {
    let t = base+Double(i)/44100
    if (0.85...1.05).contains(t) || (1.65...1.85).contains(t) { mutePeak = max(mutePeak,abs(v)) }
    if (1.25...1.45).contains(t) { normalPeak = max(normalPeak,abs(v)) }
   }
  }
  if #available(macOS 26.0, *) {
   let provider = reader.outputProvider(for:audio); try reader.start()
   while let sample = try await provider.next() { sample.withUnsafeSampleBuffer { inspect($0) } }
  } else {
   reader.add(audio); assert(reader.startReading())
   while let sample = audio.copyNextSampleBuffer() { inspect(sample) }
  }
  assert(reader.status == .completed && mutePeak < 0.0001 && normalPeak > 0.02 && normalPeak < 0.07)
  let configured = MediaSession(); configured.start(url:wav,start:settings.start,end:settings.end,autoplay:false,effects:settings)
  try await wait("edited clip prepared") { !configured.loading }
  assert(configured.error == nil && configured.player?.currentItem?.audioMix != nil); configured.stop()
  var edited = Question(); edited.media = "tone.wav"; edited.start = 0.2; edited.end = 2.8; edited.bleepRanges = "0.8-1.1"
  assert(edited.settings(answer:false).regions.count == 1 && edited.settings(answer:true).regions.isEmpty)
  edited.questionClip = settings; edited.answerClip = ClipSettings(start:1.2,end:2.4)
  let loaded = try JSONDecoder().decode(Question.self,from:JSONEncoder().encode(edited))
  assert(loaded.questionClip == settings && loaded.settings(answer:true).start == 1.2)
  let invalidBounds = ClipSettings(start:99,end:100,regions:[CensorRegion(start:0,end:1)]).bounded(to:3)
  assert(invalidBounds.start < invalidBounds.end && invalidBounds.end == 3 && invalidBounds.regions.isEmpty)
  let editorHost = NSHostingView(rootView:ClipEditor(question:.constant(edited),questionURL:wav,answerURL:wav))
  editorHost.frame = NSRect(x:0,y:0,width:940,height:850); editorHost.layoutSubtreeIfNeeded()
  print("PASS: waveform PCM decoding, silent-video thumbnails, sample-timed censorship audio mix, gain/fades, independent answer clip, legacy migration, Codable roundtrip and editor layout")
  let bad=root.appendingPathComponent("bad.mp3"); try Data([1,2,3,4]).write(to:bad)
  let invalid=MediaSession(); invalid.start(url:bad)
  try await wait("invalid file handled") { invalid.finished && invalid.error != nil }; assert(!invalid.loading)
  invalid.start(url:wav,start:100,end:101)
  try await wait("out-of-range handled") { invalid.finished && invalid.error != nil }
  invalid.start(url:wav); invalid.stop(); try await Task.sleep(nanoseconds:300_000_000); assert(invalid.player == nil && invalid.finished && invalid.error == nil)
  print("PASS: malformed media and invalid fragment fail safely; cancelled load does not restart playback")
  let quiz=Studio(draftURL:root.appendingPathComponent("Draft.workspace")); quiz.timer?.invalidate()
  var question=Question(); question.text="Аудиовопрос"; question.answer="Ответ"; question.media="tone.wav"; question.start=0.4; question.end=1.0; question.afterMedia=true; question.seconds=5; question.editorialReviewStatus = .reviewed; question.answerVideo = false
  let media=root.appendingPathComponent("Media"); try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true); try FileManager.default.copyItem(at:wav,to:media.appendingPathComponent("tone.wav"))
  quiz.folder=root; quiz.quiz.rounds[0].questions=[question]; quiz.start()
  for _ in 0..<20 { quiz.tick() }; assert(quiz.remaining==5) // Loading must not consume discussion time.
  try await wait("quiz audio ready") { !quiz.playback.loading }; quiz.player?.volume=0
  try await wait("quiz audio finish") { quiz.playback.finished }; quiz.tick(); assert(!quiz.waitingForMedia)
  for _ in 0..<6 { quiz.tick() }; assert(quiz.remaining==4)
  for afterMedia in [true,false] {
   quiz.quiz.rounds[0].questions[0].afterMedia = afterMedia
   quiz.readBeforeTimer = true; quiz.enter()
   try await wait("reading media prepared") { !quiz.playback.loading }
   quiz.player?.volume = 0
   try await Task.sleep(nanoseconds:250_000_000)
   for _ in 0..<10 { quiz.tick() }
   assert(quiz.awaitingQuestionStart && quiz.remaining == 5 && quiz.player?.rate == 0)
   assert(abs(quiz.player!.currentTime().seconds-0.4) < 0.1)
   quiz.startQuestionTimer()
   for _ in 0..<6 { quiz.tick() }
   assert(quiz.remaining == (afterMedia ? 5 : 4))
   try await wait("reading media finished") { quiz.playback.finished }; quiz.tick()
   assert(!quiz.waitingForMedia)
  }
  print("PASS: media stays silent during reading; start launches clip with timer during/after media")
  quiz.stop(); assert(quiz.player==nil)
  print("PASS: quiz uses the same safe player, waits for media before discussion timer and stops on exit")
  let editedGame = Studio(draftURL:root.appendingPathComponent("edited-draft.quiz")); editedGame.timer?.invalidate()
  edited.text = "Фрагмент вопроса и отдельный ответ"; edited.answer = "Ответ"; editedGame.folder = root
  editedGame.quiz.rounds[0].questions = [edited]; editedGame.readBeforeTimer = true; editedGame.start()
  try await wait("edited game question") { !editedGame.playback.loading }
  assert(editedGame.playback.clip?.start == 0.2 && editedGame.playback.clip?.end == 2.8 && editedGame.player?.currentItem?.audioMix != nil)
  let answerStep = editedGame.steps.firstIndex { $0.kind == .answer }!; editedGame.jump(to:answerStep)
  try await wait("independent answer in game") { !editedGame.playback.loading }
  assert(editedGame.playback.clip?.start == 1.2 && editedGame.playback.clip?.end == 2.4 && editedGame.player?.rate == 0)
  editedGame.checkpoint(copyAssets:true)
  let editedRecovery = Studio(draftURL:editedGame.draft); editedRecovery.timer?.invalidate(); editedRecovery.restoreGame()
  try await wait("edited answer recovery") { !editedRecovery.playback.loading }
  assert(editedRecovery.playback.clip?.end == 2.4 && editedRecovery.player?.currentItem?.audioMix != nil)
  let editedFile = root.appendingPathComponent("edited-portable.quiz"); try editedGame.write(to:editedFile)
  let editedArchive = try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:editedFile))
  assert(editedArchive.quiz.rounds[0].questions[0].questionClip == settings && editedArchive.assets["tone.wav"] == (try? Data(contentsOf:wav)))
  editedRecovery.stop(); editedGame.stop()
  print("PASS: edited clips used in real question/answer playback, paused recovery preserves answer end/effects and portable quiz retains original audio unchanged")
  let musicDomain = "QuizStudio.MusicChecks." + UUID().uuidString
  let musicDefaults = UserDefaults(suiteName: musicDomain)!
  defer { musicDefaults.removePersistentDomain(forName: musicDomain) }
  let supplied = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : root.appendingPathComponent("NoSuppliedMusic")
  let music = BackgroundMusic(localFolder: root.appendingPathComponent("LocalMusic"),suppliedFolder: supplied,defaults: musicDefaults)
  if CommandLine.arguments.count > 3 {
   assert(music.tracks.count == 9)
   for track in music.tracks {
    let asset = AVURLAsset(url: music.url(track))
    let playable = try await asset.load(.isPlayable); assert(playable)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio); assert(!audioTracks.isEmpty)
   }
  }
  await music.importFiles([wav,bad])
  let custom = music.tracks.filter { !$0.supplied }; assert(custom.count == 1)
  assert(music.url(custom[0]).deletingLastPathComponent().path == music.localFolder.path)
  assert(FileManager.default.fileExists(atPath: music.url(custom[0]).path))
  music.selected = Set(custom.map(\.id)); music.enabled = true; music.shuffle = false; music.volume = 0.3
  let restoredMusic = BackgroundMusic(localFolder: music.localFolder,suppliedFolder: supplied,defaults: musicDefaults)
  assert(restoredMusic.enabled && restoredMusic.volume == 0.3 && restoredMusic.selected == music.selected && restoredMusic.tracks == music.tracks)
  music.beginGame(); music.tick(mediaActive:false)
  try await wait("background ready") { !music.session.loading }
  music.session.player?.isMuted = true
  assert(music.session.player?.volume == 0)
  for _ in 0..<12 { music.tick(mediaActive:false) }; assert(abs(music.session.player!.volume-0.3)<0.001)
  for _ in 0..<8 { music.tick(mediaActive:true) }; assert(music.session.player?.volume == 0)
  music.speaking = true
  for _ in 0..<8 { music.tick(mediaActive:false) }; assert(abs(music.session.player!.volume-0.06)<0.001)
  music.muted = true; for _ in 0..<8 { music.tick(mediaActive:false) }; assert(music.session.player?.volume == 0)
  try await wait("background track end") { music.session.finished }
  music.tick(mediaActive:false); assert(music.currentID == custom[0].id && music.session.loading)
  music.enabled = false; music.tick(mediaActive:false); assert(music.session.player == nil)
  music.enabled = true; music.tick(mediaActive:false); assert(music.session.loading)
  music.stop(); assert(music.session.player == nil)
  music.preview(custom[0]); assert(music.currentID == custom[0].id)
  music.preview(custom[0]); assert(music.session.player == nil && music.currentID == nil)
  let previousAssets = quiz.referencedAssets
  quiz.background.enabled = true; quiz.background.volume = 0.1
  assert(quiz.referencedAssets == previousAssets)
  quiz.background.enabled = false
  print("PASS: supplied music opens, custom import validation/local copy, saved local playlist, fade/duck/speech/mute, repeat, enable/disable, preview, music excluded from quiz assets")

  quiz.quiz.rounds[0].questions[0].start = 100
  await quiz.validateQuiz(); assert(!quiz.preflightIssues.isEmpty)
  quiz.quiz.rounds[0].questions[0].start = 0.4
  quiz.quiz.rounds[0].questions[0].media = nil
  await quiz.validateQuiz(); assert(quiz.preflightIssues.isEmpty)
  quiz.quiz.rounds[0].questions[0].media = "tone.wav"
  quiz.quiz.rounds[0].questions[0].explanationMedia = nil
  quiz.quiz.rounds[0].questions[0].audioOnly = true
  await quiz.validateQuiz(); assert(quiz.preflightIssues.isEmpty)
  quiz.quiz.rounds[0].questions[0].audioOnly = false
  await quiz.validateQuiz(); assert(quiz.preflightIssues.contains { $0.contains("вопрос") && $0.contains("видеодорожки") })
  quiz.quiz.rounds[0].questions[0].image = "missing.png"
  await quiz.validateQuiz(); assert(quiz.preflightIssues.contains { $0.contains("missing.png") })
  quiz.quiz.rounds[0].questions[0].image = nil
  quiz.quiz.rounds[0].questions[0].audioOnly = true
  quiz.checkpoint(copyAssets:true)
  quiz.start(); quiz.startQuestionTimer()
  try await wait("recovery source playing") { !quiz.playback.loading }
  quiz.player?.volume = 0; quiz.remaining = 3; quiz.checkpoint()
  let recovered = Studio(draftURL: quiz.draft); recovered.timer?.invalidate(); recovered.restoreGame()
  assert(recovered.playing && recovered.paused && recovered.remaining == 3)
  assert(FileManager.default.fileExists(atPath: recovered.asset("tone.wav")!.path))
  try await wait("recovered recording prepared") { !recovered.playback.loading }
  assert(recovered.player?.rate == 0 && recovered.playback.error == nil)
  recovered.stop(); quiz.stop()
  let outputs = AudioOutput.available()
  quiz.audioOutputUID = outputs.first?.id ?? ""
  assert(quiz.playback.outputDevice == quiz.background.session.outputDevice)
  print("PASS: preflight catches bounds/missing media, valid media succeeds, recovery retains local assets and waits paused, sound output routes consistently")
  let gif = root.appendingPathComponent("animated.gif")
  let destinationGIF = CGImageDestinationCreateWithURL(gif as CFURL,"com.compuserve.gif" as CFString,2,nil)!
  CGImageDestinationSetProperties(destinationGIF,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
  for red in [true,false] {
   let bitmap = CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   bitmap.setFillColor((red ? NSColor.red : NSColor.blue).cgColor); bitmap.fill(CGRect(x:0,y:0,width:32,height:32))
   CGImageDestinationAddImage(destinationGIF,bitmap.makeImage()!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary)
  }
  assert(CGImageDestinationFinalize(destinationGIF))
  let gifSource = CGImageSourceCreateWithURL(gif as CFURL,nil)!; assert(CGImageSourceGetCount(gifSource)==2)
  let gifHost = NSHostingView(rootView:AnimatedQuizImage(url:gif)); gifHost.frame=NSRect(x:0,y:0,width:300,height:200); gifHost.layoutSubtreeIfNeeded()
  func imageViews(_ view: NSView) -> [NSImageView] { (view as? NSImageView).map { [$0] } ?? view.subviews.flatMap(imageViews) }
  assert(imageViews(gifHost).contains { $0.animates && $0.image != nil })
  try FileManager.default.copyItem(at:gif,to:media.appendingPathComponent("animated.gif"))
  quiz.quiz.rounds[0].intro = RoundIntro(text:"Правила",image:"animated.gif")
  let gifQuiz = root.appendingPathComponent("gif.quiz"); try quiz.write(to:gifQuiz)
  let gifArchive = try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:gifQuiz))
  let gifBytes = try Data(contentsOf:gif); assert(gifArchive.assets["animated.gif"] == gifBytes)
  print("PASS: two-frame GIF opens in animated native view and transfers unchanged with round description")
  quiz.addRound(); let destination=quiz.quiz.rounds[1].id
  let provider=NSItemProvider(object:question.id.uuidString as NSString)
  assert(quiz.acceptQuestionDrop([provider],toRound:destination))
  try await wait("native drag provider decoding") { quiz.quiz.rounds[1].questions.last?.id == question.id }
  assert(quiz.quiz.rounds[0].questions.isEmpty)
  quiz.selectRound(quiz.quiz.rounds[0].id); assert(quiz.selectedQuestion == nil)
  quiz.deleteEmptyRound(quiz.quiz.rounds[0].id); assert(quiz.quiz.rounds.count == 1 && quiz.selectedQuestion != nil)
  print("PASS: native drag provider decoding, moving last question, selecting and removing empty round")
 }
}

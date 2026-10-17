struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct MediaChecks {
 @MainActor static func wait(_ name: String,_ predicate: () -> Bool) async throws {
  for _ in 0..<150 { if predicate() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
  throw NSError(domain: "MediaChecks",code: 1,userInfo: [NSLocalizedDescriptionKey:"Timeout: " + name])
 }
 @MainActor static func video(_ url: URL) async throws {
  let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 160,AVVideoHeightKey: 120])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:160,kCVPixelBufferHeightKey as String:120])
  writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime: .zero)
  for frame in 0..<60 {
   while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
   var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)
   guard let buffer else { fatalError("pixel buffer") }
   CVPixelBufferLockBaseAddress(buffer,[])
   let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
   let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
   for i in stride(from: 0,to: count,by: 4) { address[i]=UInt8(frame*3); address[i+1]=80; address[i+2]=120; address[i+3]=255 }
   CVPixelBufferUnlockBaseAddress(buffer,[])
   guard adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(frame),timescale:30)) else { throw writer.error! }
  }
  input.markAsFinished(); await writer.finishWriting()
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
  let bad=root.appendingPathComponent("bad.mp3"); try Data([1,2,3,4]).write(to:bad)
  let invalid=MediaSession(); invalid.start(url:bad)
  try await wait("invalid file handled") { invalid.finished && invalid.error != nil }; assert(!invalid.loading)
  invalid.start(url:wav,start:100,end:101)
  try await wait("out-of-range handled") { invalid.finished && invalid.error != nil }
  invalid.start(url:wav); invalid.stop(); try await Task.sleep(nanoseconds:300_000_000); assert(invalid.player == nil && invalid.finished && invalid.error == nil)
  print("PASS: malformed media and invalid fragment fail safely; cancelled load does not restart playback")
  let quiz=Studio(draftURL:root.appendingPathComponent("Draft.workspace")); quiz.timer?.invalidate()
  var question=Question(); question.text="Аудиовопрос"; question.answer="Ответ"; question.media="tone.wav"; question.start=0.4; question.end=1.0; question.afterMedia=true; question.seconds=5
  let media=root.appendingPathComponent("Media"); try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true); try FileManager.default.copyItem(at:wav,to:media.appendingPathComponent("tone.wav"))
  quiz.folder=root; quiz.quiz.rounds[0].questions=[question]; quiz.start()
  for _ in 0..<20 { quiz.tick() }; assert(quiz.remaining==5) // Loading must not consume discussion time.
  try await wait("quiz audio ready") { !quiz.playback.loading }; quiz.player?.volume=0
  try await wait("quiz audio finish") { quiz.playback.finished }; quiz.tick(); assert(!quiz.waitingForMedia)
  for _ in 0..<6 { quiz.tick() }; assert(quiz.remaining==4)
  quiz.stop(); assert(quiz.player==nil)
  print("PASS: quiz uses the same safe player, waits for media before discussion timer and stops on exit")
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

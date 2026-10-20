struct Stage: View { var studio: Studio; var audience: Bool; var body: some View { EmptyView() } }
@main struct YouTubeChecks {
 @MainActor static func wait(_ label: String,_ predicate: () -> Bool) async throws {
  for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds:100_000_000) }
  throw YouTubeImportError(message:"Timeout: "+label)
 }
 @MainActor static func makeVideo(_ url: URL) async throws {
  let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
  let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:160,AVVideoHeightKey:120])
  if #available(macOS 26.0, *) {
   let receiver = writer.inputPixelBufferReceiver(for:input,pixelBufferAttributes:nil)
   try writer.start(); writer.startSession(atSourceTime:.zero)
   for frame in 0..<54 {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,nil,&buffer) == kCVReturnSuccess, let buffer else { throw CocoaError(.fileWriteUnknown) }
    CVPixelBufferLockBaseAddress(buffer,[])
    memset(CVPixelBufferGetBaseAddress(buffer)!,Int32(frame*3),CVPixelBufferGetBytesPerRow(buffer)*CVPixelBufferGetHeight(buffer))
    CVPixelBufferUnlockBaseAddress(buffer,[])
    try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer:buffer),with:CMTime(value:Int64(frame),timescale:30))
   }
   receiver.finish()
  } else {
   let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:160,kCVPixelBufferHeightKey as String:120])
   writer.add(input); assert(writer.startWriting()); writer.startSession(atSourceTime:.zero)
   for frame in 0..<54 {
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds:5_000_000) }
    var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)
    CVPixelBufferLockBaseAddress(buffer!,[])
    memset(CVPixelBufferGetBaseAddress(buffer!),Int32(frame*3),CVPixelBufferGetBytesPerRow(buffer!)*CVPixelBufferGetHeight(buffer!))
    CVPixelBufferUnlockBaseAddress(buffer!,[])
    assert(adaptor.append(buffer!,withPresentationTime:CMTime(value:Int64(frame),timescale:30)))
   }
   input.markAsFinished()
  }
  await writer.finishWriting(); assert(writer.status == .completed)
 }
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]); let tools=root.appendingPathComponent("tools")
  let canonical="https://www.youtube.com/watch?v=jNQXAC9IVRw"
  for input in [canonical,"youtu.be/jNQXAC9IVRw?t=2","https://m.youtube.com/shorts/jNQXAC9IVRw","https://www.youtube.com/watch?v=jNQXAC9IVRw&list=ignored"] {
   let normalized = try YouTubeLink.canonical(input); assert(normalized.absoluteString == canonical)
  }
  for input in ["https://youtube.com.evil.test/watch?v=jNQXAC9IVRw","file:///tmp/movie.mp4","--exec=bad","https://youtube.com/playlist?list=bad","https://user:pass@youtube.com/watch?v=jNQXAC9IVRw","https://youtu.be/short"] {
   do { _ = try YouTubeLink.canonical(input); fatalError("invalid URL accepted") } catch {}
  }
  var metadata=YouTubeMetadata(id:"jNQXAC9IVRw",title:"Test",duration:10,formats:[
   YouTubeFormat(format_id:"137",ext:"mp4",vcodec:"avc1",acodec:"none",height:1080),
   YouTubeFormat(format_id:"136",ext:"mp4",vcodec:"avc1",acodec:"none",height:720),
   YouTubeFormat(format_id:"140",ext:"m4a",vcodec:"none",acodec:"mp4a",abr:128)])
  let videoSelection = try metadata.selection(audioOnly:false,height:720); assert(videoSelection.map(\.format_id) == ["136","140"])
  let audioSelection = try metadata.selection(audioOnly:true,height:720); assert(audioSelection.map(\.format_id) == ["140"])
  metadata.is_live=true; do { _ = try metadata.selection(audioOnly:false,height:1080); fatalError("live accepted") } catch {}
  print("PASS: canonical YouTube/Shorts URLs, hostile/playlist rejection, format quality and audio selection, live rejection")
  try await makeVideo(root.appendingPathComponent("video.mp4"))
  let audioDir=root.appendingPathComponent("audio-work");try FileManager.default.createDirectory(at:audioDir,withIntermediateDirectories:true)
  let audio=try await YouTubeImporter.prepare(files:[root.appendingPathComponent("tone.wav")],audioOnly:true,directory:audioDir)
  try FileManager.default.copyItem(at:audio,to:root.appendingPathComponent("audio.m4a"))
  let importer=YouTubeImporter(toolsFolder:tools);assert(importer.available)
  let studio=Studio(draftURL:root.appendingPathComponent("draft.quiz"));studio.timer?.invalidate()
  let questionID=studio.quiz.rounds[0].questions[0].id
  var calls=0
  importer.start(link:canonical,audioOnly:false,height:720) { url,_ in
   try studio.importDownloadedMedia(url,questionID:questionID,explanation:false);calls += 1
  }
  try await wait("video import") { !importer.busy }
  assert(importer.failure == nil && calls == 1 && importer.progress == 1)
  let videoURL=studio.asset(studio.quiz.rounds[0].questions[0].media)!
  let importedVideo=AVURLAsset(url:videoURL)
  let videos=try await importedVideo.loadTracks(withMediaType:.video);let audios=try await importedVideo.loadTracks(withMediaType:.audio)
  assert(videos.count == 1 && audios.count == 1)
  importer.start(link:canonical,audioOnly:true,height:720) { url,_ in
   try studio.importDownloadedMedia(url,questionID:questionID,explanation:true);calls += 1
  }
  try await wait("audio import") { !importer.busy }
  assert(importer.failure == nil && calls == 2)
  let audioURL=studio.asset(studio.quiz.rounds[0].questions[0].explanationMedia)!
  let audioAsset=AVURLAsset(url:audioURL);let noVideo=try await audioAsset.loadTracks(withMediaType:.video)
  assert(noVideo.isEmpty && audioURL.pathExtension == "m4a")
  let portable=root.appendingPathComponent("portable.quiz");try studio.write(to:portable)
  let archive=try JSONDecoder().decode(QuizFile.self,from:Data(contentsOf:portable))
  assert(archive.assets.count == 2 && archive.assets.values.allSatisfy { !$0.isEmpty })
  print("PASS: structured download progress, separate video/audio merge, audio-only export, attachment to question and answer, self-contained quiz")
  try Data().write(to:root.appendingPathComponent("failure"))
  importer.start(link:canonical,audioOnly:false,height:720) { _,_ in calls += 1 }
  try await wait("failed import") { !importer.busy };assert(importer.failure != nil && calls == 2)
  try FileManager.default.removeItem(at:root.appendingPathComponent("failure"))
  try Data().write(to:root.appendingPathComponent("slow"))
  importer.start(link:canonical,audioOnly:false,height:720) { _,_ in calls += 1 }
  try await Task.sleep(nanoseconds:200_000_000);importer.cancel()
  try await Task.sleep(nanoseconds:600_000_000)
  assert(!importer.busy && calls == 2 && FileManager.default.fileExists(atPath:videoURL.path))
  print("PASS: failed and cancelled imports never attach or replace previous media; cancellation interrupts helper")
  if let tools = ProcessInfo.processInfo.environment["QUIZ_YOUTUBE_LIVE_TOOLS"] {
   let live = YouTubeImporter(toolsFolder:URL(fileURLWithPath:tools));var saved: URL?
   live.start(link:canonical,audioOnly:false,height:360) { url,_ in
    let destination=root.appendingPathComponent("live-video.mp4");try FileManager.default.copyItem(at:url,to:destination);saved=destination
   }
   for _ in 0..<2400 { if !live.busy { break }; try await Task.sleep(nanoseconds:100_000_000) }
   guard live.failure == nil, let saved else { throw YouTubeImportError(message:live.failure ?? "Live test timeout") }
   let asset=AVURLAsset(url:saved);let video=try await asset.loadTracks(withMediaType:.video);let audio=try await asset.loadTracks(withMediaType:.audio)
   assert(!video.isEmpty && !audio.isEmpty)
   print("PASS: live YouTube metadata, actual video/audio downloads and native merge produce playable local video")
  }

 }
}

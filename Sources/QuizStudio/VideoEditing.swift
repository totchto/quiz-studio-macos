import SwiftUI
import AVFoundation
import AppKit

struct VideoFrame: Identifiable {
    let time: Double
    let image: NSImage
    var id: Double { time }
}
struct VideoFrames {
    static func image(url: URL,time: Double,size: CGSize = CGSize(width:960,height:540)) async throws -> VideoFrame {
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await withTaskCancellationHandler(operation: {
            try await generator.image(at:CMTime(seconds:max(0,time),preferredTimescale:60000))
        },onCancel: { generator.cancelAllCGImageGeneration() })
        try Task.checkCancellation()
        return VideoFrame(time:result.actualTime.seconds,image:NSImage(cgImage:result.image,size:.zero))
    }
    static func strip(url: URL,range: ClosedRange<Double>,count: Int) async throws -> [VideoFrame] {
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:url))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width:180,height:110)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let count = min(96,max(2,count))
        return try await withTaskCancellationHandler(operation: {
            var frames: [VideoFrame] = []
            for i in 0..<count {
                try Task.checkCancellation()
                let time = range.lowerBound+(range.upperBound-range.lowerBound)*Double(i)/Double(count)
                if let result = try? await generator.image(at:CMTime(seconds:time,preferredTimescale:60000)) {
                    frames.append(VideoFrame(time:time,image:NSImage(cgImage:result.image,size:.zero)))
                }
            }
            try Task.checkCancellation()
            return frames
        },onCancel: { generator.cancelAllCGImageGeneration() })
    }
    static func clamped(_ time: Double,duration: Double,step: Double) -> Double {
        min(max(0,duration-max(0.001,step)),max(0,time))
    }
}
@MainActor final class VideoScrubber: ObservableObject {
    @Published var frame: VideoFrame?
    @Published var error: String?
    @Published var loading = false
    private var task: Task<Void,Never>?
    func seek(url: URL,time: Double,immediate: Bool = false) {
        task?.cancel(); loading = true; error = nil
        task = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(nanoseconds:35_000_000) }
                let frame = try await VideoFrames.image(url:url,time:time)
                guard !Task.isCancelled, let self else { return }
                self.frame = frame; self.loading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }
    func clear() { task?.cancel(); task = nil; frame = nil; error = nil; loading = false }
    deinit { task?.cancel() }
}

extension Question {
    func showsVideo(answer: Bool) -> Bool { answer ? answerVideo : !audioOnly }
}

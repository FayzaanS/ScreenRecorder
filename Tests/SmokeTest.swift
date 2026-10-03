// Records a few seconds of screen and system audio without the menu bar UI, then checks
// the saved file. Run by CI (.github/workflows/build.yml); not part of the app.
import AVFoundation

@main
struct SmokeTest {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "smoke-test.mp4")
        try? FileManager.default.removeItem(at: url)

        let recorder = Recorder(outputURL: url)
        try await recorder.start()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let file = try await recorder.stop()

        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        print("Saved \(file.path) (\(bytes / 1024) KB), duration \(String(format: "%.2f", duration)) s")

        for track in videoTracks {
            let size = try await track.load(.naturalSize)
            let range = try await track.load(.timeRange)
            print("Video: \(Int(size.width))x\(Int(size.height)), \(String(format: "%.2f", range.duration.seconds)) s")
        }
        for track in audioTracks {
            let range = try await track.load(.timeRange)
            let peak = try loudestSample(of: track, in: asset)
            print("Audio: \(String(format: "%.2f", range.duration.seconds)) s, peak level \(peak) of 32767")
        }

        guard videoTracks.count == 1, abs(duration - 4) < 1 else {
            print("FAILED: expected one video track lasting about 4 seconds")
            exit(1)
        }
        print("OK")
    }

    /// Decodes the track to 16-bit PCM and returns the largest absolute sample value.
    static func loudestSample(of track: AVAssetTrack, in asset: AVAsset) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var peak = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 2, destination: &samples)
            peak = max(peak, samples.map { abs(Int($0)) }.max() ?? 0)
        }
        return peak
    }
}

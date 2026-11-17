import AVFoundation

struct RecordingInfo: Equatable {
    let width: Int32
    let height: Int32
    let fps: Double
    let codec: String
    let audioChannels: Int
    let duration: Double

    var summary: String {
        let rate = fps > 0 ? " · \(rateLabel(fps)) кадр/с" : ""
        return "\(width) × \(height)\(rate) · \(codec) · Каналов звука: \(audioChannels)"
    }

    static func read(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureFailure("В файле нет видеодорожки.")
        }
        guard let format = try await video.load(.formatDescriptions).first else {
            throw CaptureFailure("Не удалось прочитать формат видео.")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var channels = 0
        for track in audio where try await track.load(.timeRange).duration.seconds > 0 {
            if let audioFormat = try await track.load(.formatDescriptions).first {
                channels += Int(audioFormat.audioStreamBasicDescription?.mChannelsPerFrame ?? 0)
            }
        }
        let rate = try await video.load(.nominalFrameRate)
        let duration = try await video.load(.timeRange).duration.seconds
        let size = format.dimensions
        guard size.width > 0, size.height > 0, duration.isFinite, duration > 0 else {
            throw CaptureFailure("В файле нет пригодных для просмотра кадров.")
        }
        return Self(width: size.width, height: size.height, fps: rate.isFinite ? Double(rate) : 0,
                    codec: FileCodec.label(for: format.mediaSubType.rawValue), audioChannels: channels,
                    duration: duration)
    }
}

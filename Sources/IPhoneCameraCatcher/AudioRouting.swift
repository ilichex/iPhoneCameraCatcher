import AVFoundation

enum AudioRouting: Int, CaseIterable, Identifiable {
    case original = 0
    case inputOne = 1
    case inputTwo = 2

    var id: Self { self }
    var label: String {
        self == .original ? "Как записано" : "Вход \(rawValue) → левый и правый"
    }

    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    func apply(to url: URL) async throws -> RecordingInfo {
        guard let executable = Self.ffmpeg else {
            throw CaptureFailure("Для копирования канала нужен FFmpeg.")
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first,
              let format = try await track.load(.formatDescriptions).first,
              let channels = format.audioStreamBasicDescription?.mChannelsPerFrame,
              channels >= rawValue else {
            throw CaptureFailure("В записанной дорожке нет доступного входа \(rawValue).")
        }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let original = try await RecordingInfo.read(url)
        let channel = "c\(rawValue - 1)"
        let command = Process()
        command.executableURL = executable
        command.arguments = [
            "-nostdin", "-loglevel", "error", "-n", "-copyts", "-start_at_zero", "-i", url.path,
            "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy",
            "-af", "pan=stereo|c0=\(channel)|c1=\(channel)", "-c:a", "pcm_s24le", temporary.path
        ]
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw CaptureFailure("FFmpeg не смог скопировать канал. Проверь свободное место на диске.")
        }
        let result = try await RecordingInfo.read(temporary)
        guard result.audioChannels == 2, result.width == original.width,
              result.height == original.height, result.codec == original.codec else {
            throw CaptureFailure("Не удалось подтвердить параметры готового файла.")
        }
        // Меняем исходник только после проверки нового файла на том же диске.
        guard rename(temporary.path, url.path) == 0 else {
            throw CaptureFailure("Не удалось сохранить файл с двумя каналами.")
        }
        return result
    }
}

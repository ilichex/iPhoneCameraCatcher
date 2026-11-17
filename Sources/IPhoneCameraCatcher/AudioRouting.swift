import AVFoundation

enum AudioRouting: Int, CaseIterable, Identifiable {
    case original = 0
    case inputOne = 1
    case inputTwo = 2
    case automatic = 3

    var id: Self { self }
    var label: String {
        switch self {
        case .original: "Как записано"
        case .automatic: "Авто — исправить звук с одной стороны"
        case .inputOne, .inputTwo: "Вход \(rawValue) → левый и правый"
        }
    }

    var requiredChannels: Int { self == .inputTwo ? 2 : 1 }

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
              channels >= requiredChannels else {
            throw CaptureFailure("В записанной дорожке нет нужного аудиовхода.")
        }

        let original = try await RecordingInfo.read(url)
        let input: Int
        switch self {
        case .original:
            return original
        case .automatic:
            switch channels {
            case 1: input = 0
            case 2:
                guard let active = try Self.oneSidedInput(in: url, using: executable) else { return original }
                input = active
            default: return original
            }
        case .inputOne, .inputTwo:
            input = rawValue - 1
        }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let channel = "c\(input)"
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

    private static func oneSidedInput(in url: URL, using executable: URL) throws -> Int? {
        let analysis = Process()
        let report = Pipe()
        analysis.executableURL = executable
        analysis.arguments = [
            "-nostdin", "-hide_banner", "-nostats", "-loglevel", "info", "-i", url.path,
            "-map", "0:a:0", "-af", "astats=measure_perchannel=Peak_level:measure_overall=none",
            "-f", "null", "-"
        ]
        analysis.standardOutput = FileHandle.nullDevice
        analysis.standardError = report
        try analysis.run()
        let data = report.fileHandleForReading.readDataToEndOfFile()
        analysis.waitUntilExit()
        let peaks = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { $0.contains("Peak level dB:") }
            .compactMap { $0.split(separator: " ").last.flatMap { Double($0) } }
        guard analysis.terminationStatus == 0, peaks.count == 2, peaks.allSatisfy({ !$0.isNaN }) else {
            throw CaptureFailure("Не удалось определить уровень двух каналов.")
        }
        let louder = peaks[0] >= peaks[1] ? 0 : 1
        let quieter = peaks[1 - louder]
        // Тихий, но полезный сигнал сохраняем. Копируем только при большом разрыве уровней.
        guard quieter <= -50, peaks[louder] >= -50, peaks[louder] - quieter >= 30 else { return nil }
        return louder
    }
}

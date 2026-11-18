import AVFoundation

/// Что попадает в готовый файл, когда записан системный звук.
enum SystemMix: Int, CaseIterable, Identifiable {
    case microphone = 0
    case system = 1
    case mix = 2

    var id: Self { self }
    var label: String {
        switch self {
        case .microphone: "Микрофон"
        case .system: "Только звук программ (Ableton)"
        case .mix: "Микрофон + системный звук"
        }
    }
}

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

    func preview(inputLevels: [Float], oneSidedInput: Int?) -> [Float] {
        guard let first = inputLevels.first else { return [] }
        let copyInput: Int?
        switch self {
        case .original: copyInput = nil
        case .automatic: copyInput = oneSidedInput
        case .inputOne, .inputTwo: copyInput = rawValue - 1
        }
        if let index = copyInput, inputLevels.indices.contains(index) {
            return [inputLevels[index], inputLevels[index]]
        }
        return [first, inputLevels.count > 1 ? inputLevels[1] : first]
    }

    static func oneSidedInput(peaks: [Double]) -> Int? {
        guard peaks.count == 2 else { return nil }
        let louder = peaks[0] >= peaks[1] ? 0 : 1
        let quieter = peaks[1 - louder]
        // Тихий, но полезный сигнал сохраняем. Копируем только при большом разрыве уровней.
        guard quieter <= -50, peaks[louder] >= -50, peaks[louder] - quieter >= 30 else { return nil }
        return louder
    }

    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    func apply(to url: URL, mix: SystemMix = .microphone, systemFile: URL? = nil) async throws -> RecordingInfo {
        guard let executable = Self.ffmpeg else {
            throw CaptureFailure("Для обработки звука нужен FFmpeg.")
        }
        let original = try await RecordingInfo.read(url)
        guard let systemFile, mix != .microphone else {
            return try await applyMicOnly(url, using: executable, original: original)
        }
        return try await applyWithSystemFile(url, systemFile: systemFile, using: executable, original: original, mix: mix)
    }

    /// Прежняя обработка одной дорожки: копирование канала микрофона в стерео.
    private func applyMicOnly(_ url: URL, using executable: URL, original: RecordingInfo) async throws -> RecordingInfo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first,
              let format = try await track.load(.formatDescriptions).first,
              let channels = format.audioStreamBasicDescription?.mChannelsPerFrame,
              channels >= requiredChannels else {
            throw CaptureFailure("В записанной дорожке нет нужного аудиовхода.")
        }

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

    /// Системный звук записан отдельным WAV: подмешиваем его к видео и микрофону.
    private func applyWithSystemFile(_ url: URL, systemFile: URL, using executable: URL, original: RecordingInfo,
                                     mix: SystemMix) async throws -> RecordingInfo {
        guard FileManager.default.fileExists(atPath: systemFile.path) else {
            throw CaptureFailure("Файл системного звука не найден.")
        }

        // Микрофонную дорожку приводим к стерео, как и в одиночной записи.
        var pan: String?
        switch self {
        case .original: pan = nil
        case .automatic:
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let channels = (try await tracks.first?.load(.formatDescriptions).first?
                .audioStreamBasicDescription?.mChannelsPerFrame) ?? 0
            if channels == 1 {
                pan = "pan=stereo|c0=c0|c1=c0"
            } else if channels >= 2, let active = try Self.oneSidedInput(in: url, using: executable) {
                pan = "pan=stereo|c0=c\(active)|c1=c\(active)"
            }
        case .inputOne, .inputTwo:
            pan = "pan=stereo|c0=c\(rawValue - 1)|c1=c\(rawValue - 1)"
        }

        var arguments = ["-nostdin", "-loglevel", "error", "-n", "-copyts", "-start_at_zero",
                         "-i", url.path, "-i", systemFile.path]
        switch mix {
        case .microphone:
            break
        case .system:
            let duration = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), original.duration)
            arguments += ["-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
                          "-af", "aformat=channel_layouts=stereo,apad=whole_dur=\(duration),atrim=duration=\(duration)",
                          "-c:a", "pcm_s24le"]
        case .mix:
            // Обе дорожки приводим к стерео, иначе amix смешает всё в моно.
            let chain = "amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.97"
            let mic = pan.map { "[0:a:0]\($0)[mic]" } ?? "[0:a:0]aformat=channel_layouts=stereo[mic]"
            let filter = "\(mic);[1:a:0]aformat=channel_layouts=stereo[sys];[mic][sys]\(chain)[a]"
            arguments += ["-filter_complex", filter, "-map", "0:v:0", "-map", "[a]",
                          "-c:v", "copy", "-c:a", "pcm_s24le"]
        }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let command = Process()
        command.executableURL = executable
        command.arguments = arguments + [temporary.path]
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw CaptureFailure("FFmpeg не смог собрать дорожки. Проверь свободное место на диске.")
        }
        let result = try await RecordingInfo.read(temporary)
        guard result.audioChannels == 2, result.width == original.width,
              result.height == original.height, result.codec == original.codec else {
            throw CaptureFailure("Не удалось подтвердить параметры готового файла.")
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw CaptureFailure("Не удалось сохранить готовый файл.")
        }
        return result
    }

    /// Пиковый уровень дорожки, дБ. Нужен, чтобы сообщить о пустой системной дорожке.
    static func trackPeak(in url: URL, stream: Int, using executable: URL) -> Double? {
        let analysis = Process()
        let report = Pipe()
        analysis.executableURL = executable
        analysis.arguments = [
            "-nostdin", "-hide_banner", "-nostats", "-loglevel", "info", "-i", url.path,
            "-map", "0:a:\(stream)", "-af", "astats=measure_perchannel=Peak_level:measure_overall=none",
            "-f", "null", "-"
        ]
        analysis.standardOutput = FileHandle.nullDevice
        analysis.standardError = report
        do { try analysis.run() } catch { return nil }
        let data = report.fileHandleForReading.readDataToEndOfFile()
        analysis.waitUntilExit()
        let peaks = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { $0.contains("Peak level dB:") }
            .compactMap { $0.split(separator: " ").last.flatMap { Double($0) } }
        guard analysis.terminationStatus == 0, peaks.allSatisfy({ !$0.isNaN }) else { return nil }
        return peaks.max()
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
        return oneSidedInput(peaks: peaks)
    }
}

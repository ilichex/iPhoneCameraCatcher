import AVFoundation
import VideoToolbox

struct CaptureMode: Identifiable, Equatable {
    let width: Int32
    let height: Int32
    let fps: Double

    var id: String { "\(width)x\(height)-\(Int((fps * 1000).rounded()))" }
    var pixels: Int64 { Int64(width) * Int64(height) }
    var label: String { "\(width) × \(height) · \(rateLabel(fps)) кадр/с" }
}

func rateLabel(_ value: Double) -> String {
    value.formatted(.number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(0...2)))
}

struct ModeCandidate {
    let mode: CaptureMode
    let format: AVCaptureDevice.Format
    let duration: CMTime

    static func advertised(by device: AVCaptureDevice) -> [Self] {
        let standard = [24, 25, 30, 50, 60, 100, 120, 240].map { CMTime(value: 1, timescale: $0) }
            + [24_000, 30_000, 60_000, 120_000].map { CMTime(value: 1001, timescale: $0) }
        var unique: [String: ModeCandidate] = [:]
        for format in device.formats {
            let size = format.formatDescription.dimensions
            guard size.width > 0, size.height > 0 else { continue }
            for range in format.videoSupportedFrameRateRanges {
                for time in [range.minFrameDuration, range.maxFrameDuration] + standard {
                    guard time.isNumeric, time.seconds > 0,
                          time >= range.minFrameDuration, time <= range.maxFrameDuration else { continue }
                    let mode = CaptureMode(width: size.width, height: size.height, fps: 1 / time.seconds)
                    if unique[mode.id] == nil || format == device.activeFormat {
                        unique[mode.id] = Self(mode: mode, format: format, duration: time)
                    }
                }
            }
        }
        return unique.values.sorted {
            if $0.mode.pixels != $1.mode.pixels { return $0.mode.pixels > $1.mode.pixels }
            if $0.mode.fps != $1.mode.fps { return $0.mode.fps > $1.mode.fps }
            return $0.mode.width > $1.mode.width
        }
    }

    func apply(to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.activeFormat != format { device.activeFormat = format }

        // Эффекты macOS могут изменить доступный диапазон частоты кадров.
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            duration >= $0.minFrameDuration && duration <= $0.maxFrameDuration
        }) else { throw CaptureFailure("Камера больше не поддерживает выбранную частоту кадров.") }

        if #available(macOS 15, *), device.isAutoVideoFrameRateEnabled {
            device.isAutoVideoFrameRateEnabled = false
        }
        if device.activeVideoMaxFrameDuration.isNumeric, duration > device.activeVideoMaxFrameDuration {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }
}

enum FileCodec: String, CaseIterable, Identifiable {
    case automatic, proResHQ, proRes, hevc, h264, system

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "Авто — максимум качества"
        case .proResHQ: "Apple ProRes 422 HQ"
        case .proRes: "Apple ProRes 422"
        case .hevc: "HEVC (H.265)"
        case .h264: "H.264"
        case .system: "Как выберет macOS"
        }
    }

    var avType: AVVideoCodecType? {
        switch self {
        case .proResHQ: .proRes422HQ
        case .proRes: .proRes422
        case .hevc: .hevc
        case .h264: .h264
        default: nil
        }
    }

    var largeFile: Bool { self == .proRes || self == .proResHQ }

    static func available(width: Int32, height: Int32) -> [Self] {
        [.proResHQ, .proRes, .hevc, .h264].filter { codec in
            var encoder: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height, codecType: codec.fourCC,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &encoder
            )
            guard status == noErr, let encoder else { return false }
            defer { VTCompressionSessionInvalidate(encoder) }
            return VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr
        } + [.system]
    }

    private var fourCC: FourCharCode {
        switch self {
        case .proResHQ: kCMVideoCodecType_AppleProRes422HQ
        case .proRes: kCMVideoCodecType_AppleProRes422
        case .hevc: kCMVideoCodecType_HEVC
        case .h264: kCMVideoCodecType_H264
        default: 0
        }
    }

    func settings(for mode: CaptureMode) -> [String: Any]? {
        guard let avType else { return nil }
        var settings: [String: Any] = [
            AVVideoCodecKey: avType.rawValue,
            AVVideoWidthKey: Int(mode.width),
            AVVideoHeightKey: Int(mode.height)
        ]
        if self == .hevc || self == .h264 {
            // Оставляем запас битрейта для движения и мелких деталей.
            let bitsPerPixel = self == .hevc ? 0.28 : 0.4
            let fps = mode.fps > 0 ? mode.fps : 30
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(1_000_000, Int(Double(mode.pixels) * fps * bitsPerPixel))
            ]
        }
        return settings
    }

    static func label(for subtype: FourCharCode) -> String {
        if let codec = allCases.first(where: { $0.avType != nil && $0.fourCC == subtype }) { return codec.label }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "неизвестный кодек"
    }
}

struct CaptureFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

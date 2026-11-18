import AVFoundation
import CoreAudio
import Foundation

/// Источник системного звука: тап Core Audio на устройство вывода,
/// обёрнутый в приватный агрегат.
///
/// AVFoundation (особенно вместе с камерой Continuity) не доставляет
/// аудио такого агрегата в записи, поэтому звук читается напрямую
/// через IOProc агрегата: он кормит шкалу «Программы» и пишет PCM
/// во временный WAV во время записи. На постобработке FFmpeg
/// подмешивает системную дорожку к видео (см. AudioRouting).
final class SystemTap: @unchecked Sendable {
    private(set) var deviceUID = ""
    private(set) var aggregateUID = ""
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private let lock = NSLock()

    // Прямой ввод агрегата: формат тапа, метры и запись PCM.
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var nonInterleaved = true
    private var channels = 2
    private var sampleRate: Double = 48000

    private let ioLock = NSLock()
    private var meterPeaks: [Float] = []
    private var pendingChannels: [[Float]] = []
    private var file: AVAudioFile?
    private var capturing = false
    private var captureStartHostTime = 0.0
    private var needsInitialPadding = false
    private var writeFailure: String?
    private let writerQueue = DispatchQueue(label: "local.iphone-camera-catcher.systemtap.writer")

    /// Устройства, с которых можно записать системный звук.
    static func outputDevices() -> [InputChoice] {
        guard let ids = Self.devices() else { return [] }
        let list = ids.compactMap { id -> InputChoice? in
            guard Self.streamCount(id) > 0,
                  UInt32(bitPattern: Self.transport(id)) != kAudioDeviceTransportTypeAggregate,
                  let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return InputChoice(id: uid, name: name)
        }
        // Текущий выход по умолчанию показываем первым.
        let defaultUID = Self.string(Self.defaultOutput(), kAudioDevicePropertyDeviceUID)
        return list.sorted {
            if $0.id == defaultUID { return true }
            if $1.id == defaultUID { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Создаёт тап и агрегат, запускает непрерывный ввод агрегата.
    /// Возвращает UID агрегата.
    func start(for outputUID: String) throws -> String {
        try lock.withLock {
            stopLocked()
            let description = CATapDescription(__excludingProcesses: [], andDeviceUID: outputUID, withStream: 0)
            description.name = "iPhone Camera Catcher Tap"
            description.uuid = UUID()
            description.isPrivate = true
            description.isMixdown = true
            description.muteBehavior = .unmuted

            var tapID = AudioObjectID(0)
            let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
            guard tapStatus == noErr, tapID != 0 else {
                throw CaptureFailure("Не удалось создать захват системного звука (\(tapStatus)).")
            }
            do {
                guard let tapUID = Self.string(tapID, kAudioTapPropertyUID) else {
                    throw CaptureFailure("Не удалось прочитать UID захвата системного звука.")
                }
                // Формат тапа — он же формат входа агрегата.
                var asbd = AudioStreamBasicDescription()
                var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                               mScope: kAudioObjectPropertyScopeGlobal,
                                                               mElement: kAudioObjectPropertyElementMain)
                let formatStatus = withUnsafeMutablePointer(to: &asbd) { pointer in
                    AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, pointer)
                }
                guard formatStatus == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
                    throw CaptureFailure("Не удалось прочитать формат захвата системного звука (\(formatStatus)).")
                }
                nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                channels = Int(asbd.mChannelsPerFrame)
                sampleRate = asbd.mSampleRate
                // Для записи всегда используем стандартный non-interleaved float32,
                // поэтому достаточно частоты и числа каналов тапа.
                tapFormat = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame)

                let aggregateUID = "local.iphone-camera-catcher.systemaudio.\(UUID().uuidString.prefix(8))"
                let aggregateDescription: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "iPhone Camera Catcher Tap",
                    kAudioAggregateDeviceUIDKey: aggregateUID,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                    kAudioAggregateDeviceSubDeviceListKey: [[
                        kAudioSubDeviceUIDKey: outputUID,
                        kAudioSubDeviceInputChannelsKey: 0
                    ]],
                    kAudioAggregateDeviceTapAutoStartKey: true,
                    kAudioAggregateDeviceTapListKey: [[
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: 1,
                        kAudioSubTapDriftCompensationQualityKey: 127
                    ]]
                ]
                var aggregateID = AudioDeviceID(0)
                let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
                guard status == noErr, aggregateID != 0 else {
                    throw CaptureFailure("Не удалось создать агрегат для системного звука (\(status)).")
                }
                // Непрерывный ввод агрегата: метры и запись.
                ioLock.lock()
                meterPeaks = Array(repeating: 0, count: channels)
                ioLock.unlock()
                var ioProcID: AudioDeviceIOProcID?
                let ioStatus = AudioDeviceCreateIOProcID(aggregateID, Self.ioCallback,
                                                         Unmanaged.passUnretained(self).toOpaque(), &ioProcID)
                guard ioStatus == noErr, let started = ioProcID else {
                    AudioHardwareDestroyAggregateDevice(aggregateID)
                    throw CaptureFailure("Не удалось запустить ввод системного звука (\(ioStatus)).")
                }
                guard AudioDeviceStart(aggregateID, started) == noErr else {
                    AudioDeviceDestroyIOProcID(aggregateID, started)
                    AudioHardwareDestroyAggregateDevice(aggregateID)
                    throw CaptureFailure("Не удалось запустить ввод системного звука.")
                }
                ioProcID = started

                self.tapID = tapID
                self.aggregateID = aggregateID
                self.aggregateUID = aggregateUID
                self.deviceUID = outputUID
                return aggregateUID
            } catch {
                AudioHardwareDestroyProcessTap(tapID)
                throw error
            }
        }
    }

    func stop() {
        lock.withLock { stopLocked() }
    }

    /// Начинает писать системный звук во временный WAV.
    func startCapture(to url: URL, startHostTime: Double? = nil) throws {
        guard aggregateUID != "", let tapFormat else { throw CaptureFailure("Системный звук не выбран.") }
        let newFile = try AVAudioFile(forWriting: url, settings: tapFormat.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        ioLock.lock()
        pendingChannels = Array(repeating: [], count: channels)
        writeFailure = nil
        captureStartHostTime = startHostTime ?? AVAudioTime.seconds(forHostTime: mach_absolute_time())
        needsInitialPadding = true
        capturing = true
        ioLock.unlock()
        file = newFile
        writerQueue.async { [weak self] in self?.flushLoop() }
    }

    /// Завершает запись и дожидается сброса на диск.
    func stopCapture() {
        ioLock.lock()
        let wasCapturing = capturing
        capturing = false
        ioLock.unlock()
        guard wasCapturing else { return }
        writerQueue.sync { [self] in
            flushLocked()
            file = nil
        }
    }

    /// Пиковые уровни каналов в дБ с прошлого опроса.
    func drainLevels() -> [Float] {
        ioLock.lock()
        let peaks = meterPeaks
        for index in meterPeaks.indices { meterPeaks[index] = 0 }
        ioLock.unlock()
        return peaks.map { $0 > 0 ? Float(20 * log10(Double($0))) : -80 }
    }

    var recordingError: String? {
        ioLock.withLock { writeFailure }
    }

    // MARK: Ввод агрегата

    private static let ioCallback: AudioDeviceIOProc = { _, _, inData, inputTime, _, _, refcon in
        guard let refcon else { return noErr }
        let tap = Unmanaged<SystemTap>.fromOpaque(refcon).takeUnretainedValue()
        tap.consume(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                    hostTime: inputTime.pointee.mHostTime)
        return noErr
    }

    private func consume(_ buffers: UnsafeMutableAudioBufferListPointer, hostTime: UInt64) {
        ioLock.lock()
        defer { ioLock.unlock() }
        let capturingNow = capturing
        if capturingNow, needsInitialPadding {
            if hostTime > 0 {
                let elapsed = AVAudioTime.seconds(forHostTime: hostTime) - captureStartHostTime
                let silence = Int(max(0, min(5, elapsed)) * sampleRate)
                pendingChannels = Array(repeating: Array(repeating: 0, count: silence), count: channels)
            }
            needsInitialPadding = false
        }
        // В агрегате физические входы могут идти перед каналами тапа.
        // Берём только последние буферы с захваченным выходом программ.
        let inputBuffers = Array(buffers)
        let tapBuffers = nonInterleaved ? Array(inputBuffers.suffix(channels)) : Array(inputBuffers.suffix(1))
        for (index, buffer) in tapBuffers.enumerated() where buffer.mNumberChannels > 0 {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let floats = data.bindMemory(to: Float.self, capacity: Int(buffer.mDataByteSize) / 4)
            let count = Int(buffer.mDataByteSize) / 4
            guard count > 0 else { continue }
            if nonInterleaved {
                guard index < channels, index < meterPeaks.count else { continue }
                var peak: Float = 0
                for sampleIndex in 0..<count {
                    let value = abs(floats[sampleIndex])
                    if value > peak { peak = value }
                }
                if peak > meterPeaks[index] { meterPeaks[index] = peak }
                if capturingNow, index < pendingChannels.count {
                    pendingChannels[index].reserveCapacity(pendingChannels[index].count + count)
                    for sampleIndex in 0..<count { pendingChannels[index].append(floats[sampleIndex]) }
                }
            } else {
                let stride = min(channels, meterPeaks.count)
                let frames = count / max(stride, 1)
                for channel in 0..<stride {
                    var peak: Float = 0
                    for frame in 0..<frames {
                        let value = abs(floats[frame * channels + channel])
                        if value > peak { peak = value }
                    }
                    if peak > meterPeaks[channel] { meterPeaks[channel] = peak }
                    if capturingNow, channel < pendingChannels.count {
                        pendingChannels[channel].reserveCapacity(pendingChannels[channel].count + frames)
                        for frame in 0..<frames { pendingChannels[channel].append(floats[frame * channels + channel]) }
                    }
                }
            }
        }
    }

    private func flushLoop() {
        guard ioLock.withLock({ capturing }) else { return }
        flushLocked()
        writerQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flushLoop() }
    }

    /// Вызывается только на writerQueue.
    private func flushLocked() {
        guard let file else { return }
        var chunk: [[Float]]
        ioLock.lock()
        chunk = (0..<pendingChannels.count).map { index -> [Float] in
            let copy = pendingChannels[index]
            pendingChannels[index].removeAll(keepingCapacity: true)
            return copy
        }
        ioLock.unlock()
        let frames = chunk.first?.count ?? 0
        guard frames > 0 else {
            return
        }
        guard let format = tapFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            ioLock.withLock { writeFailure = "Недостаточно памяти для записи системного звука." }
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        // chunk — уже по-канальные массивы; стандартный формат буфера non-interleaved.
        for (index, samples) in chunk.enumerated() where index < channels {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress, source.count >= frames else { return }
                memcpy(buffer.floatChannelData![index], base, frames * MemoryLayout<Float>.size)
            }
        }
        do {
            try file.write(from: buffer)
        } catch {
            ioLock.withLock { writeFailure = error.localizedDescription }
        }
    }

    private func stopLocked() {
        stopCapture()
        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        aggregateUID = ""
        deviceUID = ""
        ioLock.lock()
        capturing = false
        file = nil
        pendingChannels = []
        meterPeaks = []
        ioLock.unlock()
        tapFormat = nil
    }

    deinit { stop() }

    // MARK: Core Audio

    private static func devices() -> [AudioDeviceID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, pointer.baseAddress!)
        }
        return status == noErr ? ids : nil
    }

    private static func defaultOutput() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = withUnsafeMutablePointer(to: &id) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, pointer)
        }
        return id
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return name as String?
    }

    private static func streamCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<UInt32>.size
    }

    private static func transport(_ id: AudioObjectID) -> Int32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        _ = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return value
    }
}

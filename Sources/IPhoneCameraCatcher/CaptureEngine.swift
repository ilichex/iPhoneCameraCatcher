import AVFoundation
import CoreAudio
import Foundation

struct InputChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

enum RecordPhase: Equatable {
    case idle, starting, recording, finishing
}

enum CameraLock: String, CaseIterable, Identifiable {
    case focus = "Фокус", exposure = "Экспозиция", whiteBalance = "Баланс белого"
    var id: Self { self }

    func isSupported(on device: AVCaptureDevice) -> Bool {
        switch self {
        case .focus: device.isFocusModeSupported(.locked) && device.isFocusModeSupported(.continuousAutoFocus)
        case .exposure: device.isExposureModeSupported(.locked) && device.isExposureModeSupported(.continuousAutoExposure)
        case .whiteBalance: device.isWhiteBalanceModeSupported(.locked) && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
        }
    }

    func isLocked(on device: AVCaptureDevice) -> Bool {
        switch self {
        case .focus: device.focusMode == .locked
        case .exposure: device.exposureMode == .locked
        case .whiteBalance: device.whiteBalanceMode == .locked
        }
    }

    func set(_ locked: Bool, on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard isSupported(on: device) else { return }
        switch self {
        case .focus: device.focusMode = locked ? .locked : .continuousAutoFocus
        case .exposure: device.exposureMode = locked ? .locked : .continuousAutoExposure
        case .whiteBalance: device.whiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
        }
    }
}

private extension AVCaptureDevice {
    var pointFocusMode: FocusMode? {
        guard isFocusPointOfInterestSupported else { return nil }
        return [.autoFocus, .continuousAutoFocus].first(where: isFocusModeSupported)
    }

    var pointExposureMode: ExposureMode? {
        guard isExposurePointOfInterestSupported else { return nil }
        return [.autoExpose, .continuousAutoExposure].first(where: isExposureModeSupported)
    }
}

struct RecordingResult: Equatable {
    let url: URL?
    let info: RecordingInfo?
    let warning: String?
}

enum FrameOrientation: String, CaseIterable, Identifiable {
    case automatic = "Авто по камере"
    case original = "Исходный кадр (0°)"
    case clockwise = "Повернуть вправо (90°)"
    case upsideDown = "Перевернуть (180°)"
    case counterclockwise = "Повернуть влево (270°)"

    var id: Self { self }
}

struct CaptureState: Equatable {
    var orientation: FrameOrientation = .automatic
    var rotation: CGFloat = 0
    var centerStageEnabled: Bool?
    var cameras: [InputChoice] = []
    var microphones: [InputChoice] = []
    var cameraID = ""
    var microphoneID = ""
    var audioRouting: AudioRouting = .original
    var systemAudioDevices: [InputChoice] = []
    var systemAudioID = ""
    var systemAudioActive = false
    var systemMix: SystemMix = .system
    var systemLevels: [Float] = []
    var modes: [CaptureMode] = []
    var modeID = ""
    var activeMode: CaptureMode?
    var codecs: [FileCodec] = []
    var selectedCodec = FileCodec.automatic
    var activeCodec: FileCodec?
    var locks: [CameraLock: Bool] = [:]
    var canSetFocusPoint = false
    var canSetExposurePoint = false
    var cameraPoint: CGPoint?
    var levels: [Float] = []
    var oneSidedInput: Int?
    var outputLevels: [Float] {
        if systemAudioActive, systemMix == .system {
            return systemLevels
        }
        return audioRouting.preview(inputLevels: levels, oneSidedInput: oneSidedInput)
    }
    var isPreviewing = false
    var ready = false
    var message: String?
    var phase = RecordPhase.idle
    var elapsed = 0
    var result: RecordingResult?
}

// Меняем захват и приём событий записи только на одной очереди.
final class CaptureEngine: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onState: ((CaptureState) -> Void)? // Используется только в главном потоке.

    private let queue = DispatchQueue(label: "local.iphone-camera-catcher.capture", qos: .userInitiated)
    private let output = AVCaptureMovieFileOutput()
    private var videoDiscovery: AVCaptureDevice.DiscoverySession?
    private var audioDiscovery: AVCaptureDevice.DiscoverySession?
    private var videoInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var audioInput: AVCaptureDeviceInput?
    private var systemTap = SystemTap()
    private var preferredCamera: String?
    private var preferredMicrophone: String?
    private var candidates: [ModeCandidate] = []
    private var availableCodecs: [String: [FileCodec]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var discoveryObservers: [NSKeyValueObservation] = []
    private var timer: DispatchSourceTimer?
    private var recordingURL: URL?
    private var systemCaptureURL: URL?
    private var interruption: String?
    private var stopAfterStart = false
    private var refreshAfterRecording = false
    private var sessionInterrupted = false
    private var activity: NSObjectProtocol?
    private var state = CaptureState()
    private var published = CaptureState()
    private var recentAudioPeaks: [[Double]] = []
    private var recordingAudioPeaks: [Double] = []
    private let reserve: Int64 = 512 * 1024 * 1024

    func activate() { queue.async { self.activateOnQueue() } }
    func refresh() { queue.async { self.discover(force: true) } }

    func chooseCamera(_ id: String) {
        queue.async {
            guard self.state.phase == .idle else { return }
            self.preferredCamera = id.isEmpty ? nil : id
            self.state.modeID = ""
            self.discover(force: true)
        }
    }

    func chooseMicrophone(_ id: String) {
        queue.async {
            guard self.state.phase == .idle else { return }
            self.preferredMicrophone = id.isEmpty ? nil : id
            self.discover(force: true)
        }
    }

    func chooseMode(_ id: String) {
        queue.async {
            guard self.state.phase == .idle, let device = self.videoInput?.device else { return }
            self.state.modeID = id
            self.applyMode(on: device)
            self.updateActiveSettings()
            self.publish()
        }
    }

    func chooseAudioRouting(_ routing: AudioRouting) {
        queue.async {
            guard self.state.phase == .idle else { return }
            self.state.audioRouting = routing
            self.publish()
        }
    }

    func chooseSystemAudio(_ id: String) {
        queue.async {
            guard self.state.phase == .idle else { return }
            self.state.systemAudioID = id
            UserDefaults.standard.set(id, forKey: "systemAudioDevice")
            if !id.isEmpty, self.state.systemMix == .microphone { self.state.systemMix = .system }
            self.discover(force: true)
        }
    }

    func chooseSystemMix(_ mix: SystemMix) {
        queue.async {
            guard self.state.phase == .idle else { return }
            self.state.systemMix = mix
            self.publish()
        }
    }

    func fixOneSidedAudio() {
        queue.async {
            guard self.state.phase == .idle || self.state.phase == .recording,
                  self.state.audioRouting == .original,
                  self.state.oneSidedInput != nil, AudioRouting.ffmpeg != nil else { return }
            self.state.audioRouting = .automatic
            self.publish()
        }
    }

    func setCenterStage(_ enabled: Bool) {
        queue.async {
            guard self.state.phase == .idle,
                  self.videoInput?.device.activeFormat.isCenterStageSupported == true else { return }
            AVCaptureDevice.centerStageControlMode = .cooperative
            AVCaptureDevice.isCenterStageEnabled = enabled
            self.updateActiveSettings()
            self.publish()
        }
    }

    func chooseOrientation(_ orientation: FrameOrientation) {
        queue.async {
            guard self.state.phase == .idle else { return }
            self.state.orientation = orientation
            self.updateActiveSettings()
            self.publish()
        }
    }

    func chooseCodec(_ codec: FileCodec) {
        queue.async {
            guard self.state.phase == .idle,
                  codec == .automatic || self.state.codecs.contains(codec) else { return }
            self.state.selectedCodec = codec
            self.updateActiveSettings()
            self.publish()
        }
    }

    func setLock(_ setting: CameraLock, locked: Bool) {
        queue.async {
            guard self.state.phase == .idle, let device = self.videoInput?.device else { return }
            do { try setting.set(locked, on: device) }
            catch { self.state.message = "Не удалось изменить настройку «\(setting.rawValue)»: \(error.localizedDescription)" }
            self.updateActiveSettings()
            self.publish()
        }
    }

    func setCameraPoint(_ point: CGPoint, cameraID: String) {
        queue.async {
            guard self.state.phase == .idle, self.state.isPreviewing,
                  let device = self.videoInput?.device, device.uniqueID == cameraID,
                  (0...1).contains(point.x), (0...1).contains(point.y) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let focus = device.pointFocusMode
                let exposure = device.pointExposureMode
                guard focus != nil || exposure != nil else { return }
                if let focus {
                    device.focusPointOfInterest = point
                    device.focusMode = focus
                }
                if let exposure {
                    device.exposurePointOfInterest = point
                    device.exposureMode = exposure
                }
                self.state.cameraPoint = point
            } catch {
                self.state.message = "Не удалось задать точку камеры: \(error.localizedDescription)"
            }
            self.updateActiveSettings()
            self.publish()
        }
    }

    func record(in folder: URL, processed: @escaping () -> Void) {
        queue.async {
            self.startRecording(in: folder)
            DispatchQueue.main.async(execute: processed)
        }
    }
    func stop() { queue.async { self.stopRecording() } }

    private func activateOnQueue() {
        if videoDiscovery != nil { discover(force: true); return }
        let video = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
                                                     mediaType: .video, position: .unspecified)
        let audio = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external, .continuityCamera],
                                                     mediaType: .audio, position: .unspecified)
        videoDiscovery = video
        audioDiscovery = audio
        for discovery in [video, audio] {
            discoveryObservers.append(discovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
                self?.queue.async { [weak self] in self?.discover() }
            })
        }
        listen(AVCaptureDevice.wasConnectedNotification) { $0.discover() }
        listen(AVCaptureDevice.wasDisconnectedNotification) { $0.discover() }
        listen(AVCaptureSession.runtimeErrorNotification, object: session) { $0.sessionFailed("macOS сообщила об ошибке захвата.") }
        listen(AVCaptureSession.wasInterruptedNotification, object: session) {
            $0.sessionInterrupted = true
            $0.sessionFailed("Захват прерван macOS.")
        }
        listen(AVCaptureSession.interruptionEndedNotification, object: session) {
            $0.sessionInterrupted = false
            $0.discover(force: true)
        }
        listen(AVCaptureSession.didStopRunningNotification, object: session) {
            if !$0.session.isRunning, $0.videoInput != nil { $0.sessionFailed("Предпросмотр остановлен.") }
        }

        output.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)
        output.minFreeDiskSpaceLimit = reserve
        discover(force: true)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(125), leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func listen(_ name: Notification.Name, object: Any? = nil, handle: @escaping (CaptureEngine) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                if let self { handle(self) }
            }
        })
    }

    private func discover(force: Bool = false) {
        guard let videoDiscovery, let audioDiscovery else { return }
        let cameras = videoDiscovery.devices.filter(\.isConnected).sorted {
            let lhs = Self.isIPhone($0), rhs = Self.isIPhone($1)
            return lhs != rhs ? lhs : $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
        let microphones = audioDiscovery.devices.filter {
            $0.isConnected && !Self.isIPhone($0) && !$0.uniqueID.hasPrefix("local.iphone-camera-catcher.")
        }.sorted {
            let lhs = Self.isBuiltIn($0), rhs = Self.isBuiltIn($1)
            return lhs != rhs ? lhs : $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
        if state.phase != .idle {
            let videoPresent = cameras.contains { $0.uniqueID == videoInput?.device.uniqueID }
            let audioPresent = microphones.contains { $0.uniqueID == audioInput?.device.uniqueID }
            refreshAfterRecording = refreshAfterRecording || force || !videoPresent || !audioPresent
                || cameras.map(\.uniqueID) != state.cameras.map(\.id)
                || microphones.map(\.uniqueID) != state.microphones.map(\.id)
            if !videoPresent || !audioPresent {
                sessionFailed(!videoPresent ? "Камера отключилась." : "Аудиовход отключился.")
            }
            return
        }

        state.cameras = cameras.map { .init(id: $0.uniqueID, name: $0.localizedName) }
        state.microphones = microphones.map { .init(id: $0.uniqueID, name: $0.localizedName) }
        let video = preferredCamera.flatMap { id in cameras.first { $0.uniqueID == id } }
            ?? (preferredCamera == nil ? cameras.first(where: Self.isIPhone) : nil)
        let audio = preferredMicrophone.flatMap { id in microphones.first { $0.uniqueID == id } }
            ?? (preferredMicrophone == nil ? microphones.first(where: Self.isBuiltIn) : nil)
        let cameraID = video?.uniqueID ?? preferredCamera ?? ""
        let micID = audio?.uniqueID ?? preferredMicrophone ?? ""
        if cameraID != state.cameraID { state.modeID = "" }
        state.cameraID = cameraID
        if micID != state.microphoneID {
            state.audioRouting = audio?.localizedName.localizedCaseInsensitiveContains("Scarlett") == true
                && AudioRouting.ffmpeg != nil ? .automatic : .original
        }
        state.microphoneID = micID
        updateSystemTap(force: force)
        if force || video?.uniqueID != videoInput?.device.uniqueID || audio?.uniqueID != audioInput?.device.uniqueID {
            configure(video: video, audio: audio)
        }
        if video == nil || audio == nil {
            if video == nil {
                state.message = preferredCamera == nil ? "Подключи iPhone или выбери камеру для проверки." : "Выбранная камера отключена."
            } else {
                state.message = preferredMicrophone == nil ? "Выбери аудиовход." : "Выбранный аудиовход отключён."
            }
        }
        updateActiveSettings()
        publish()
    }

    private static func isIPhone(_ device: AVCaptureDevice) -> Bool {
        let transport = UInt32(bitPattern: device.transportType)
        return device.isContinuityCamera || device.deviceType == .continuityCamera || transport == 0x63636170 // ccap
            || transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    private static func isBuiltIn(_ device: AVCaptureDevice) -> Bool {
        UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeBuiltIn
    }

    /// Держит тап системного звука согласованным с выбором пользователя.
    private func updateSystemTap(force: Bool = false) {
        state.systemAudioDevices = SystemTap.outputDevices()
        if state.systemAudioID.isEmpty, let stored = UserDefaults.standard.string(forKey: "systemAudioDevice") {
            state.systemAudioID = state.systemAudioDevices.contains(where: { $0.id == stored }) ? stored : ""
        }
        let wanted = state.systemAudioID
        if wanted == systemTap.deviceUID, !force { return }
        if wanted.isEmpty {
            systemTap.stop()
            state.systemAudioActive = false
            return
        }
        do {
            _ = try systemTap.start(for: wanted)
            state.systemAudioActive = true
        } catch {
            systemTap.stop()
            state.systemAudioActive = false
            state.message = "Системный звук отключён. \(error.localizedDescription)"
        }
    }

    private func configure(video: AVCaptureDevice?, audio: AVCaptureDevice?) {
        state.message = nil
        state.ready = false
        state.isPreviewing = false
        state.cameraPoint = nil
        state.levels = []
        state.systemLevels = []
        state.systemAudioActive = false
        state.oneSidedInput = nil
        recentAudioPeaks.removeAll()
        sessionInterrupted = false
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        videoInput = nil
        audioInput = nil
        do {
            if let video { videoInput = try addInput(video) }
            if let audio { audioInput = try addInput(audio) }
            // Системный звук не входит в сессию: он пишется тапом напрямую
            // (SystemTap.startCapture) и подмешивается на постобработке.
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else { throw CaptureFailure("Не удалось подключить запись .mov.") }
                session.addOutput(output)
            }
        } catch {
            state.message = error.localizedDescription
        }
        session.commitConfiguration()
        state.systemAudioActive = systemTap.aggregateUID != ""
        rotationCoordinator = videoInput.map { .init(device: $0.device, previewLayer: nil) }

        if videoInput != nil || audioInput != nil { session.startRunning() }
        candidates = videoInput.map { ModeCandidate.advertised(by: $0.device) } ?? []
        state.modes = candidates.map(\.mode)
        if !state.modes.contains(where: { $0.id == state.modeID }) { state.modeID = "" }
        // macOS может выбрать другой входной формат во время запуска сессии.
        if session.isRunning, let device = videoInput?.device { applyMode(on: device) }
        if !session.isRunning, videoInput != nil || audioInput != nil {
            state.message = "Не удалось запустить захват. Переподключи устройства и обнови список."
        }
    }

    private func addInput(_ device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureFailure("Не удалось подключить «\(device.localizedName)».") }
        session.addInput(input)
        return input
    }

    private func applyMode(on device: AVCaptureDevice) {
        let candidate = state.modeID.isEmpty ? candidates.first : candidates.first { $0.mode.id == state.modeID }
        guard let candidate else { return }
        do {
            try candidate.apply(to: device)
            state.cameraPoint = nil
            if audioInput != nil { state.message = nil }
        } catch {
            state.message = "Не удалось задать режим камеры: \(error.localizedDescription)"
        }
    }

    private func updateActiveSettings() {
        state.isPreviewing = session.isRunning && !sessionInterrupted && videoInput?.device.isConnected == true
        state.ready = state.isPreviewing && audioInput?.device.isConnected == true
            && output.connection(with: .video)?.isActive == true && output.connection(with: .audio)?.isActive == true
        if !state.systemAudioID.isEmpty && state.systemMix != .microphone && !state.systemAudioActive {
            state.ready = false
        }
        guard state.isPreviewing, let device = videoInput?.device else {
            state.activeMode = nil
            state.centerStageEnabled = nil
            state.locks = [:]
            state.canSetFocusPoint = false
            state.canSetExposurePoint = false
            state.cameraPoint = nil
            state.codecs = []
            state.activeCodec = nil
            return
        }
        let size = device.activeFormat.formatDescription.dimensions
        state.canSetFocusPoint = device.pointFocusMode != nil
        state.canSetExposurePoint = device.pointExposureMode != nil
        if !state.canSetFocusPoint && !state.canSetExposurePoint { state.cameraPoint = nil }
        state.centerStageEnabled = device.activeFormat.isCenterStageSupported ? AVCaptureDevice.isCenterStageEnabled : nil
        let interval = device.activeVideoMinFrameDuration.seconds
        let rate = interval.isFinite && interval > 0 ? 1 / interval : 0
        state.activeMode = CaptureMode(width: size.width, height: size.height, fps: rate)
        switch state.orientation {
        case .automatic: state.rotation = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
        case .original: state.rotation = 0
        case .clockwise: state.rotation = 90
        case .upsideDown: state.rotation = 180
        case .counterclockwise: state.rotation = 270
        }
        state.locks = Dictionary(uniqueKeysWithValues: CameraLock.allCases.filter { $0.isSupported(on: device) }
            .map { ($0, $0.isLocked(on: device)) })

        let key = "\(size.width)x\(size.height)"
        if availableCodecs[key] == nil, size.width > 0, size.height > 0 {
            availableCodecs[key] = FileCodec.available(width: size.width, height: size.height)
        }
        state.codecs = availableCodecs[key] ?? [.system]
        state.activeCodec = state.selectedCodec == .automatic ? state.codecs.first : state.selectedCodec
        if let codec = state.activeCodec, !state.codecs.contains(codec) {
            state.activeCodec = nil
            state.ready = false
            state.message = "Выбранный кодек недоступен для этого размера кадра. Выбери другой."
        }
    }

    private func tick() {
        let audioConnections: [AVCaptureConnection] = session.isRunning
            ? output.connections.filter { $0.inputPorts.contains { $0.mediaType == .audio } } : []
        let micChannels = audioConnections.first?.audioChannels ?? []
        state.levels = micChannels.map {
            let value = $0.averagePowerLevel
            return value.isFinite ? value : -80
        }
        state.systemLevels = state.systemAudioActive
            ? systemTap.drainLevels().map { $0.isFinite ? $0 : -80 }
            : []
        updateAudioPreview(peaks: micChannels.map { Double($0.peakHoldLevel) })
        if state.phase == .idle {
            updateActiveSettings()
        } else if state.phase == .recording {
            let seconds = output.recordedDuration.seconds
            if seconds.isFinite, seconds >= 0 { state.elapsed = Int(seconds) }
        }
        publish()
    }

    private func updateAudioPreview(peaks: [Double]) {
        state.oneSidedInput = nil
        guard peaks.count == 2, peaks.allSatisfy({ !$0.isNaN }) else {
            recentAudioPeaks.removeAll()
            return
        }

        if state.phase == .recording {
            if recordingAudioPeaks.isEmpty { recordingAudioPeaks = peaks }
            else { recordingAudioPeaks = zip(recordingAudioPeaks, peaks).map { max($0.0, $0.1) } }
            state.oneSidedInput = AudioRouting.oneSidedInput(peaks: recordingAudioPeaks)
        } else if state.phase == .idle {
            // Окно в две секунды не сбрасывает предупреждение между словами.
            recentAudioPeaks.append(peaks)
            if recentAudioPeaks.count > 16 { recentAudioPeaks.removeFirst() }
            guard recentAudioPeaks.count >= 4 else { return }
            let maxima = recentAudioPeaks.reduce([-.infinity, -.infinity]) { result, sample in
                [max(result[0], sample[0]), max(result[1], sample[1])]
            }
            state.oneSidedInput = AudioRouting.oneSidedInput(peaks: maxima)
        }
    }

    private func startRecording(in folder: URL) {
        guard state.phase == .idle else { return }
        updateActiveSettings()
        guard state.ready, let mode = state.activeMode, let codec = state.activeCodec,
              let connection = output.connection(with: .video) else {
            state.message = "Для записи нужны активные камера и аудиовход, а также доступный кодек."
            publish()
            return
        }
        guard connection.isVideoRotationAngleSupported(state.rotation) else {
            state.message = "Камера не поддерживает выбранный поворот для записи."
            publish()
            return
        }
        let routing = state.audioRouting
        if routing != .original {
            guard AudioRouting.ffmpeg != nil else {
                state.message = "Для копирования канала нужен FFmpeg."
                publish()
                return
            }
            guard let audio = output.connection(with: .audio), audio.audioChannels.count >= routing.requiredChannels else {
                state.message = "На выбранном устройстве нет нужного аудиовхода."
                publish()
                return
            }
        }
        if state.systemAudioActive, state.systemMix != .microphone, AudioRouting.ffmpeg == nil {
            state.message = "Для выбора звуковых дорожек нужен FFmpeg."
            publish()
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let disk = try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            if let disk, Int64(disk) <= reserve { throw CaptureFailure("На диске осталось меньше 512 МБ.") }
        } catch {
            state.message = "Нельзя записать в выбранную папку: \(error.localizedDescription)"
            publish()
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let stamp = formatter.string(from: Date())
        let url = folder.appendingPathComponent("Запись \(stamp) \(UUID().uuidString.prefix(8)).mov")
        output.setOutputSettings(codec.settings(for: mode), for: connection)
        connection.videoRotationAngle = state.rotation
        state.phase = .starting
        recordingAudioPeaks.removeAll()
        state.message = nil
        state.result = nil
        state.elapsed = 0
        recordingURL = url
        interruption = nil
        stopAfterStart = false
        systemCaptureURL = state.systemAudioActive
            ? url.deletingLastPathComponent().appendingPathComponent(".system-\(UUID().uuidString.prefix(8)).wav")
            : nil
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Запись видео")
        publish()
        output.startRecording(to: url, recordingDelegate: self)
    }

    private func stopRecording() {
        if state.phase == .starting { stopAfterStart = true }
        if state.phase == .recording {
            state.phase = .finishing
            publish()
            output.stopRecording()
        }
    }

    private func sessionFailed(_ message: String) {
        if recordingURL != nil {
            interruption = interruption ?? message
            state.message = message
            refreshAfterRecording = true
            stopRecording()
        } else {
            state.message = message
            updateActiveSettings()
        }
        publish()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        recordingStarted(at: url, startHostTime: nil)
    }

    @available(macOS 15.2, *)
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, startPTS: CMTime,
                    from connections: [AVCaptureConnection]) {
        var hostTime: Double?
        if let clock = session.synchronizationClock {
            let converted = CMSyncConvertTime(startPTS, from: clock, to: CMClockGetHostTimeClock())
            if converted.isNumeric, converted.seconds.isFinite { hostTime = converted.seconds }
        }
        recordingStarted(at: url, startHostTime: hostTime)
    }

    private func recordingStarted(at url: URL, startHostTime: Double?) {
        queue.async {
            guard self.recordingURL == url, self.state.phase == .starting else { return }
            self.state.phase = .recording
            if let systemCaptureURL = self.systemCaptureURL {
                do {
                    try self.systemTap.startCapture(to: systemCaptureURL, startHostTime: startHostTime)
                } catch {
                    self.systemCaptureURL = nil
                    self.state.message = "Системный звук не записан. \(error.localizedDescription)"
                    self.interruption = self.state.message
                    self.stopAfterStart = true
                }
            }
            if self.stopAfterStart { self.stopRecording() }
            self.publish()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard self.recordingURL == url else { return }
            self.systemTap.stopCapture()
            let systemFile = self.systemCaptureURL
            let systemWriteError = self.systemTap.recordingError
            self.systemCaptureURL = nil
            self.state.phase = .finishing
            self.publish()
            let exists = FileManager.default.fileExists(atPath: url.path)
            let routing = self.state.audioRouting
            let mix = self.state.systemMix
            Task {
                if exists, (systemFile != nil && mix != .microphone) || routing != .original {
                    var systemWarning: String?
                    if let systemFile, mix != .microphone, let executable = AudioRouting.ffmpeg,
                       let peak = AudioRouting.trackPeak(in: systemFile, stream: 0, using: executable), peak < -55 {
                        systemWarning = "Системная дорожка пустая. Проверь, что Ableton или другой плеер играет на выбранное устройство, и что шкала «Программы» двигалась во время записи."
                    }
                    do {
                        if let systemWriteError { throw CaptureFailure(systemWriteError) }
                        if let systemWarning { throw CaptureFailure(systemWarning) }
                        let info = try await routing.apply(to: url, mix: mix, systemFile: systemFile)
                        if let systemFile { try? FileManager.default.removeItem(at: systemFile) }
                        self.queue.async { self.finish(url: url, exists: true, info: info, error: error, audioWarning: systemWarning) }
                        return
                    } catch let routingError {
                        let info = try? await RecordingInfo.read(url)
                        let action = systemFile != nil ? "Дорожки не объединены" : "Звук не скопирован"
                        var warning = "\(action). Исходная запись сохранена. \(routingError.localizedDescription)"
                        if let systemFile {
                            let recovery = url.deletingPathExtension().appendingPathExtension("Ableton.wav")
                            do {
                                try FileManager.default.moveItem(at: systemFile, to: recovery)
                                warning += " Звук программ сохранён отдельно: \(recovery.lastPathComponent)."
                            } catch {
                                warning += " Временный звук оставлен в папке записи: \(systemFile.lastPathComponent)."
                            }
                        }
                        if let systemWarning { warning += " " + systemWarning }
                        self.queue.async {
                            self.finish(url: url, exists: true, info: info, error: error, audioWarning: warning)
                        }
                        return
                    }
                }
                if let systemFile { try? FileManager.default.removeItem(at: systemFile) }
                let info = try? await RecordingInfo.read(url)
                self.queue.async { self.finish(url: url, exists: exists, info: info, error: error) }
            }
        }
    }

    private func finish(url: URL, exists: Bool, info: RecordingInfo?, error: Error?, audioWarning: String? = nil) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let issue = interruption ?? error?.localizedDescription
        let warning: String?
        if !exists { warning = issue ?? "Файл не был создан." }
        else if info == nil { warning = issue ?? "Файл не содержит пригодной видеодорожки." }
        else if info?.audioChannels == 0 { warning = "В файле нет звуковой дорожки. " + (issue ?? "Проверь аудиовход.") }
        else { warning = issue }
        let warnings = [audioWarning, warning].compactMap { $0 }
        state.result = RecordingResult(url: exists ? url : nil, info: info,
                                       warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
        recordingURL = nil
        state.phase = .idle
        if refreshAfterRecording {
            refreshAfterRecording = false
            discover(force: true)
        } else {
            updateActiveSettings()
            publish()
        }
    }

    private func publish() {
        guard state != published else { return }
        published = state
        let snapshot = state
        DispatchQueue.main.async { [weak self] in self?.onState?(snapshot) }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        timer?.cancel()
        systemTap.stop()
    }
}

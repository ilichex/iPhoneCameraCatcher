import AVFoundation
import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: CatcherModel
    private var state: CaptureState { model.state }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    preview
                    if let result = state.result { resultView(result) }
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        sources
                            .disabled(state.phase != .idle)
                        audioPreview
                        Divider()
                        quality
                            .disabled(state.phase != .idle)
                        Divider()
                        location
                            .disabled(state.phase != .idle)
                    }
                    .padding(20)
                    .disabled(!model.activated)
                }
                .frame(width: 326)
                .background(.regularMaterial)
            }
        }
        .frame(minWidth: 820, minHeight: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("iPhone Camera Catcher").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.phase != .idle {
                Text(timerLabel).font(.system(.body, design: .monospaced).weight(.medium))
                    .accessibilityLabel("Время записи: \(timerLabel)")
            }
            if model.activated {
                if state.phase == .idle {
                    Button(action: model.record) { Label("Записать", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!state.ready)
                } else {
                    Button(action: model.stop) { Label("Остановить", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.phase == .finishing)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var preview: some View {
        ZStack {
            Color.black
            CameraPreview(session: model.engine.session, rotation: state.rotation, selectedPoint: state.cameraPoint,
                          onPoint: cameraPointHandler)
                .opacity(state.isPreviewing ? 1 : 0)
                .accessibilityLabel("Предпросмотр камеры")
                .accessibilityHidden(!state.isPreviewing)
            if !state.isPreviewing {
                VStack(spacing: 14) {
                    Image(systemName: model.activated ? "iphone.and.arrow.right.inward" : "video")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.65))
                        .accessibilityHidden(true)
                    Text(model.activated ? "Подключи камеру" : "Камера iPhone. Звук с Mac.")
                        .font(.title2.weight(.semibold))
                    Text(model.permissionIssue ?? (model.activated ?
                         "Подключи iPhone по USB, подтверди доверие и заблокируй экран. Для пробы можно выбрать встроенную камеру Mac." :
                         "Подключи iPhone и разреши доступ к камере и микрофону для предпросмотра."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: 330)
                    if !model.activated {
                        Button(model.grantingAccess ? "Ожидаем разрешения…" : "Включить предпросмотр") {
                            Task { await model.activate() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.grantingAccess)
                        if model.permissionIssue != nil {
                            Button("Открыть настройки macOS", action: model.openPrivacySettings)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(24)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
            }
            if let message = state.message, model.activated {
                VStack {
                    Spacer()
                    Label(message, systemImage: "info.circle")
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cameraPointHandler: ((CGPoint) -> Void)? {
        guard state.isPreviewing, state.phase == .idle,
              state.canSetFocusPoint || state.canSetExposurePoint else { return nil }
        let cameraID = state.cameraID
        return { model.engine.setCameraPoint($0, cameraID: cameraID) }
    }

    private var cameraPointHelp: String {
        switch (state.canSetFocusPoint, state.canSetExposurePoint) {
        case (true, true): "Кликни по кадру, чтобы навести фокус и замерить экспозицию в этой точке."
        case (true, false): "Кликни по кадру для фокуса. Точечный замер экспозиции недоступен."
        case (false, true): "Кликни по кадру для замера экспозиции. Выбор точки фокуса недоступен."
        case (false, false): "Камера не позволяет выбрать точку фокуса или экспозиции с Mac."
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                section("Источники", icon: "cable.connector")
                Spacer()
                Button(action: model.engine.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Обновить список устройств")
                    .accessibilityLabel("Обновить список устройств")
            }
            Picker("Камера", selection: Binding(get: { state.cameraID }, set: model.engine.chooseCamera)) {
                Text("Найти iPhone").tag("")
                if !state.cameraID.isEmpty, !state.cameras.contains(where: { $0.id == state.cameraID }) {
                    Text("Камера отключена").tag(state.cameraID)
                }
                ForEach(state.cameras) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityLabel("Камера")
            Text("Микрофон").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.top, 4)
            Picker("Микрофон", selection: Binding(get: { state.microphoneID }, set: model.engine.chooseMicrophone)) {
                Text("Встроенный микрофон Mac").tag("")
                if !state.microphoneID.isEmpty, !state.microphones.contains(where: { $0.id == state.microphoneID }) {
                    Text("Аудиовход отключён").tag(state.microphoneID)
                }
                ForEach(state.microphones) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityLabel("Микрофон")
        }
    }

    private var audioPreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            if state.levels.count > 1 || state.audioRouting != .original {
                Picker("Звук в файле", selection: Binding(get: { state.audioRouting }, set: model.engine.chooseAudioRouting)) {
                    ForEach(AudioRouting.allCases) { routing in
                        Text(routing.label).tag(routing)
                    }
                }
                .disabled(state.phase != .idle)
            }
            if !state.levels.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Вход").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(state.levels.indices, id: \.self) { index in
                            meterRow("\(index + 1)", level: state.levels[index], description: "Физический вход \(index + 1)")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("В файле").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .help("Предварительный уровень. В режиме «Авто» решение уточняется после записи.")
                        let outputLevels = state.outputLevels
                        if outputLevels.count == 2 {
                            meterRow("Л", level: outputLevels[0], description: "Левый канал в файле")
                            meterRow("П", level: outputLevels[1], description: "Правый канал в файле")
                        }
                    }
                }
                if state.oneSidedInput != nil {
                    if state.audioRouting == .original {
                        oneSidedWarning
                    } else if state.audioRouting == .automatic {
                        Label("Авто: сигнал на обе стороны", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Уровень звука появится после подключения входа.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var oneSidedWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Звук только с одной стороны", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
            if AudioRouting.ffmpeg != nil {
                Button("Исправить", action: model.engine.fixOneSidedAudio)
                    .buttonStyle(.bordered)
                    .disabled(state.phase != .idle && state.phase != .recording)
            } else {
                Text("Для исправления нужен FFmpeg.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
    }

    private func meterRow(_ label: String, level: Float, description: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 13, alignment: .leading)
            AudioMeter(db: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .accessibilityValue("\(Int(max(-80, min(0, level)))) дБ")
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("Качество", icon: "slider.horizontal.3")
            Picker("Ориентация кадра", selection: Binding(get: { state.orientation }, set: model.engine.chooseOrientation)) {
                ForEach(FrameOrientation.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("Поворот: \(Int(state.rotation))°. Если угол не меняется, выбери поворот по предпросмотру.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Разрешение и частота").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Picker("Разрешение и частота", selection: Binding(get: { state.modeID }, set: model.engine.chooseMode)) {
                Text("Авто — максимум камеры").tag("")
                ForEach(state.modes) { Text($0.label).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityLabel("Разрешение и частота")
            .disabled(state.modes.isEmpty)
            if let mode = state.activeMode {
                let displayed = state.rotation == 90 || state.rotation == 270
                    ? CaptureMode(width: mode.height, height: mode.width, fps: mode.fps)
                    : mode
                Text("Кадр: \(displayed.label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Кодек записи").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.top, 4)
            Picker("Кодек записи", selection: Binding(get: { state.selectedCodec }, set: model.engine.chooseCodec)) {
                Text(FileCodec.automatic.label).tag(FileCodec.automatic)
                if state.selectedCodec != .automatic, !state.codecs.contains(state.selectedCodec) {
                    Text("\(state.selectedCodec.label) — недоступен").tag(state.selectedCodec)
                }
                ForEach(state.codecs) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Кодек записи")
            .disabled(state.codecs.isEmpty)
            if let codec = state.activeCodec {
                let warning = codec.largeFile ? " · большой файл" : ""
                Text("Выбран: \(codec.label)\(warning)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(CameraLock.allCases) { setting in
                if let locked = state.locks[setting] {
                    Toggle("Зафиксировать: \(setting.rawValue.lowercased())", isOn: Binding(get: { locked }, set: {
                        model.engine.setLock(setting, locked: $0)
                    }))
                    .toggleStyle(.checkbox)
                }
            }
            if state.isPreviewing {
                Label(cameraPointHelp, systemImage: "scope")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.centerStageEnabled != nil {
                Toggle("В центре внимания", isOn: Binding(
                    get: { state.centerStageEnabled ?? false },
                    set: model.engine.setCenterStage
                ))
                .toggleStyle(.checkbox)
            }
            Text("Если кадр тесный, отключи «В центре внимания» и проверь масштаб в меню «Видео» macOS.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private var location: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("Папка записи", icon: "folder")
            Text((model.folder.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(model.folder.path)
            Button("Выбрать папку…", action: model.pickFolder)
        }
    }

    private func resultView(_ result: RecordingResult) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: result.warning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.warning == nil ? .green : .orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.warning ?? "Запись сохранена").font(.callout.weight(.semibold))
                    if let info = result.info { Text(info.summary).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let url = result.url {
                    Button("Показать в Finder") { model.reveal(url) }
                }
            }
            .padding(16)
        }
    }

    private func section(_ name: String, icon: String) -> some View {
        Label(name, systemImage: icon).font(.headline)
    }

    private var timerLabel: String {
        String(format: "%02d:%02d:%02d", state.elapsed / 3600, (state.elapsed / 60) % 60, state.elapsed % 60)
    }

    private var status: String {
        switch state.phase {
        case .starting: "Запуск записи…"
        case .recording: "Идёт запись"
        case .finishing: "Сохраняем и проверяем файл…"
        case .idle: state.ready ? "Камера и микрофон готовы" : "Подготовка источников"
        }
    }
}

private struct AudioMeter: View {
    let db: Float

    var body: some View {
        GeometryReader { geometry in
            let progress = CGFloat(max(0, min(1, (db + 60) / 60)))
            Capsule().fill(.quaternary)
            Capsule().fill(db > -3 ? Color.orange : Color.green)
                .frame(width: geometry.size.width * progress)
        }
        .frame(height: 5)
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let rotation: CGFloat
    let selectedPoint: CGPoint?
    let onPoint: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.video.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewHost, context: Context) {
        if let connection = nsView.video.connection, connection.videoRotationAngle != rotation,
           connection.isVideoRotationAngleSupported(rotation) {
            connection.videoRotationAngle = rotation
        }
        nsView.onPoint = onPoint
        nsView.selectedPoint = selectedPoint
        nsView.updatePointMarker()
    }
}

private final class PreviewHost: NSView {
    let video = AVCaptureVideoPreviewLayer()
    var onPoint: ((CGPoint) -> Void)?
    var selectedPoint: CGPoint?
    private let pointMarker = CALayer()

    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer { video }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        video.videoGravity = .resizeAspect
        wantsLayer = true
        pointMarker.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        pointMarker.cornerRadius = 6
        pointMarker.borderWidth = 2
        pointMarker.borderColor = NSColor.systemYellow.cgColor
        pointMarker.isHidden = true
        video.addSublayer(pointMarker)
    }

    override func layout() {
        super.layout()
        updatePointMarker()
    }

    override func mouseDown(with event: NSEvent) {
        guard let onPoint, video.connection?.isActive == true else {
            super.mouseDown(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        // Поля вокруг изображения не относятся к кадру камеры.
        let imageRect = video.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard imageRect.contains(location) else { return }
        onPoint(video.captureDevicePointConverted(fromLayerPoint: location))
    }

    func updatePointMarker() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let selectedPoint, video.connection?.isActive == true {
            pointMarker.position = video.layerPointConverted(fromCaptureDevicePoint: selectedPoint)
            pointMarker.isHidden = false
        } else {
            pointMarker.isHidden = true
        }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { nil }
}

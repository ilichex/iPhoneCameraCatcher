import AppKit
import AVFoundation
import SwiftUI

@main
struct CatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CatcherModel()

    var body: some Scene {
        Window("iPhone Camera Catcher", id: "recorder") {
            RecorderView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1080, height: 690)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: CatcherModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        model.whenIdle = { sender.reply(toApplicationShouldTerminate: true) }
        model.stop()
        return .terminateLater
    }
}

@MainActor
final class CatcherModel: ObservableObject {
    @Published private(set) var state = CaptureState()
    @Published private(set) var activated = false
    @Published private(set) var grantingAccess = false
    @Published private(set) var permissionIssue: String?
    @Published private(set) var folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/iPhone Camera Catcher", isDirectory: true)

    let engine = CaptureEngine()
    var whenIdle: (() -> Void)?
    private var pendingRecord = false
    var isBusy: Bool { pendingRecord || state.phase != .idle }

    init() {
        if let path = UserDefaults.standard.string(forKey: "outputFolder") {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
        engine.onState = { [weak self] snapshot in
            guard let self else { return }
            self.state = snapshot
            self.notifyIdle()
        }
    }

    func activate() async {
        guard !grantingAccess else { return }
        grantingAccess = true
        defer { grantingAccess = false }

        let video = await request(.video)
        let audio = await request(.audio)
        guard video && audio else {
            let missing = !video && !audio ? "камере и микрофону" : !video ? "камере" : "микрофону"
            permissionIssue = "В настройках конфиденциальности macOS разреши доступ к \(missing) и попробуй снова."
            return
        }
        permissionIssue = nil
        activated = true
        engine.activate()
    }

    private func request(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    func pickFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Папка для записей"
        panel.prompt = "Выбрать"
        panel.directoryURL = folder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            UserDefaults.standard.set(url.path, forKey: "outputFolder")
        }
    }

    func record() {
        guard state.ready, !isBusy else { return }
        pendingRecord = true
        engine.record(in: folder) { [weak self] in
            self?.pendingRecord = false
            self?.notifyIdle()
        }
    }

    private func notifyIdle() {
        guard !isBusy, let whenIdle else { return }
        self.whenIdle = nil
        whenIdle()
    }

    func stop() { engine.stop() }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

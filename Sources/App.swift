import AppKit

/// A menu bar app: click the icon and choose Start Recording, then click it again to stop.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    static let recordingsFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screen Recordings", isDirectory: true)

    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var startDate = Date()
    private var timer: Timer?

    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(withTitle: "Start Recording", action: #selector(AppDelegate.startRecording), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Recordings Folder", action: #selector(AppDelegate.openRecordingsFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Screen Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.imagePosition = .imageLeft
            // Fixed-width digits so the timer doesn't wiggle.
            button.font = .monospacedDigitSystemFont(ofSize: button.font?.pointSize ?? NSFont.systemFontSize, weight: .regular)
        }
        showIdle()

        // macOS shows its own permission prompt the first time.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Opening the app again (e.g. from Spotlight) clicks the menu bar icon, in case
    /// it's hidden behind the notch: it shows the menu, or stops a running recording.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { self.statusItem.button?.performClick(nil) }
        return false
    }

    /// Save a recording in progress before quitting (e.g. when logging out).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder else { return .terminateNow }
        self.recorder = nil
        Task {
            _ = try? await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Recording

    @objc private func startRecording() {
        guard CGPreflightScreenCaptureAccess() else {
            showPermissionHelp()
            return
        }
        // Record the screen whose menu bar was clicked.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        showBusy()
        Task {
            do {
                let url = try Self.newRecordingURL()
                let recorder = Recorder(outputURL: url, displayID: displayID ?? CGMainDisplayID())
                recorder.onUnexpectedStop = { [weak self] error in self?.finishRecording(reason: error) }
                try await recorder.start()
                self.recorder = recorder
                self.showRecording()
            } catch {
                self.showIdle()
                self.showAlert("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    @objc private func stopRecording() {
        finishRecording(reason: nil)
    }

    private func finishRecording(reason: Error?) {
        guard let recorder else { return }
        self.recorder = nil
        showBusy()
        Task {
            do {
                let file = try await recorder.stop()
                self.showIdle()
                if let reason {
                    self.showAlert("Recording stopped", "\(reason.localizedDescription)\n\nEverything up to that point was saved.")
                }
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } catch {
                self.showIdle()
                self.showAlert("Couldn't save the recording", error.localizedDescription)
            }
        }
    }

    @objc private func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    /// e.g. "Screen Recording 2026-10-03 at 14.05.22.mp4"
    private static func newRecordingURL() throws -> URL {
        try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screen Recording \(formatter.string(from: Date()))"
        var url = recordingsFolder.appendingPathComponent(name + ".mp4")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsFolder.appendingPathComponent("\(name) (\(copy)).mp4")
            copy += 1
        }
        return url
    }

    // MARK: - Menu bar icon

    private func showIdle() {
        timer?.invalidate()
        timer = nil
        statusItem.menu = menu
        statusItem.button?.action = nil
        setIcon("record.circle", title: "", tint: nil, tooltip: "Screen Recorder")
    }

    private func showBusy() {
        statusItem.menu = nil
        statusItem.button?.action = nil
        setIcon("ellipsis.circle", title: "", tint: nil, tooltip: "Screen Recorder")
    }

    private func showRecording() {
        statusItem.menu = nil
        statusItem.button?.action = #selector(AppDelegate.stopRecording)
        startDate = Date()
        setIcon("stop.circle.fill", title: " 0:00", tint: .systemRed, tooltip: "Click to stop recording")
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(AppDelegate.updateTimer), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func updateTimer() {
        let seconds = Int(Date().timeIntervalSince(startDate))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        statusItem.button?.title = h > 0 ? String(format: " %d:%02d:%02d", h, m, s) : String(format: " %d:%02d", m, s)
    }

    private func setIcon(_ symbol: String, title: String, tint: NSColor?, tooltip: String) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.image?.isTemplate = true
        button.title = title
        button.contentTintColor = tint
        button.toolTip = tooltip
    }

    // MARK: - Alerts

    private func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recorder to record your screen"
        alert.informativeText = """
            In System Settings, go to Privacy & Security → Screen & System Audio Recording \
            (called Screen Recording on older macOS), turn on Screen Recorder, then quit and reopen it.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if run(alert) == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        run(alert)
    }

    @discardableResult
    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return alert.runModal()
    }
}

import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openFileArgument = "--mini-mark-open-file"
    private static let idleKeepAliveLockFileName = "idle-keep-alive.lock"

    private enum PreparedMarkdownFile {
        case ready(canonicalURL: URL, lock: MarkdownFileInstanceLock?)
        case openedElsewhere
    }

    private var windowControllers: [BrowserWindowController] = []
    private var fileInstanceLocks: [String: MarkdownFileInstanceLock] = [:]
    private var delayedExit: DispatchWorkItem?
    private var idleExit: DispatchWorkItem?
    private var idleKeepAliveFileDescriptor: Int32 = -1
    private var settingsChangeSource: DispatchSourceFileSystemObject?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MiniMDSettingsManager.shared.settings()
        HighlightConfigurationMonitor.shared.start()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivateFileNotification(_:)),
            name: .miniMDActivateFile,
            object: nil
        )

        if let launchURL = launchArgumentFileURL() {
            handleMarkdownFileURLs([launchURL])
        }

        scheduleExitIfNoFileArrives()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleMarkdownFileURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleMarkdownFileURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MiniMDSettingsManager.shared.settings().keepAliveAfterLastWindowClosed
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self, name: .miniMDActivateFile, object: nil)
        leaveIdleKeepAliveMode()
        fileInstanceLocks.removeAll()
    }

    private func launchArgumentFileURL() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: Self.openFileArgument),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }

        return URL(fileURLWithPath: arguments[flagIndex + 1])
    }

    private func handleMarkdownFileURLs(_ urls: [URL]) {
        delayedExit?.cancel()
        delayedExit = nil

        let markdownURLs = urls.filter { Self.isSupportedMarkdownURL($0) }
        guard !markdownURLs.isEmpty else {
            scheduleExitIfNoFileArrives()
            return
        }

        leaveIdleKeepAliveMode()

        let settings = MiniMDSettingsManager.shared.settings()
        for url in markdownURLs {
            if let controller = controller(for: url) {
                present(controller)
            } else if settings.tabsEnabled || windowControllers.isEmpty {
                openInCurrentInstance(url, settings: settings)
            } else {
                launchNewInstance(for: url)
            }
        }
    }

    private func openInCurrentInstance(_ fileURL: URL, settings: MiniMDSettings) {
        switch prepareMarkdownFile(fileURL, settings: settings) {
        case .ready(let canonicalURL, let lock):
            let hostWindow = settings.tabsEnabled ? activeSpaceHostWindow() : nil
            let controller = BrowserWindowController(fileURL: fileURL)
            register(controller, canonicalURL: canonicalURL, lock: lock)

            if let hostWindow,
               let newWindow = controller.window,
               hostWindow !== newWindow {
                hostWindow.addTabbedWindow(newWindow, ordered: .above)
            }

            present(controller)
        case .openedElsewhere:
            if windowControllers.isEmpty {
                scheduleExitIfNoFileArrives()
            }
        }
    }

    private func prepareMarkdownFile(_ fileURL: URL, settings: MiniMDSettings) -> PreparedMarkdownFile {
        if settings.singleInstancePerFile {
            switch MarkdownFileInstanceLock.acquire(for: fileURL) {
            case .acquired(let lock):
                return .ready(canonicalURL: lock.canonicalURL, lock: lock)
            case .occupied(let existingCanonicalURL, let processIdentifier):
                activateExistingInstance(for: existingCanonicalURL, processIdentifier: processIdentifier)
                return .openedElsewhere
            case .unavailable(let error):
                let canonicalURL = MarkdownFileInstanceLock.canonicalFileURL(for: fileURL)
                NSLog("Mini.md could not create a per-file instance lock for %@: %@", canonicalURL.path, String(describing: error))
                return .ready(canonicalURL: canonicalURL, lock: nil)
            }
        }

        return .ready(canonicalURL: MarkdownFileInstanceLock.canonicalFileURL(for: fileURL), lock: nil)
    }

    private func register(_ controller: BrowserWindowController, canonicalURL: URL, lock: MarkdownFileInstanceLock?) {
        controller.onWindowWillClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.handleWindowWillClose(for: controller)
        }

        windowControllers.append(controller)
        if let lock {
            fileInstanceLocks[canonicalURL.path] = lock
        }
    }

    private func handleWindowWillClose(for controller: BrowserWindowController) {
        let canonicalPath = MarkdownFileInstanceLock.canonicalFileURL(for: controller.documentFileURL).path
        fileInstanceLocks[canonicalPath] = nil
        windowControllers.removeAll { $0 === controller }

        guard windowControllers.isEmpty else {
            return
        }

        let settings = MiniMDSettingsManager.shared.settings()
        if !settings.keepAliveAfterLastWindowClosed {
            NSApp.terminate(nil)
            return
        }

        enterIdleKeepAliveMode(settings: settings)
    }

    private func launchNewInstance(for fileURL: URL) {
        let appURL = Bundle.main.bundleURL
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [
            "-n",
            appURL.path,
            "--args",
            Self.openFileArgument,
            fileURL.path
        ]

        do {
            try openProcess.run()
        } catch {
            launchExecutableFallback(for: fileURL, originalError: error)
        }
    }

    private func launchExecutableFallback(for fileURL: URL, originalError: Error) {
        guard let executableURL = Bundle.main.executableURL else {
            NSLog("Mini.md could not launch a new instance for %@: %@", fileURL.path, String(describing: originalError))
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [Self.openFileArgument, fileURL.path]

        do {
            try process.run()
        } catch {
            NSLog("Mini.md executable fallback failed for %@: %@", fileURL.path, String(describing: error))
        }
    }

    private func scheduleExitIfNoFileArrives() {
        guard windowControllers.isEmpty else { return }

        let workItem = DispatchWorkItem {
            if self.windowControllers.isEmpty {
                NSApp.terminate(nil)
            }
        }

        delayedExit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func enterIdleKeepAliveMode(settings: MiniMDSettings) {
        guard acquireIdleKeepAliveSlot() else {
            NSApp.terminate(nil)
            return
        }

        startSettingsFileObserver()
        scheduleIdleExit(after: settings.keepAliveIdleTimeoutSeconds)
    }

    private func leaveIdleKeepAliveMode() {
        idleExit?.cancel()
        idleExit = nil
        stopSettingsFileObserver()
        releaseIdleKeepAliveSlot()
    }

    private func acquireIdleKeepAliveSlot() -> Bool {
        if idleKeepAliveFileDescriptor >= 0 {
            return true
        }

        let lockURL = MiniMDSettingsManager.shared.settingsDirectoryURL
            .appendingPathComponent(Self.idleKeepAliveLockFileName)

        do {
            try FileManager.default.createDirectory(
                at: MiniMDSettingsManager.shared.settingsDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("Mini.md could not create idle keep-alive lock directory: %@", String(describing: error))
            return false
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return false
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        idleKeepAliveFileDescriptor = descriptor
        return true
    }

    private func releaseIdleKeepAliveSlot() {
        guard idleKeepAliveFileDescriptor >= 0 else {
            return
        }

        flock(idleKeepAliveFileDescriptor, LOCK_UN)
        close(idleKeepAliveFileDescriptor)
        idleKeepAliveFileDescriptor = -1
    }

    private func scheduleIdleExit(after timeout: TimeInterval) {
        idleExit?.cancel()
        idleExit = nil

        guard timeout > 0 else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.windowControllers.isEmpty else {
                return
            }

            NSApp.terminate(nil)
        }

        idleExit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func startSettingsFileObserver() {
        stopSettingsFileObserver()
        _ = MiniMDSettingsManager.shared.settings()

        let descriptor = open(MiniMDSettingsManager.shared.settingsFileURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MiniMDSettingsManager.shared.invalidateCache()
            guard let self,
                  self.windowControllers.isEmpty else {
                return
            }

            NSApp.terminate(nil)
        }

        source.setCancelHandler {
            close(descriptor)
        }

        settingsChangeSource = source
        source.resume()
    }

    private func stopSettingsFileObserver() {
        settingsChangeSource?.cancel()
        settingsChangeSource = nil
    }

    private func controller(for fileURL: URL) -> BrowserWindowController? {
        let canonicalURL = MarkdownFileInstanceLock.canonicalFileURL(for: fileURL)
        return controller(forCanonicalPath: canonicalURL.path)
    }

    private func controller(forCanonicalPath canonicalPath: String) -> BrowserWindowController? {
        windowControllers.first { controller in
            MarkdownFileInstanceLock.canonicalFileURL(for: controller.documentFileURL).path == canonicalPath
        }
    }

    private func activeSpaceHostWindow() -> NSWindow? {
        windowControllers
            .compactMap(\.window)
            .first { window in
                window.isVisible && window.isOnActiveSpace
            }
    }

    private func present(_ controller: BrowserWindowController) {
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func activateExistingInstance(for canonicalURL: URL, processIdentifier: pid_t?) {
        DistributedNotificationCenter.default().postNotificationName(
            .miniMDActivateFile,
            object: nil,
            userInfo: ["path": canonicalURL.path],
            deliverImmediately: true
        )

        if let processIdentifier,
           let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) {
            runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    @objc private func handleActivateFileNotification(_ notification: Notification) {
        guard let requestedPath = notification.userInfo?["path"] as? String,
              let controller = controller(forCanonicalPath: requestedPath) else {
            return
        }

        present(controller)
    }

    private static func isSupportedMarkdownURL(_ url: URL) -> Bool {
        let supportedExtensions = ["md", "markdown", "mdown", "mkdn"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

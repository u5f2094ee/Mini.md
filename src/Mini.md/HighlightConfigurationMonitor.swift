import Darwin
import Foundation

final class HighlightConfigurationMonitor: @unchecked Sendable {
    static let shared = HighlightConfigurationMonitor()

    private let store: HighlightConfigurationStore
    private let queue = DispatchQueue(label: "com.openai-codex.zhangzheng.minimd.highlight-monitor")
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastSignature: HighlightFileSignature?
    private var isStarted = false

    init(store: HighlightConfigurationStore = .shared) {
        self.store = store
    }

    func start() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            guard !self.isStarted else {
                return
            }

            self.store.ensureConfigurationFile()
            self.lastSignature = self.store.currentFileSignature()

            let descriptor = open(self.store.configurationDirectoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                NSLog("Mini.md could not monitor highlight directory %@: errno %d", self.store.configurationDirectoryURL.path, errno)
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend],
                queue: self.queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebouncedReload()
            }
            source.setCancelHandler {
                close(descriptor)
            }

            self.source = source
            self.isStarted = true
            source.resume()
        }
    }

    private func scheduleDebouncedReload() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.handleDebouncedFileEvent()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func handleDebouncedFileEvent() {
        guard store.refreshAfterFileSystemEvent(previousSignature: &lastSignature) else {
            return
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .miniMDHighlightConfigurationDidChange,
                object: self.store.configurationFileURL
            )
        }
    }
}

extension Notification.Name {
    static let miniMDHighlightConfigurationDidChange = Notification.Name("com.openai-codex.zhangzheng.minimd.highlightConfigurationDidChange")
}

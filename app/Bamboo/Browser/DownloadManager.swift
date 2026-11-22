import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case downloading
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL?
    let startedAt = Date.now
    var filename: String
    var destination: URL?
    var state: State = .downloading
    var fractionCompleted: Double = 0
    var totalBytes: Int64 = 0
    var completedBytes: Int64 = 0
    @ObservationIgnored let download: WKDownload
    @ObservationIgnored fileprivate var progressObservation: NSKeyValueObservation?

    init(download: WKDownload) {
        self.download = download
        sourceURL = download.originalRequest?.url
        filename = download.originalRequest?.url?.lastPathComponent ?? "download"
    }

    func cancel() {
        download.cancel { _ in }
        state = .cancelled
    }

    func revealInFinder() {
        guard let destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

/// Tracks WebKit downloads and saves them to ~/Downloads (or asks where, per Settings).
@MainActor
@Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    private(set) var items: [DownloadItem] = []

    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    func track(_ download: WKDownload) {
        let item = DownloadItem(download: download)
        item.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            let total = progress.totalUnitCount
            let completed = progress.completedUnitCount
            Task { @MainActor in
                item?.fractionCompleted = fraction
                item?.totalBytes = total
                item?.completedBytes = completed
            }
        }
        items.insert(item, at: 0)
        download.delegate = self
    }

    func clearFinished() {
        items.removeAll { $0.state != .downloading }
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let item = item(for: download) else { return nil }
        item.filename = suggestedFilename

        if AppServices.shared.settings.askWhereToSaveDownloads {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            guard await panel.begin() == .OK, let url = panel.url else {
                item.state = .cancelled
                return nil
            }
            // The panel already confirmed replacing an existing file.
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    item.state = .failed(error.localizedDescription)
                    return nil
                }
            }
            item.destination = url
            return url
        }

        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = Self.uniqueURL(in: folder, for: suggestedFilename)
        item.destination = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.fractionCompleted = 1
        if let destination = item.destination {
            // Bounce the Downloads stack in the Dock, like Safari.
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: destination.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.state != .cancelled else { return }
        item.state = .failed(error.localizedDescription)
    }

    /// "file.zip", then "file 2.zip", "file 3.zip", ... like Finder.
    static func uniqueURL(in folder: URL, for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}

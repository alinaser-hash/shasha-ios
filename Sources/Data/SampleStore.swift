import Foundation

/// Downloads the first part of the file playing now into the app's Documents ("On My iPhone › شاشة" in Files),
/// so the same file can be played locally (network vs local test) or shared for inspection.
@MainActor final class SampleStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = SampleStore()
    @Published var progress: Double?
    @Published var lastFile: URL?
    @Published var error: String?
    private var session: URLSession?
    private var name = "sample"

    static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// First `megabytes` MB of `url` (HTTP Range). MKV/MP4 files start with their headers, so the part plays from the start.
    func download(_ url: URL, title: String, ext: String, megabytes: Int) {
        guard progress == nil else { return }
        error = nil
        name = title.replacingOccurrences(of: #"[^\p{L}\p{N} ._-]+"#, with: "_", options: .regularExpression)
            .prefix(60) + "-\(megabytes)MB.\(ext.isEmpty ? "mkv" : ext)"
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.setValue("bytes=0-\(megabytes * 1_048_576 - 1)", forHTTPHeaderField: "Range")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        progress = 0
        s.downloadTask(with: r).resume()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in self.progress = p }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: tmp)
        Task { @MainActor in
            guard code == 206 || code == 200 else { self.error = "الخادم ردّ \(code)"; return }
            let dest = Self.folder.appendingPathComponent(self.name)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: tmp, to: dest); self.lastFile = dest } catch { self.error = error.localizedDescription }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error { self.error = error.localizedDescription }
            self.progress = nil
            self.session?.finishTasksAndInvalidate(); self.session = nil
        }
    }
}

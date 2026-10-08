import Foundation

struct RangeUnsupported: Error {}

enum DownloadEngineError: LocalizedError {
    case httpStatus(Int)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "服务器返回错误（HTTP \(code)）"
        case .serverError(let msg): return msg
        }
    }
}

final class AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(_ permits: Int) {
        self.permits = permits
    }

    func wait() async {
        lock.lock()
        if permits > 0 {
            permits -= 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        if waiters.isEmpty {
            permits += 1
            lock.unlock()
        } else {
            let cont = waiters.removeFirst()
            lock.unlock()
            cont.resume()
        }
    }
}

final class DownloadEngine {
    static let segmentSize: Int64 = 8 * 1024 * 1024
    static let smallFileThreshold: Int64 = 4 * 1024 * 1024
    static let maxConnections = 8
    static let maxSegments = 1024
    static let maxRetries = 2

    let url: URL
    let destination: URL
    let session: URLSession

    var onProgress: ((Int64, Int64?) -> Void)?
    var onPhase: ((String) -> Void)?

    private var cancelled = false
    private var downloadedBytes: Int64 = 0
    private var totalBytes: Int64?
    private let stateLock = NSLock()

    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = Self.maxConnections * 2
        config.httpShouldUsePipelining = false
        self.session = URLSession(configuration: config)
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
        session.invalidateAndCancel()
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func checkCancelled() throws {
        if isCancelled() { throw CancellationError() }
    }

    private func addDownloaded(_ n: Int64) {
        stateLock.lock()
        downloadedBytes += n
        stateLock.unlock()
        reportProgress()
    }

    private func reportProgress() {
        var d: Int64 = 0
        var t: Int64?
        stateLock.lock()
        d = downloadedBytes
        t = totalBytes
        stateLock.unlock()
        onProgress?(d, t)
    }

    func download() async throws {
        let dirURL = destination.deletingLastPathComponent()
        let fileName = destination.lastPathComponent
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        stateLock.lock()
        cancelled = false
        downloadedBytes = 0
        totalBytes = nil
        stateLock.unlock()

        cleanupParts(dirURL: dirURL, fileName: fileName)
        reportProgress()

        let total = try await probeSize()

        if let total = total, total >= Self.smallFileThreshold {
            do {
                stateLock.lock()
                totalBytes = total
                stateLock.unlock()
                reportProgress()
                let count = try await downloadSegmented(total: total, dirURL: dirURL, fileName: fileName)
                onPhase?("正在合并文件…")
                try mergeParts(dirURL: dirURL, fileName: fileName, count: count)
                cleanupParts(dirURL: dirURL, fileName: fileName)
                return
            } catch is RangeUnsupported {
                stateLock.lock()
                downloadedBytes = 0
                totalBytes = nil
                stateLock.unlock()
                cleanupParts(dirURL: dirURL, fileName: fileName)
                reportProgress()
            } catch {
                throw error
            }
        }

        try await downloadSingle(dirURL: dirURL, fileName: fileName)
    }

    private func probeSize() async throws -> Int64? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = 15

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 206,
              let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let total = Self.parseContentRangeTotal(cr) else { return nil }
        return total
    }

    private static func parseContentRangeTotal(_ header: String) -> Int64? {
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let s = header[header.index(after: slash)...]
        return Int64(s.trimmingCharacters(in: .whitespaces))
    }

    private func segmentCount(for total: Int64) -> Int {
        let c = (total + Self.segmentSize - 1) / Self.segmentSize
        return Int(min(Int64(Self.maxSegments), max(1, c)))
    }

    private func downloadSegmented(total: Int64, dirURL: URL, fileName: String) async throws -> Int {
        let count = segmentCount(for: total)
        let segSize = (total + Int64(count) - 1) / Int64(count)
        let semaphore = AsyncSemaphore(Self.maxConnections)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let start = Int64(i) * segSize
                let end = min(total - 1, start + segSize - 1)
                group.addTask {
                    await semaphore.wait()
                    defer { semaphore.signal() }
                    try await self.downloadSegment(start: start, end: end, index: i, dirURL: dirURL, fileName: fileName)
                }
            }
            try await group.waitForAll()
        }
        return count
    }

    private func downloadSegment(start: Int64, end: Int64, index: Int, dirURL: URL, fileName: String) async throws {
        var lastError: Error?
        for attempt in 0...Self.maxRetries {
            do {
                try await downloadSegmentOnce(start: start, end: end, index: index, dirURL: dirURL, fileName: fileName)
                return
            } catch is RangeUnsupported {
                throw RangeUnsupported()
            } catch {
                lastError = error
                try checkCancelled()
                if attempt < Self.maxRetries {
                    try await Task.sleep(nanoseconds: UInt64(200_000_000) * UInt64(attempt + 1))
                }
            }
        }
        throw lastError ?? DownloadEngineError.serverError("分段下载失败")
    }

    private func downloadSegmentOnce(start: Int64, end: Int64, index: Int, dirURL: URL, fileName: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = 30

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadEngineError.serverError("无效的服务器响应")
        }
        if http.statusCode == 200 { throw RangeUnsupported() }
        guard http.statusCode == 206 else {
            throw DownloadEngineError.httpStatus(http.statusCode)
        }

        let partURL = dirURL.appendingPathComponent("\(fileName).part.\(index)")
        let written = try await streamToFile(bytes: bytes, partURL: partURL)
        let expected = end - start + 1
        if written != expected {
            throw DownloadEngineError.serverError("分段数据不完整（期望 \(expected) 字节，实际 \(written) 字节）")
        }
    }

    private func downloadSingle(dirURL: URL, fileName: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = 30

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadEngineError.serverError("无效的服务器响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadEngineError.httpStatus(http.statusCode)
        }

        let expected = http.expectedContentLength
        stateLock.lock()
        totalBytes = expected >= 0 ? expected : nil
        stateLock.unlock()
        reportProgress()

        let partURL = dirURL.appendingPathComponent("\(fileName).part")
        _ = try await streamToFile(bytes: bytes, partURL: partURL)
        try moveToFinal(partURL: partURL, finalURL: destination)
    }

    private func streamToFile(bytes: URLSession.AsyncBytes, partURL: URL) async throws -> Int64 {
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: partURL)
        defer { try? fh.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var written: Int64 = 0
        var added: Int64 = 0

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try checkCancelled()
                    try fh.write(contentsOf: buffer)
                    let n = Int64(buffer.count)
                    written += n
                    added += n
                    addDownloaded(n)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try fh.write(contentsOf: buffer)
                let n = Int64(buffer.count)
                written += n
                added += n
                addDownloaded(n)
            }
            return written
        } catch {
            addDownloaded(-added)
            throw error
        }
    }

    private func moveToFinal(partURL: URL, finalURL: URL) throws {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partURL, to: finalURL)
    }

    private func mergeParts(dirURL: URL, fileName: String, count: Int) throws {
        let finalURL = destination
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        FileManager.default.createFile(atPath: finalURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: finalURL)
        defer { try? out.close() }
        for i in 0..<count {
            let partURL = dirURL.appendingPathComponent("\(fileName).part.\(i)")
            let data = try Data(contentsOf: partURL)
            try out.write(contentsOf: data)
        }
        try? out.synchronize()
    }

    private func cleanupParts(dirURL: URL, fileName: String) {
        let prefix = fileName + ".part"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) else { return }
        for e in entries where e.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dirURL.appendingPathComponent(e))
        }
    }
}

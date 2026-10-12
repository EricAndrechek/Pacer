import Foundation

/// The real I/O behind `PaceIO.standard`.
enum PaceHTTP {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// One GET, waited for: `pace` is a command line, and every caller needs
    /// the answer before it can say anything. A `file://` URL reads the file
    /// (what `curl` did, and how the tests point it at a fixture), ignoring any
    /// query.
    static func get(_ request: URLRequest) -> PaceResponse? {
        if let url = request.url, url.isFileURL {
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            return PaceResponse(status: nil, body: String(decoding: data, as: UTF8.self))
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: PaceResponse?
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil, let response else { return }
            result = PaceResponse(status: (response as? HTTPURLResponse)?.statusCode,
                                  body: String(decoding: data ?? Data(), as: UTF8.self))
        }
        task.resume()
        done.wait()
        return result
    }

    /// `git -C <path> rev-parse --abbrev-ref HEAD`, or nil.
    static func gitBranch(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }
}

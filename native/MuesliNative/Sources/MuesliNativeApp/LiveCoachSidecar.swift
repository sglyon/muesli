import Foundation

/// Handshake line the sidecar prints to stdout on boot so Swift can discover
/// its bound port and shared-secret bearer token.
struct CoachSidecarHandshake: Codable {
    let port: Int
    let token: String
    let version: String
}

enum LiveCoachSidecarError: LocalizedError {
    case binaryMissing(URL)
    case handshakeTimeout
    case handshakeUnparseable(String)
    case processExited(Int32)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let url):
            return "muesli-agent binary not found at \(url.path)"
        case .handshakeTimeout:
            return "muesli-agent did not announce a port within 5 seconds"
        case .handshakeUnparseable(let line):
            return "muesli-agent emitted an unparseable handshake line: \(line.prefix(200))"
        case .processExited(let code):
            return "muesli-agent exited with status \(code)"
        }
    }
}

/// Manages the lifecycle of the bundled `muesli-agent` sidecar binary.
///
/// Responsibilities:
///  1. Spawn the sidecar with `MUESLI_DATA_DIR` pointing at the app support dir.
///  2. Read the single JSON handshake line it prints on stdout.
///  3. Expose `baseURL` + `bearerToken` so clients can reach it.
///  4. Restart the sidecar with exponential backoff if it crashes.
@MainActor
final class LiveCoachSidecar {
    private var process: Process?
    private(set) var baseURL: URL?
    private(set) var bearerToken: String?
    private(set) var version: String?

    private var restartBackoffMs: Int = 500
    private let maxBackoffMs: Int = 30_000
    private var shuttingDown = false

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func launch() async throws {
        guard !isRunning else { return }
        let handshake = try await spawnAndRead()
        self.baseURL = URL(string: "http://127.0.0.1:\(handshake.port)")
        self.bearerToken = handshake.token
        self.version = handshake.version
        restartBackoffMs = 500  // reset on successful launch
        fputs("[live-coach] sidecar listening on \(self.baseURL?.absoluteString ?? "?") (v\(handshake.version))\n", stderr)
    }

    func shutdown() {
        shuttingDown = true
        process?.terminate()
        process = nil
        baseURL = nil
        bearerToken = nil
    }

    // MARK: - Internal

    /// Resolve the binary path. Respects `MUESLI_SIDECAR_OVERRIDE` for dev.
    private func resolveBinaryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["MUESLI_SIDECAR_OVERRIDE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // Packaged: Contents/Resources/muesli-agent
        if let resources = Bundle.main.resourceURL {
            let packaged = resources.appendingPathComponent("muesli-agent")
            if FileManager.default.isExecutableFile(atPath: packaged.path) {
                return packaged
            }
        }
        // Dev fallback: build output of the sidecar repo (repo-relative).
        let repoRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()   // Contents/
            .deletingLastPathComponent()   // Muesli.app
            .deletingLastPathComponent()   // Applications/
        let fallback = repoRoot.appendingPathComponent("native/sidecar/muesli-agent/dist/muesli-agent")
        return fallback
    }

    private func spawnAndRead() async throws -> CoachSidecarHandshake {
        let binary = resolveBinaryURL()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LiveCoachSidecarError.binaryMissing(binary)
        }

        let dataDir = AppIdentity.supportDirectoryURL.path
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["MUESLI_DATA_DIR"] = dataDir
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                await self?.handleProcessExit(proc)
            }
        }

        try task.run()
        self.process = task

        return try await readHandshake(from: outPipe)
    }

    private func readHandshake(from pipe: Pipe) async throws -> CoachSidecarHandshake {
        let deadline = Date().addingTimeInterval(5.0)
        var buffer = Data()
        while Date() < deadline {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            buffer.append(chunk)
            if let newlineIdx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[..<newlineIdx]
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw LiveCoachSidecarError.handshakeUnparseable("(not utf8)")
                }
                let parsed: CoachSidecarHandshake
                do {
                    parsed = try JSONDecoder().decode(CoachSidecarHandshake.self, from: Data(line.utf8))
                } catch {
                    throw LiveCoachSidecarError.handshakeUnparseable(line)
                }
                drainPipeInBackground(pipe, prefix: "[live-coach:stdout]")
                if let errPipe = process?.standardError as? Pipe {
                    drainPipeInBackground(errPipe, prefix: "[live-coach:stderr]")
                }
                return parsed
            }
        }
        throw LiveCoachSidecarError.handshakeTimeout
    }

    private func drainPipeInBackground(_ pipe: Pipe, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                fputs("\(prefix) \(text)", stderr)
            }
        }
    }

    private func handleProcessExit(_ proc: Process) async {
        if shuttingDown { return }
        fputs("[live-coach] sidecar exited with status \(proc.terminationStatus)\n", stderr)
        baseURL = nil
        bearerToken = nil
        // Exponential backoff restart.
        let delayNs = UInt64(restartBackoffMs) * 1_000_000
        restartBackoffMs = min(restartBackoffMs * 2, maxBackoffMs)
        try? await Task.sleep(nanoseconds: delayNs)
        if shuttingDown { return }
        do {
            try await launch()
        } catch {
            fputs("[live-coach] sidecar restart failed: \(error)\n", stderr)
        }
    }
}

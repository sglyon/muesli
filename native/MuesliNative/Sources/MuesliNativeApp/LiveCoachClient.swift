import Foundation

/// Events streamed from the sidecar in response to a coach turn.
enum CoachStreamEvent: Equatable {
    case delta(String)
    case usage(input: Int?, output: Int?)
    case done
    case error(String)
}

struct CoachTurnRequest: Codable {
    struct Credentials: Codable {
        var apiKey: String?
        var bearer: String?
        var accountId: String?
        var embedderAPIKey: String?

        enum CodingKeys: String, CodingKey {
            case apiKey
            case bearer
            case accountId
            case embedderAPIKey
        }
    }

    struct Turn: Codable {
        enum Kind: String, Codable {
            case transcriptUpdate
            case userMessage
        }
        var kind: Kind
        var content: String
    }

    var threadId: String
    var resourceId: String
    var provider: String
    var model: String
    var credentials: Credentials
    var systemPrompt: String
    var agentInstructions: String?
    /// Mastra working-memory template for the active profile. Sidecar caches
    /// Memory instances by (embedderKey, templateHash) so each profile keeps
    /// its own working memory.
    var workingMemoryTemplate: String?
    var turn: Turn
}

struct HistoricalCoachMessage: Codable, Equatable {
    var id: String
    var role: String
    var content: String
    var createdAt: String?
}

struct ThreadHistoryResponse: Codable {
    var threadId: String
    var messages: [HistoricalCoachMessage]
}

enum LiveCoachClientError: LocalizedError {
    case notRunning
    case badResponse(Int, String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Live coach sidecar is not running"
        case .badResponse(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .encodingFailed: return "Failed to encode coach request"
        }
    }
}

/// Abstraction over the sidecar HTTP client so `LiveCoachEngine` can be
/// exercised in tests with a mock implementation that records requests and
/// emits scripted SSE events.
@MainActor
protocol CoachClientProtocol {
    func fetchThread(id: String) async throws -> ThreadHistoryResponse
    func deleteThread(id: String) async throws
    func deleteResource(id: String) async throws
    func streamTurn(_ request: CoachTurnRequest) -> AsyncThrowingStream<CoachStreamEvent, Error>
}

/// Thin HTTP/SSE client that talks to the local muesli-agent sidecar.
@MainActor
final class LiveCoachClient: CoachClientProtocol {
    private let sidecar: LiveCoachSidecar
    private let session: URLSession
    private let encoder: JSONEncoder

    init(sidecar: LiveCoachSidecar, session: URLSession = .shared) {
        self.sidecar = sidecar
        self.session = session
        self.encoder = JSONEncoder()
    }

    func fetchThread(id: String) async throws -> ThreadHistoryResponse {
        guard let (baseURL, token) = currentEndpoint() else { throw LiveCoachClientError.notRunning }
        let url = baseURL.appendingPathComponent("thread").appendingPathComponent(id)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LiveCoachClientError.badResponse(code, body)
        }
        return try JSONDecoder().decode(ThreadHistoryResponse.self, from: data)
    }

    func deleteThread(id: String) async throws {
        try await deleteResource(path: "thread", id: id)
    }

    func deleteResource(id: String) async throws {
        try await deleteResource(path: "resource", id: id)
    }

    private func deleteResource(path: String, id: String) async throws {
        guard let (baseURL, token) = currentEndpoint() else { throw LiveCoachClientError.notRunning }
        let url = baseURL.appendingPathComponent(path).appendingPathComponent(id)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LiveCoachClientError.badResponse(code, body)
        }
    }

    /// Streams a coach turn. Each delta arrives as `.delta(text)`; the stream
    /// ends after `.done` or `.error(message)`.
    func streamTurn(_ request: CoachTurnRequest) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runStream(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runStream(
        request: CoachTurnRequest,
        continuation: AsyncThrowingStream<CoachStreamEvent, Error>.Continuation
    ) async throws {
        guard let (baseURL, token) = currentEndpoint() else {
            throw LiveCoachClientError.notRunning
        }
        let url = baseURL.appendingPathComponent("coach").appendingPathComponent("turn")
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Streaming coach turns can legitimately pause for 30+ seconds if the
        // model is "thinking" or if Mastra is running a side-call (working
        // memory update, title generation). Default URLSession request
        // timeout (60s, treated as idle) kills those mid-stream and the user
        // sees "[error: The request timed out.]". 300s is plenty of head-
        // room; resource timeout stays at URLSession's default (7 days).
        urlReq.timeoutInterval = 300

        let body: Data
        do { body = try encoder.encode(request) } catch { throw LiveCoachClientError.encodingFailed }
        urlReq.httpBody = body

        let (bytes, response) = try await session.bytes(for: urlReq)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let text = String(data: errorData, encoding: .utf8) ?? ""
            continuation.yield(.error("HTTP \(http.statusCode): \(text.prefix(300))"))
            continuation.finish()
            return
        }

        var currentEvent: String?
        var currentData: [String] = []
        for try await line in bytes.lines {
            let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if trimmed.isEmpty {
                dispatchEvent(event: currentEvent, data: currentData.joined(separator: "\n"), continuation: continuation)
                currentEvent = nil
                currentData = []
                continue
            }
            if trimmed.hasPrefix("event:") {
                currentEvent = trimmed.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("data:") {
                currentData.append(String(trimmed.dropFirst("data:".count).drop(while: { $0 == " " })))
            }
        }
        // Flush any trailing event without terminator.
        if currentEvent != nil {
            dispatchEvent(event: currentEvent, data: currentData.joined(separator: "\n"), continuation: continuation)
        }
        continuation.finish()
    }

    private func dispatchEvent(
        event: String?,
        data: String,
        continuation: AsyncThrowingStream<CoachStreamEvent, Error>.Continuation
    ) {
        switch event {
        case "delta":
            continuation.yield(.delta(data))
        case "usage":
            if let parsed = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
                continuation.yield(.usage(input: parsed["input"] as? Int, output: parsed["output"] as? Int))
            }
        case "done":
            continuation.yield(.done)
        case "error":
            let parsed = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
            let message = (parsed?["message"] as? String) ?? data
            continuation.yield(.error(message))
        default:
            break
        }
    }

    private func currentEndpoint() -> (URL, String)? {
        guard let base = sidecar.baseURL, let token = sidecar.bearerToken else { return nil }
        return (base, token)
    }
}

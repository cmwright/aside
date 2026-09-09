import Foundation

/// `200 application/json` body from `POST /v1/audio/transcriptions`.
struct TranscriptionResponse: Codable, Sendable {
    struct Timing: Codable, Sendable {
        var stt: Double
        var cleanup: Double
        var total: Double
    }

    var text: String
    var rawText: String?
    var timing: Timing?

    enum CodingKeys: String, CodingKey {
        case text
        case rawText = "raw_text"
        case timing = "timing_ms"
    }
}

enum BackendError: LocalizedError {
    case badURL
    case http(status: Int, message: String)
    case transport(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Backend URL is not valid. Check Settings."
        case .http(let status, let message):
            switch status {
            case 401: return "Backend rejected the token (401). Check Settings."
            case 400: return "Backend rejected the request (400): \(message)"
            case 502: return "Speech provider failed (502): \(message)"
            default: return "Backend error \(status): \(message)"
            }
        case .transport(let message):
            return "Could not reach the backend: \(message)"
        case .badResponse:
            return "Backend returned something that is not a transcription."
        }
    }
}

struct TranscriptionRequest: Sendable {
    var baseURL: URL
    var token: String?
    var audio: Data
    /// Already-encoded JSON for the `dictionary` field.
    var dictionaryJSON: String
    var cleanup: CleanupLevel
    var appName: String?
    /// Ignored by the Worker, present for OpenAI-client compatibility.
    var model: String = "default"
}

/// `POST /v1/cleanup` for a transcript produced on-device.
struct CleanupRequest: Sendable {
    var baseURL: URL
    var token: String?
    var text: String
    /// Already-encoded JSON for the `dictionary` field.
    var dictionaryJSON: String
    var cleanup: CleanupLevel
    var appName: String?
}

/// Speaks the HTTP contract in PLAN.md and nothing else.
struct BackendClient: Sendable {
    var timeout: TimeInterval = 30
    var session: URLSession = .shared

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        let boundary = "vtt-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: request.baseURL.appendingPathComponent("v1/audio/transcriptions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = request.token, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = BackendClient.multipartBody(boundary: boundary, request: request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse }
        Log.net.info("POST /v1/audio/transcriptions -> \(http.statusCode, privacy: .public)")

        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, message: BackendClient.errorMessage(from: data))
        }
        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw BackendError.badResponse
        }
        return decoded
    }

    func cleanup(_ request: CleanupRequest) async throws -> TranscriptionResponse {
        var urlRequest = URLRequest(url: request.baseURL.appendingPathComponent("v1/cleanup"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = request.token, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = BackendClient.cleanupBody(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse }
        Log.net.info("POST /v1/cleanup -> \(http.statusCode, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, message: BackendClient.errorMessage(from: data))
        }
        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw BackendError.badResponse
        }
        return decoded
    }

    /// Pure and testable: the JSON body for `/v1/cleanup`. `dictionary` is sent as the
    /// same JSON string the multipart route uses, so the Worker parses both identically.
    static func cleanupBody(_ request: CleanupRequest) -> Data {
        var object: [String: Any] = [
            "text": request.text,
            "dictionary": request.dictionaryJSON,
            "cleanup": request.cleanup.rawValue,
        ]
        if let appName = request.appName, !appName.isEmpty {
            object["app_name"] = appName
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// `GET /health`. Returns the raw JSON string so Settings can show it verbatim.
    func health(baseURL: URL, token: String?) async throws -> String {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("health"))
        urlRequest.timeoutInterval = 10
        if let token, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse }
            let body = String(data: data, encoding: .utf8) ?? ""
            guard (200..<300).contains(http.statusCode) else {
                throw BackendError.http(status: http.statusCode, message: BackendClient.errorMessage(from: data))
            }
            return body
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
    }

    /// Pure and testable: the exact multipart body the contract describes.
    static func multipartBody(boundary: String, request: TranscriptionRequest) -> Data {
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(request.audio)
        body.append(Data("\r\n".utf8))

        field("model", request.model)
        field("dictionary", request.dictionaryJSON)
        field("cleanup", request.cleanup.rawValue)
        if let appName = request.appName, !appName.isEmpty {
            field("app_name", appName)
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Errors are `{ "error": string }`; fall back to whatever text arrived.
    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable { let error: String? }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let message = envelope.error {
            return message
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "no details" : String(raw.prefix(200))
    }
}

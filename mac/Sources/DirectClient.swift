import Foundation

enum DirectError: LocalizedError {
    case missingKey(String)
    case http(provider: String, status: Int, message: String)
    case transport(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): return "Add an API key for \(provider) in Settings → Direct providers."
        case .http(let provider, let status, let message): return "\(provider) returned \(status): \(message)"
        case .transport(let message): return "Could not reach the provider: \(message)"
        case .badResponse(let what): return "Provider response did not contain \(what)."
        }
    }
}

/// Talks to any OpenAI-compatible service straight from the app, no Worker in between.
struct DirectClient: Sendable {
    var session: URLSession = .shared
    var timeout: TimeInterval = 30

    /// `POST {base}/audio/transcriptions`, Whisper-style multipart. `vocabulary` becomes
    /// the free-text `prompt` hint, the same trick the Worker uses for Groq.
    func transcribe(audio: Data, endpoint: DirectEndpoint, vocabulary: [String]) async throws -> String {
        let boundary = "aside-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try DirectClient.authorize(&request, endpoint)

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n".utf8))
        field("model", endpoint.model)
        field("response_format", "json")
        field("temperature", "0")
        if let prompt = DirectClient.vocabularyPrompt(vocabulary) { field("prompt", prompt) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data = try await send(request, provider: endpoint.providerName, path: "audio/transcriptions")
        struct Reply: Decodable { let text: String? }
        guard let text = (try? JSONDecoder().decode(Reply.self, from: data))?.text else {
            throw DirectError.badResponse("a \"text\" field")
        }
        return text
    }

    /// `POST {base}/chat/completions` with the cleanup instructions; returns the reply text.
    func chat(endpoint: DirectEndpoint, system: String, user: String) async throws -> String {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try DirectClient.authorize(&request, endpoint)
        request.httpBody = DirectClient.chatBody(model: endpoint.model, system: system, user: user)

        let data = try await send(request, provider: endpoint.providerName, path: "chat/completions")
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message? }
            let choices: [Choice]?
        }
        guard let content = (try? JSONDecoder().decode(Reply.self, from: data))?.choices?.first?.message?.content else {
            throw DirectError.badResponse("a message")
        }
        return content
    }

    /// `GET {base}/models`, used by the Settings "Test" button.
    func listModels(endpoint: DirectEndpoint) async throws -> [String] {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 15
        try DirectClient.authorize(&request, endpoint)
        let data = try await send(request, provider: endpoint.providerName, path: "models")
        struct Reply: Decodable { struct Model: Decodable { let id: String }; let data: [Model]? }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.data?.map(\.id).sorted() ?? []
    }

    // MARK: - Pure helpers (tested)

    static func chatBody(model: String, system: String, user: String) -> Data {
        var object: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        // gpt-oss models think before answering; keep that short for dictation latency.
        if model.lowercased().contains("gpt-oss") { object["reasoning_effort"] = "low" }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Whisper-style hint: a plain list of spellings, capped so it never eats the prompt budget.
    static func vocabularyPrompt(_ terms: [String], maxChars: Int = 700) -> String? {
        var kept: [String] = []
        var length = 0
        for term in terms where !term.isEmpty {
            if length + term.count + 2 > maxChars { break }
            kept.append(term)
            length += term.count + 2
        }
        return kept.isEmpty ? nil : "Vocabulary: \(kept.joined(separator: ", "))."
    }

    /// Every spelling the dictionary wants the speech model to know.
    static func vocabulary(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries {
            let wire = entry.wire
            for term in [wire.replacement ?? wire.term, wire.term] where !term.isEmpty && seen.insert(term.lowercased()).inserted {
                out.append(term)
            }
        }
        return out
    }

    private static func authorize(_ request: inout URLRequest, _ endpoint: DirectEndpoint) throws {
        if let key = endpoint.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func send(_ request: URLRequest, provider: String, path: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DirectError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DirectError.badResponse("an HTTP response") }
        Log.net.info("\(provider, privacy: .public) \(path, privacy: .public) -> \(http.statusCode, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            throw DirectError.http(provider: provider, status: http.statusCode, message: DirectClient.errorMessage(from: data))
        }
        return data
    }

    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
            let message: String?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            if let message = envelope.error?.message { return message }
            if let message = envelope.message { return message }
        }
        struct Flat: Decodable { let error: String? }
        if let flat = try? JSONDecoder().decode(Flat.self, from: data), let message = flat.error { return message }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "no details" : String(raw.prefix(200))
    }
}

import Foundation
import Security

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case gemini, openai
    var id: String { rawValue }
    var title: String { self == .gemini ? "Google Gemini" : "OpenAI（GPT）" }
    var defaultModel: String { self == .gemini ? "gemini-3.1-flash-lite" : "gpt-5-mini" }
}

enum AIKey {
    private static func identity(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.wsxqaza12.return-note.\(provider.rawValue)",
         kSecAttrAccount as String: provider == .gemini ? "Gemini API key" : "OpenAI API key"]
    }

    static func read(_ provider: AIProvider) throws -> String? {
        var query = identity(provider)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw NoteError("無法讀取鑰匙圈的 \(provider.title) API key。")
        }
        return key
    }

    static func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 512,
              key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw NoteError("API key 格式不正確。") }
    }

    static func save(_ key: String, for provider: AIProvider) throws {
        try validate(key)
        let identity = identity(provider)
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(identity.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NoteError("無法儲存 API key 到鑰匙圈。") }
    }

    static func remove(_ provider: AIProvider) throws {
        let status = SecItemDelete(identity(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NoteError("無法從鑰匙圈移除 API key。") }
    }
}

struct AIJobEnvelope: Decodable { let job: AIJob }
struct AIJob: Decodable {
    let provider: AIProvider
    let model: String
    let tags: [[String]]
    let revision: UInt64
    let body: JSONValue
}

// Decodes the request constructed by the shared Rust core without interpreting its schema.
enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a credential or note text to another host.
        completionHandler(nil)
    }
}

final class AIClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    deinit { session.invalidateAndCancel() }

    static func request(job: AIJob, key: String) throws -> URLRequest {
        try AIKey.validate(key)
        guard job.model.range(of: #"\A[A-Za-z0-9.-]{1,100}\z"#, options: .regularExpression) != nil else { throw NoteError("模型名稱格式不正確。") }
        let endpoint = job.provider == .gemini
            ? "https://generativelanguage.googleapis.com/v1beta/models/\(job.model):generateContent"
            : "https://api.openai.com/v1/responses"
        guard let endpoint = URL(string: endpoint) else { throw NoteError("無法建立 API 請求。") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch job.provider {
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openai: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(job.body)
        return request
    }

    func send(job: AIJob, key: String, completion: @escaping (Result<(Int, Any), Error>) -> Void) throws -> URLSessionDataTask {
        let request = try Self.request(job: job, key: key)
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse, let data, data.count <= 2_000_000 else {
                completion(.failure(NoteError("\(job.provider.title) 連線失敗或回應逾時；便條仍保留在本機。"))); return
            }
            let value = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
            completion(.success((http.statusCode, value)))
        }
        task.resume()
        return task
    }
}

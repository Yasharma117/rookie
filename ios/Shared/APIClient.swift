import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case serverError(Int)
    case timeout
    case networkUnavailable
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Authentication expired"
        case .serverError(let code): return "Server error (\(code))"
        case .timeout: return "Request timed out"
        case .networkUnavailable: return "No internet connection"
        case .decodingError: return "Unexpected server response"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder

    init(baseURL: URL = AppConstants.apiBaseURL) {
        self.baseURL = baseURL

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = AppConstants.ingestTimeout
        config.timeoutIntervalForResource = AppConstants.ingestTimeout
        self.session = URLSession(configuration: config)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            let formats: [String] = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss"
            ]
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            for format in formats {
                fmt.dateFormat = format
                if let date = fmt.date(from: str) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Cannot parse date: \(str)"
            )
        }
        self.decoder = dec
    }

    @discardableResult
    func ingest(
        _ req: IngestRequest,
        token: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> IngestResponse {
        var request = urlRequest(path: "v1/links", method: "POST")
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        request.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
        request.setValue(AppConstants.clientVersion, forHTTPHeaderField: "X-Client")
        request.httpBody = try encoder.encode(req)
        return try await perform(request)
    }

    @discardableResult
    func patchLink(id: UUID, categoryIDs: [UUID]?, token: String) async throws -> IngestResponse {
        var request = urlRequest(path: "v1/links/\(id.uuidString.lowercased())", method: "PATCH")
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        var body: [String: Any] = [:]
        if let ids = categoryIDs {
            body["category_ids"] = ids.map { $0.uuidString.lowercased() }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    func fetchLink(id: UUID, token: String) async throws -> IngestResponse {
        var request = urlRequest(path: "v1/links/\(id.uuidString.lowercased())", method: "GET")
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        return try await perform(request)
    }

    @discardableResult
    func resummarizeLink(id: UUID, token: String) async throws -> IngestResponse {
        var request = urlRequest(
            path: "v1/links/\(id.uuidString.lowercased())/resummarize",
            method: "POST"
        )
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        return try await perform(request)
    }

    /// Categories with ETag/304 + local cache. On 304 (or when the body is
    /// unchanged) returns the cached categories; otherwise decodes, refreshes
    /// the cache, and stores the new ETag.
    func fetchCategories(token: String) async throws -> [Category] {
        var request = urlRequest(path: "v1/categories", method: "GET")
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        if let etag = LocalCache.etag(for: "categories") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await rawData(request)
        if http.statusCode == 304 { return LocalCache.loadCategories() }
        do {
            let categories = try decoder.decode([Category].self, from: data)
            LocalCache.setEtag(http.value(forHTTPHeaderField: "ETag"), for: "categories")
            LocalCache.saveCategories(categories)
            return categories
        } catch { throw APIError.decodingError(error) }
    }

    /// Links with ETag/304 + local cache (stale-while-revalidate source).
    func fetchLinks(token: String, limit: Int = 50, offset: Int = 0) async throws -> [IngestResponse] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/links"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        if let etag = LocalCache.etag(for: "links") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await rawData(request)
        if http.statusCode == 304 { return LocalCache.loadLinks() }
        do {
            let envelope = try decoder.decode(LinkListResponse.self, from: data)
            LocalCache.setEtag(http.value(forHTTPHeaderField: "ETag"), for: "links")
            LocalCache.saveLinks(envelope.items)
            return envelope.items
        } catch { throw APIError.decodingError(error) }
    }

    private struct LinkListResponse: Decodable {
        let items: [IngestResponse]
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case items
            case nextCursor = "next_cursor"
        }
    }

    func mintIngestToken(appleJWT: String) async throws -> String {
        struct ExchangeRequest: Encodable { let apple_jwt: String }
        struct ExchangeResponse: Decodable { let token: String }
        var request = urlRequest(path: "v1/auth/exchange", method: "POST")
        request.httpBody = try encoder.encode(ExchangeRequest(apple_jwt: appleJWT))
        let response: ExchangeResponse = try await perform(request)
        return response.token
    }

    func fetchTokens(token: String) async throws -> [IngestTokenOut] {
        var request = urlRequest(path: "v1/ingest-tokens", method: "GET")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    func revokeToken(id: UUID, token: String) async throws {
        var request = urlRequest(path: "v1/ingest-tokens/\(id.uuidString.lowercased())", method: "DELETE")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await performVoid(request)
    }

    // MARK: - Private

    private func performVoid(_ request: URLRequest) async throws {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.networkUnavailable }
            switch http.statusCode {
            case 200...299: return
            case 401: throw APIError.unauthorized
            default: throw APIError.serverError(http.statusCode)
            }
        } catch let error as APIError { throw error }
        catch let error as URLError {
            throw error.code == .timedOut ? APIError.timeout : APIError.networkUnavailable
        }
    }

    private func urlRequest(path: String, method: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// Like `perform` but returns the raw bytes + HTTP response without decoding,
    /// and treats 304 as a success so callers can fall back to their local cache.
    private func rawData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.networkUnavailable }
            switch http.statusCode {
            case 200...299, 304: return (data, http)
            case 401: throw APIError.unauthorized
            default: throw APIError.serverError(http.statusCode)
            }
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                throw APIError.networkUnavailable
            case .timedOut:
                throw APIError.timeout
            default:
                throw APIError.networkUnavailable
            }
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.networkUnavailable }
            switch http.statusCode {
            case 200...299:
                do { return try decoder.decode(T.self, from: data) }
                catch { throw APIError.decodingError(error) }
            case 401: throw APIError.unauthorized
            default: throw APIError.serverError(http.statusCode)
            }
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                throw APIError.networkUnavailable
            case .timedOut:
                throw APIError.timeout
            default:
                throw APIError.networkUnavailable
            }
        }
    }
}

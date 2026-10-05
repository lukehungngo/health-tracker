import Foundation

// Neon Data API speaks the PostgREST HTTP protocol. Keep this small client scoped
// to the operations the tracker actually uses, without a third-party SDK.
struct NeonDataClient {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let fetch: Fetch

    func from(_ table: String) -> Query {
        Query(client: self, path: table)
    }

    func rpc<Parameters: Encodable>(_ function: String, params: Parameters) throws -> Query {
        Query(client: self, path: "rpc/\(function)", method: "POST",
              body: try Self.encoder.encode(params))
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day()
                .dateTimeSeparator(.standard).time(includingFractionalSeconds: true)))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let style = Date.ISO8601FormatStyle().year().month().day()
                .dateTimeSeparator(.standard).time(includingFractionalSeconds: true)
            if let date = try? Date(raw, strategy: style) { return date }
            if let date = try? Date(raw, strategy: style.time(includingFractionalSeconds: false)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(raw)")
        }
        return decoder
    }

    struct Result<Value> {
        let value: Value
    }

    struct Query {
        let client: NeonDataClient
        let path: String
        var method = "GET"
        var parameters: [URLQueryItem] = []
        var body: Data?
        var preference: String?

        func select(_ columns: String) -> Self { adding("select", columns) }
        func eq(_ column: String, value: String) -> Self { adding(column, "eq.\(value)") }
        func gte(_ column: String, value: String) -> Self { adding(column, "gte.\(value)") }
        func gt(_ column: String, value: String) -> Self { adding(column, "gt.\(value)") }
        func lt(_ column: String, value: String) -> Self { adding(column, "lt.\(value)") }
        func order(_ column: String, ascending: Bool) -> Self {
            adding("order", "\(column).\(ascending ? "asc" : "desc")")
        }
        func limit(_ count: Int) -> Self { adding("limit", String(count)) }

        func upsert<Value: Encodable>(_ value: Value, onConflict: String) throws -> Self {
            var query = try writing(value, method: "POST")
            query = query.adding("on_conflict", onConflict)
            query.preference = "resolution=merge-duplicates,return=minimal"
            return query
        }

        func insert<Value: Encodable>(_ value: Value) throws -> Self {
            try writing(value, method: "POST")
        }

        func update<Value: Encodable>(_ value: Value) throws -> Self {
            try writing(value, method: "PATCH")
        }

        func delete() -> Self {
            var query = self
            query.method = "DELETE"
            return query
        }

        func execute<Value: Decodable>() async throws -> Result<Value> {
            let data = try await request()
            return Result(value: try NeonDataClient.decoder.decode(Value.self, from: data))
        }

        func execute() async throws {
            _ = try await request()
        }

        private func adding(_ name: String, _ value: String) -> Self {
            var query = self
            query.parameters.append(URLQueryItem(name: name, value: value))
            return query
        }

        private func writing<Value: Encodable>(_ value: Value, method: String) throws -> Self {
            var query = self
            query.method = method
            query.body = try NeonDataClient.encoder.encode(value)
            query.preference = "return=minimal"
            return query
        }

        private func request() async throws -> Data {
            guard var components = URLComponents(url: client.baseURL.appending(path: path),
                                                 resolvingAgainstBaseURL: false) else {
                throw NeonDataError.invalidURL
            }
            components.queryItems = parameters.isEmpty ? nil : parameters
            guard let url = components.url else { throw NeonDataError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let preference { request.setValue(preference, forHTTPHeaderField: "Prefer") }
            let (data, response) = try await client.fetch(request)
            guard let http = response as? HTTPURLResponse else { throw NeonDataError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw NeonDataError.http(http.statusCode,
                                         message?["message"] as? String ?? "Neon Data API request failed")
            }
            return data
        }
    }
}

enum NeonDataError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Neon Data API URL."
        case .invalidResponse: "Unexpected Neon Data API response."
        case .http(let status, let message): "Neon Data API HTTP \(status): \(message)"
        }
    }
}

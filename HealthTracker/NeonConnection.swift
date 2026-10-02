import Foundation
import PostgREST
import Security

enum NeonConnection {
    static let authURL = configuredURL("NeonAuthURL")
    static let dataURL = configuredURL("NeonDataAPIURL")
    static let mealImageURL = configuredURL("NeonMealImageURL")

    static let client = PostgrestClient(configuration: .init(url: dataURL, logger: nil, fetch: { request in
        var authorized = request
        authorized.setValue("Bearer \(try await NeonSession.shared.jwt())", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: authorized)
    }))

    private static func configuredURL(_ key: String) -> URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            fatalError("Configure \(key) in Config/Local.xcconfig")
        }
        return url
    }
}

enum NeonAuthError: LocalizedError {
    case signedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to sync with Neon."
        case .invalidResponse: "Unexpected authentication response."
        case .server(let message): message
        }
    }
}

actor NeonSession {
    static let shared = NeonSession()
    private let keychainAccount = "neon-session-token"
    private var cachedJWT: String?
    private var jwtExpiry = Date.distantPast
    private var receivedSessionCookie: String?

    private func savedSession() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: keychainAccount,
                                    kSecAttrService as String: Bundle.main.bundleIdentifier ?? "HealthTracker",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveSession(_ token: String?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: keychainAccount,
                                    kSecAttrService as String: Bundle.main.bundleIdentifier ?? "HealthTracker"]
        SecItemDelete(query as CFDictionary)
        cachedJWT = nil
        jwtExpiry = .distantPast
        guard let token else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw NeonAuthError.server("Could not save the session securely.")
        }
    }

    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                      authenticated: Bool = false) async throws -> [String: Any] {
        let url = NeonConnection.authURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let origin = "\(NeonConnection.authURL.scheme!)://\(NeonConnection.authURL.host!)"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if authenticated {
            guard let session = savedSession() else { throw NeonAuthError.signedOut }
            request.setValue("__Secure-neon-auth.session_token=\(session)", forHTTPHeaderField: "Cookie")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NeonAuthError.invalidResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw NeonAuthError.server(json["message"] as? String ?? "Auth HTTP \(http.statusCode)")
        }
        if path == "sign-in/email" || path == "sign-up/email" {
            receivedSessionCookie = http.value(forHTTPHeaderField: "Set-Cookie")?
                .components(separatedBy: "__Secure-neon-auth.session_token=").dropFirst().first?
                .components(separatedBy: ";").first
        }
        return json
    }

    private func identity(_ json: [String: Any]) throws -> (UUID, String?) {
        guard let user = json["user"] as? [String: Any],
              let id = user["id"] as? String, let uuid = UUID(uuidString: id) else {
            throw NeonAuthError.invalidResponse
        }
        return (uuid, user["email"] as? String)
    }

    private func acceptSession(_ json: [String: Any]) throws -> (UUID, String?) {
        guard let token = receivedSessionCookie else { throw NeonAuthError.invalidResponse }
        receivedSessionCookie = nil
        let user = try identity(json)
        try saveSession(token)
        return user
    }

    func restore() async throws -> (UUID, String?) {
        let json = try await call("get-session", authenticated: true)
        return try identity(json)
    }

    func signIn(email: String, password: String) async throws -> (UUID, String?) {
        try acceptSession(await call("sign-in/email", method: "POST", body: [
            "email": email, "password": password,
            "callbackURL": NeonConnection.authURL.absoluteString
        ]))
    }

    func signUp(email: String, password: String) async throws -> (UUID, String?) {
        try acceptSession(await call("sign-up/email", method: "POST", body: [
            "email": email, "password": password, "name": email.components(separatedBy: "@").first ?? "User",
            "callbackURL": NeonConnection.authURL.absoluteString
        ]))
    }

    func jwt() async throws -> String {
        if let cachedJWT, jwtExpiry > Date().addingTimeInterval(30) { return cachedJWT }
        let json = try await call("token", authenticated: true)
        guard let token = json["token"] as? String else { throw NeonAuthError.invalidResponse }
        cachedJWT = token
        jwtExpiry = Self.expiry(of: token) ?? Date().addingTimeInterval(60)
        return token
    }

    private static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let seconds = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func signOut() async throws {
        _ = try await call("sign-out", method: "POST", authenticated: true)
        try saveSession(nil)
    }
}

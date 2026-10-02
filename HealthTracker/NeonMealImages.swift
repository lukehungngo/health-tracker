import Foundation

enum NeonMealImages {
    private struct SignedURL: Decodable { let url: URL }

    private static func signedURL(action: String, path: String) async throws -> URL {
        var request = URLRequest(url: NeonConnection.mealImageURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await NeonSession.shared.jwt())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "path": path])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NeonAuthError.server("Could not get a private meal-image URL.")
        }
        return try JSONDecoder().decode(SignedURL.self, from: data).url
    }

    static func upload(path: String, data: Data) async throws {
        guard data.count <= 10_000_000 else { throw NeonAuthError.server("Meal image exceeds 10 MB.") }
        var request = URLRequest(url: try await signedURL(action: "upload", path: path))
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NeonAuthError.server("Meal image upload failed.")
        }
    }

    static func download(path: String) async throws -> Data {
        let url = try await signedURL(action: "download", path: path)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NeonAuthError.server("Meal image download failed.")
        }
        return data
    }
}

import Foundation
import XCTest
@testable import PersonalHealthTracker

final class NeonDataClientTests: XCTestCase {
    private struct Row: Codable, Equatable {
        let id: UUID
        let recorded_at: Date
    }

    func testSelectFiltersAndDecodesNeonTimestamp() async throws {
        let id = UUID()
        let client = NeonDataClient(baseURL: URL(string: "https://example.neon.tech/rest/v1")!) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/rest/v1/health_samples")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(URLQueryItem(name: "select", value: "id,recorded_at")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "user_id", value: "eq.\(id.uuidString)")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "limit", value: "1")))
            let data = Data("[{\"id\":\"\(id.uuidString)\",\"recorded_at\":\"2026-10-05T12:00:00.123+00:00\"}]".utf8)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let rows: [Row] = try await client.from("health_samples")
            .select("id,recorded_at").eq("user_id", value: id.uuidString).limit(1).execute().value
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, id)
        XCTAssertEqual(rows[0].recorded_at.timeIntervalSince1970, 1_791_201_600.123, accuracy: 0.001)
    }

    func testUpsertUsesConflictKeyAndStableRecordID() async throws {
        let id = UUID()
        let row = Row(id: id, recorded_at: Date(timeIntervalSince1970: 1_791_201_600))
        let client = NeonDataClient(baseURL: URL(string: "https://example.neon.tech/rest/v1")!) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=minimal")
            let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(URLQueryItem(name: "on_conflict", value: "user_id,external_id")))
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try NeonDataClient.decoder.decode(Row.self, from: body)
            XCTAssertEqual(decoded, row)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        try await client.from("health_samples").upsert(row, onConflict: "user_id,external_id").execute()
    }

    func testRejectedUpdateSurfacesServerMessage() async throws {
        let client = NeonDataClient(baseURL: URL(string: "https://example.neon.tech/rest/v1")!) { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(URLQueryItem(name: "user_id", value: "eq.owner")))
            return (Data("{\"message\":\"permission denied\"}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        do {
            try await client.from("meal_estimates").update(["note": "test"])
                .eq("user_id", value: "owner").execute()
            XCTFail("Expected Neon to reject the update")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("permission denied"))
        }
    }
}

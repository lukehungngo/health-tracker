import Foundation
import Supabase

enum SupabaseConnection {
    // Local.xcconfig supplies client configuration; no credential is committed.
    static let client: SupabaseClient = {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
              let url = URL(string: urlString), key.hasPrefix("sb_publishable_") else {
            fatalError("Copy Config/Local.example.xcconfig to Config/Local.xcconfig and configure Supabase")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()
}

import Foundation
import Supabase

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var userID: UUID?
    @Published private(set) var email: String?
    @Published private(set) var isBusy = false
    @Published var message: String?

    private let client = SupabaseConnection.client

    func restore() async {
        do {
            let session = try await client.auth.session
            userID = session.user.id
            email = session.user.email
        } catch {
            userID = nil
            email = nil
        }
    }

    func signIn(email: String, password: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            userID = session.user.id
            self.email = session.user.email
            message = "Signed in."
        } catch {
            message = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func sendSignInLink(email: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.auth.signInWithOTP(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                redirectTo: URL(string: "healthtracker://auth-callback")!,
                shouldCreateUser: false
            )
            message = "Sign-in link sent. Open the newest email link on this Simulator or iPhone."
        } catch {
            message = "Could not send sign-in link: \(error.localizedDescription)"
        }
    }

    func signUp(email: String, password: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                redirectTo: URL(string: "healthtracker://auth-callback")!
            )
            if let session = response.session {
                userID = session.user.id
                self.email = session.user.email
                message = "Account created and signed in."
            } else {
                message = "Check your email to confirm the account. The link should return you to this app."
            }
        } catch {
            message = "Sign-up failed: \(error.localizedDescription)"
        }
    }

    func handleCallback(_ url: URL) async {
        guard url.scheme == "healthtracker", url.host == "auth-callback" else { return }
        do {
            let session = try await client.auth.session(from: url)
            userID = session.user.id
            email = session.user.email
            message = "Signed in from the email link."
        } catch {
            message = "The email link could not sign in: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.auth.signOut()
            userID = nil
            email = nil
            message = "Signed out."
        } catch {
            message = "Sign-out failed: \(error.localizedDescription)"
        }
    }
}

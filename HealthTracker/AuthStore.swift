import Foundation

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var userID: UUID?
    @Published private(set) var email: String?
    @Published private(set) var isBusy = false
    @Published var message: String?

    func restore() async {
        do {
            (userID, email) = try await NeonSession.shared.restore()
        } catch {
            userID = nil
            email = nil
        }
    }

    func signIn(email: String, password: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            (userID, self.email) = try await NeonSession.shared.signIn(email: email, password: password)
            message = "Signed in."
        } catch { message = "Sign-in failed: \(error.localizedDescription)" }
    }

    func signUp(email: String, password: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            (userID, self.email) = try await NeonSession.shared.signUp(email: email, password: password)
            message = "Account created and signed in."
        } catch { message = "Sign-up failed: \(error.localizedDescription)" }
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await NeonSession.shared.signOut()
            userID = nil
            email = nil
            message = "Signed out."
        } catch { message = "Sign-out failed: \(error.localizedDescription)" }
    }
}

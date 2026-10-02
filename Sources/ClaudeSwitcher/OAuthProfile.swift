import CryptoKit
import Foundation

/// Asks Anthropic which account an OAuth token belongs to.
///
/// The credentials blob has no account ID in it, so this is the only reliable way
/// to tell whether the token in the Keychain matches the account in `~/.claude.json`.
/// A running session on another account can refresh its token and overwrite the
/// Keychain item at any time.
enum OAuthProfile {
    enum Owner: Equatable {
        /// `accountUuid:organizationUuid`, the same format as `Account.id`.
        case account(String)
        /// Couldn't tell: offline, expired token, or an unexpected response.
        case unknown
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static var cache: [String: String] = [:]

    static func owner(ofCredentials credentials: String) -> Owner {
        let key = SHA256.hash(data: Data(credentials.utf8)).map { String(format: "%02x", $0) }.joined()
        if let id = cache[key] { return .account(id) }

        guard let data = credentials.data(using: .utf8),
              let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = blob["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return .unknown }

        var request = URLRequest(url: endpoint, timeoutInterval: 4)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        // Called while the menu is opening. This only runs when the token has
        // changed, so blocking for at most a few seconds is acceptable.
        var owner = Owner.unknown
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { body, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let body,
                  let profile = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let account = profile["account"] as? [String: Any],
                  let accountUuid = account["uuid"] as? String,
                  let org = profile["organization"] as? [String: Any],
                  let orgUuid = org["uuid"] as? String else { return }
            owner = .account("\(accountUuid):\(orgUuid)")
        }.resume()
        done.wait()

        if case .account(let id) = owner { cache[key] = id }
        return owner
    }
}

import Foundation

/// Reads and writes the parts of Claude Code's local state that identify the
/// logged-in account: the OAuth credentials in the Keychain and the
/// `oauthAccount` block in `~/.claude.json`.
enum ClaudeConfig {
    static let credentialsService = "Claude Code-credentials"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
            .resolvingSymlinksInPath()
    }

    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Credentials

    static func readCredentials() -> String? {
        Keychain.read(service: credentialsService)
    }

    static func writeCredentials(_ secret: String) throws {
        let account = Keychain.account(service: credentialsService) ?? NSUserName()
        try Keychain.write(service: credentialsService, account: account, secret: secret)
    }

    // MARK: oauthAccount

    private static func loadConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error(message: "~/.claude.json is not a JSON object")
        }
        return object
    }

    /// The current `oauthAccount` block, serialized as JSON.
    static func readOAuthAccount() -> Data? {
        guard let config = try? loadConfig(), let account = config["oauthAccount"] as? [String: Any] else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: account)
    }

    /// Replaces only the `oauthAccount` key and leaves the rest of the file alone.
    static func writeOAuthAccount(_ json: Data) throws {
        var config = try loadConfig()
        config["oauthAccount"] = try JSONSerialization.jsonObject(with: json)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: configURL, options: .atomic)
    }
}

import Foundation

struct Account: Codable, Equatable {
    /// `accountUuid:organizationUuid`. One person can belong to several orgs,
    /// and each one is a separate login.
    var id: String
    var email: String
    var displayName: String
    var organizationName: String
    /// The raw `oauthAccount` block from `~/.claude.json`, restored on switch.
    var oauthAccount: Data

    init?(oauthAccount json: Data) {
        guard let info = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let accountUuid = info["accountUuid"] as? String else { return nil }
        let orgUuid = info["organizationUuid"] as? String ?? ""
        id = "\(accountUuid):\(orgUuid)"
        email = info["emailAddress"] as? String ?? "Unknown"
        displayName = info["displayName"] as? String ?? info["fullName"] as? String ?? email
        organizationName = info["organizationName"] as? String ?? ""
        oauthAccount = json
    }
}

/// Saved accounts. Profile metadata lives in Application Support; the OAuth
/// credentials for each account live in the Keychain under `ClaudeSwitcher`.
final class AccountStore {
    static let keychainService = "ClaudeSwitcher"

    private(set) var accounts: [Account] = []
    private(set) var activeID: String?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    enum Issue {
        /// Claude Code's config says `configured`, but the Keychain token belongs to
        /// another account. Usually an old session refreshed its token after a switch.
        case tokenMismatch(configured: Account, owner: Account?)
        /// The token changed but its owner couldn't be checked (offline or expired).
        /// Nothing was saved.
        case unverified(Account)
    }

    /// Set by `syncActive()` when the current login can't be trusted.
    private(set) var issue: Issue?

    /// Captures whatever Claude Code is currently logged in as. New accounts are
    /// added; known accounts get their stored tokens refreshed, since Claude Code
    /// rotates them while it runs. A token is only saved after Anthropic confirms
    /// which account it belongs to, so one account's token is never filed under another.
    func syncActive() {
        issue = nil
        guard let json = ClaudeConfig.readOAuthAccount(),
              let current = Account(oauthAccount: json),
              let credentials = ClaudeConfig.readCredentials() else {
            activeID = nil
            return
        }
        activeID = current.id

        // Already saved for this account, which means it was verified when saved.
        if Keychain.read(service: Self.keychainService, account: current.id) == credentials {
            upsert(current)
            return
        }

        switch OAuthProfile.owner(ofCredentials: credentials) {
        case .account(let ownerID) where ownerID == current.id:
            if store(credentials, for: current.id) { upsert(current) }
        case .account(let ownerID):
            // Keep the token for its real owner: it's that account's newest one,
            // and its previous refresh token stops working once it has been refreshed.
            let owner = accounts.first { $0.id == ownerID }
            if owner != nil { store(credentials, for: ownerID) }
            issue = .tokenMismatch(configured: current, owner: owner)
        case .unknown:
            issue = .unverified(current)
        }
    }

    @discardableResult
    private func store(_ credentials: String, for id: String) -> Bool {
        do {
            try Keychain.write(service: Self.keychainService, account: id, secret: credentials)
            return true
        } catch {
            NSLog("ClaudeSwitcher: failed to store credentials: \(error)")
            return false
        }
    }

    private func upsert(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            guard accounts[index] != account else { return }
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        save()
    }

    func switchTo(_ account: Account) throws {
        // Save the outgoing account's latest tokens before overwriting them.
        syncActive()
        guard let credentials = Keychain.read(service: Self.keychainService, account: account.id) else {
            throw ClaudeConfig.Error(message: "No saved credentials for \(account.email). Log in to it again with “Add Account…”.")
        }
        try ClaudeConfig.writeCredentials(credentials)
        try ClaudeConfig.writeOAuthAccount(account.oauthAccount)
        activeID = account.id
        issue = nil
    }

    func remove(_ account: Account) {
        Keychain.delete(service: Self.keychainService, account: account.id)
        accounts.removeAll { $0.id == account.id }
        save()
    }
}

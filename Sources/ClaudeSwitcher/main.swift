import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = AccountStore()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "key.2.on.ring", accessibilityDescription: "Claude Switcher")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Claude Code accounts"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        store.syncActive()
    }

    // Rebuild every time the menu opens so a login done in the terminal shows up right away.
    func menuNeedsUpdate(_ menu: NSMenu) {
        store.syncActive()
        menu.removeAllItems()

        let header = NSMenuItem(title: "Claude Code Accounts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        addIssueItems(to: menu)

        if store.accounts.isEmpty {
            let empty = NSMenuItem(title: "No accounts yet. Log in with Claude Code first.", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for (index, account) in store.accounts.enumerated() {
            let item = NSMenuItem(
                title: account.email,
                action: #selector(switchAccount(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : ""
            )
            item.target = self
            item.representedObject = account.id
            item.state = account.id == store.activeID ? .on : .off
            let subtitle = [account.displayName, account.organizationName]
                .filter { !$0.isEmpty && $0 != account.email }
                .joined(separator: " · ")
            if !subtitle.isEmpty {
                item.attributedTitle = attributedTitle(account.email, subtitle: subtitle)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let add = NSMenuItem(title: "Add Account…", action: #selector(addAccount), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)

        if !store.accounts.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for account in store.accounts {
                let item = NSMenuItem(title: account.email, action: #selector(removeAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.id
                item.isEnabled = account.id != store.activeID
                submenu.addItem(item)
            }
            removeItem.submenu = submenu
            menu.addItem(removeItem)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // A custom action instead of `terminate:`, which macOS 26 decorates with an
        // icon that pushes the rest of the section out of alignment.
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addIssueItems(to menu: NSMenu) {
        guard let issue = store.issue else { return }
        let warning: String
        switch issue {
        case .tokenMismatch(let configured, let owner):
            warning = "Claude Code is set to \(configured.email), but its login token belongs to \(owner?.email ?? "another account"). A session that was still running probably refreshed it. Close old sessions, then restore."
        case .unverified(let account):
            warning = "Couldn’t confirm the current login for \(account.email) (offline or expired?). It hasn’t been saved yet. Open the menu again to retry."
        }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: "⚠︎ " + wrapped(warning, width: 52),
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.systemOrange,
            ]
        )
        item.isEnabled = false
        menu.addItem(item)

        if case .tokenMismatch(let configured, _) = issue {
            let restore = NSMenuItem(title: "Restore \(configured.email)", action: #selector(restoreAccount(_:)), keyEquivalent: "")
            restore.target = self
            restore.representedObject = configured.id
            restore.isEnabled = store.accounts.contains { $0.id == configured.id }
            menu.addItem(restore)
        }
        menu.addItem(.separator())
    }

    /// Menu items don't wrap, so break long text into lines by hand.
    private func wrapped(_ text: String, width: Int) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + word.count + 1 > width {
                lines.append(line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    private func attributedTitle(_ title: String, subtitle: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(
            string: "\n" + subtitle,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return text
    }

    private func account(for item: NSMenuItem) -> Account? {
        guard let id = item.representedObject as? String else { return nil }
        return store.accounts.first { $0.id == id }
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let account = account(for: sender), account.id != store.activeID else { return }
        do {
            try store.switchTo(account)
            notify("Switched to \(account.email)", detail: "New Claude Code sessions use this account. Restart sessions that are already running.")
        } catch {
            showError(error)
        }
    }

    /// Writes the saved login back for the account Claude Code's config points at,
    /// replacing a token that belongs to someone else.
    @objc private func restoreAccount(_ sender: NSMenuItem) {
        guard let account = account(for: sender) else { return }
        do {
            try store.switchTo(account)
            notify("Restored \(account.email)", detail: "Restart Claude Code sessions that were using the wrong account.")
        } catch {
            showError(error)
        }
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let account = account(for: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.email)?"
        alert.informativeText = "This deletes the saved login from Claude Switcher. To use the account again, log in to it again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.remove(account)
        }
    }

    /// Saves the current login, then opens a terminal running `claude auth login`.
    /// The new account is picked up the next time the menu opens.
    @objc private func addAccount() {
        store.syncActive()
        let script = """
        #!/bin/zsh -l
        echo "Log in with the account you want to add."
        echo "When you're done, open the Claude Switcher menu and it will appear in the list."
        echo
        claude auth login
        echo
        echo "Done. You can close this window."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-switcher-login.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            showError(error)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(error)
        }
    }

    private func notify(_ title: String, detail: String) {
        // Show the switch briefly in the menu bar instead of asking for notification permission.
        statusItem.button?.title = " " + title
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.statusItem.button?.title = ""
            self?.statusItem.button?.toolTip = "Claude Code accounts"
        }
        statusItem.button?.toolTip = "\(title)\n\(detail)"
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Claude Switcher"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

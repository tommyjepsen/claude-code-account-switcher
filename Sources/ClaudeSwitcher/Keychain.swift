import Foundation

/// Thin wrapper around `/usr/bin/security`.
///
/// Claude Code itself reads and writes its credentials through the `security`
/// CLI, so the keychain item's ACL trusts that binary. Going through the same
/// tool avoids keychain password prompts and keeps the item usable by Claude Code.
enum Keychain {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func read(service: String, account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account { args += ["-a", account] }
        guard let result = try? run(args), result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    /// Returns the account name of the first item with this service, if any.
    static func account(service: String) -> String? {
        guard let result = try? run(["find-generic-password", "-s", service]), result.status == 0 else {
            return nil
        }
        // Line looks like:     "acct"<blob>="tommyjepsen"
        for line in result.stdout.split(separator: "\n") where line.contains("\"acct\"<blob>=") {
            guard let eq = line.range(of: "<blob>=") else { continue }
            let raw = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                return String(raw.dropFirst().dropLast())
            }
        }
        return nil
    }

    /// Creates or updates a generic password, then reads it back to confirm.
    ///
    /// The secret is hex-encoded and sent over stdin (`security -i`) so it stays out
    /// of the process argument list. Interactive mode caps a line at 4 KB, so very
    /// large secrets fall back to an argument; on macOS only the same user or root
    /// can read another process's arguments.
    static func write(service: String, account: String, secret: String) throws {
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X \(hex)\n"
        let result = command.utf8.count < 4000
            ? try run(["-i"], stdin: command)
            : try run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        guard read(service: service, account: account) == secret else {
            throw Error(message: "Keychain write to “\(service)” failed. \(result.stderr)")
        }
    }

    static func delete(service: String, account: String) {
        _ = try? run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    private static func run(_ args: [String], stdin: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }
        try process.run()
        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

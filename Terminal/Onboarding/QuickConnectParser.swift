import Foundation

/// Turns quick-connect strings into transient profiles.
/// Accepted forms:
///   ssh [-p port] [user@]host
///   [user@]host[:port]
///   ssh://[user@]host[:port]
enum QuickConnectParser {

    /// Parsed target plus an optional inline password (`user:pass@host`).
    struct Result {
        let profile: ServerProfile
        let password: String?
    }

    static func parse(_ input: String, profiles: [ServerProfile]) -> Result? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        var user: String?
        var password: String?
        var host = ""
        var port = 22

        if s.lowercased().hasPrefix("ssh://") {
            guard let components = URLComponents(string: s),
                  let parsedHost = components.host else { return nil }
            host = parsedHost
            // Drop IPv6 brackets — transports want the bare address.
            if host.hasPrefix("[") && host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            if let u = components.user, !u.isEmpty { user = u }
            if let p = components.port, (1...65535).contains(p) { port = p }
            if let pw = components.password, !pw.isEmpty {
                password = pw.removingPercentEncoding ?? pw
            }
        } else {
            var tokens = s.split(separator: " ").map(String.init)
            if tokens.first?.lowercased() == "ssh" { tokens.removeFirst() }

            var target: String?
            var i = 0
            while i < tokens.count {
                let token = tokens[i]
                if token == "-p" {
                    guard i + 1 < tokens.count,
                          let p = Int(tokens[i + 1]),
                          (1...65535).contains(p) else { return nil }
                    port = p
                    i += 2
                } else if token.hasPrefix("-p"),
                          token.count > 2,
                          let p = Int(token.dropFirst(2)),
                          (1...65535).contains(p) {
                    port = p
                    i += 1
                } else if token.hasPrefix("-") {
                    return nil // unknown flag — don't guess
                } else {
                    guard target == nil else { return nil }
                    target = token
                    i += 1
                }
            }

            guard let target else { return nil }
            guard let parts = splitTarget(target, port: port) else { return nil }
            user = parts.user
            host = parts.host
            port = parts.port
        }

        guard isValidHost(host) else { return nil }

        // "user:pass@host" — the first colon inside the userinfo splits
        // credentials; it never reaches this point inside the host.
        if let u = user, let colon = u.firstIndex(of: ":") {
            user = String(u[u.startIndex..<colon])
            let pw = String(u[u.index(after: colon)...])
            if !pw.isEmpty { password = pw }
        }

        var profile = ServerProfile()
        profile.host = host
        profile.port = port
        profile.username = (user?.isEmpty == false ? user : nil) ?? defaultUsername(profiles: profiles)
        return Result(profile: profile, password: password)
    }

    /// True when the input looks like an SSH target rather than a bare word.
    static func looksLikeSSH(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.contains("@") || t.hasPrefix("ssh")
    }

    // MARK: - Internals

    /// Splits `[user@]host[:port]`. A single colon must carry a numeric port;
    /// multiple colons are treated as part of the host (IPv6).
    private static func splitTarget(_ target: String, port: Int)
        -> (user: String?, host: String, port: Int)?
    {
        var u: String?
        var h = target
        var p = port

        if let at = h.lastIndex(of: "@") {
            let name = String(h[h.startIndex..<at])
            guard !name.isEmpty else { return nil }
            u = name
            h = String(h[h.index(after: at)...])
        }

        // Bracketed IPv6: "[::1]", "[::1]:2222" — the address lives
        // inside brackets; an optional :port follows the closing one.
        if h.hasPrefix("[") {
            guard let close = h.firstIndex(of: "]") else { return nil }
            let addr = String(h[h.index(after: h.startIndex)..<close])
            guard !addr.isEmpty else { return nil }
            let tail = h[h.index(after: close)...]
            if tail.isEmpty {
                h = addr
            } else if tail.hasPrefix(":"),
                      let parsed = Int(tail.dropFirst()),
                      (1...65535).contains(parsed) {
                h = addr
                p = parsed
            } else {
                return nil
            }
            return (u, h, p)
        }

        let colons = h.filter { $0 == ":" }.count
        if colons == 1, let colon = h.lastIndex(of: ":") {
            let tail = String(h[h.index(after: colon)...])
            guard let parsed = Int(tail), (1...65535).contains(parsed) else { return nil }
            p = parsed
            h = String(h[h.startIndex..<colon])
        }

        return (u, h, p)
    }

    private static func isValidHost(_ h: String) -> Bool {
        !h.isEmpty && h.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "[" || $0 == "]"
        }
    }

    /// Last used profile's username, else "root".
    private static func defaultUsername(profiles: [ServerProfile]) -> String {
        let candidate = profiles
            .max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }?
            .username ?? ""
        return candidate.isEmpty ? "root" : candidate
    }
}

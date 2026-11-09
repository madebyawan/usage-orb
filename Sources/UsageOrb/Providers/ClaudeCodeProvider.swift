import Foundation

/// Reads the Claude Code sign-in and asks Anthropic for the same usage figures Claude Code's `/usage` shows.
///
/// The endpoint is undocumented and may change. Usage Orb only reads the token; it never refreshes it,
/// so it can't interfere with Claude Code's own sign-in. An expired token means "open Claude Code".
struct ClaudeCodeProvider: UsageProvider {
    let id = ProviderID.claudeCode
    let method = "Reads Claude Code's sign-in from your Keychain (macOS asks first) and calls the undocumented usage endpoint that Claude Code's /usage uses."

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(now: Date) async throws -> ProviderSnapshot {
        let token = try Self.cachedAccessToken(now: now)
        do {
            return try await Self.fetch(token: token, now: now)
        } catch let error as ProviderError where error.kind == .auth {
            // Rejected. Only a renewed sign-in can hold a different token, so don't ask macOS for the same one.
            guard Self.tokenCache.hasChanged(stamp: Keychain.modificationDate(service: Self.keychainService)) else { throw error }
            Self.tokenCache.clear()
            let fresh = try Self.cachedAccessToken(now: now)
            guard fresh != token else { throw error }
            return try await Self.fetch(token: fresh, now: now)
        }
    }

    private static func fetch(token: String, now: Date) async throws -> ProviderSnapshot {
        let object = try await HTTP.getJSON(endpoint, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ], service: "Anthropic")
        return try parse(object, now: now)
    }

    // MARK: Credentials

    private static let keychainService = "Claude Code-credentials"
    static let expiredMessage = "Claude Code's sign-in has expired. Run Claude Code once to renew it, then refresh."

    /// Keeps the token in memory and reads the Keychain again only after Claude Code has rewritten the item,
    /// because macOS may ask on every read. A failed read stays failed until then.
    private static let tokenCache = TokenCache()

    private static func cachedAccessToken(now: Date) throws -> String {
        if let token = tokenCache.token(now: now) { return token }
        let stamp = Keychain.modificationDate(service: keychainService)
        if let failure = tokenCache.knownFailure(stamp: stamp) { throw failure }
        do {
            let (token, expiry) = try readAccessToken(now: now)
            tokenCache.store(token, expiry: expiry, stamp: stamp)
            return token
        } catch let error as ProviderError {
            tokenCache.store(failure: error, stamp: stamp)
            throw error
        }
    }

    static func readAccessToken(now: Date) throws -> (token: String, expiry: Date?) {
        let data = Keychain.readOtherApp(service: keychainService) ?? credentialsFile()
        guard let data else {
            throw ProviderError.notConfigured("No Claude Code sign-in found. Sign in with `claude`, then refresh.")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.notConfigured("Claude Code is signed in with an API key, not a subscription. There's no quota to show.")
        }
        let expiry = JSON.date(oauth["expiresAt"])
        if let expiry, expiry <= now {
            throw ProviderError.auth(expiredMessage)
        }
        return (token, expiry)
    }

    private static func credentialsFile() -> Data? {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return try? Data(contentsOf: directory.appendingPathComponent(".credentials.json"))
    }

    // MARK: Parsing

    static func parse(_ object: [String: Any], now: Date) throws -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(provider: .claudeCode, fetchedAt: now)

        func window(key: String, name: String, percent: Any?, resets: Any?) -> QuotaWindow? {
            guard let used = JSON.double(percent) else { return nil }
            return QuotaWindow(id: "claudeCode.\(key)", provider: .claudeCode, name: name, usedPercent: used,
                               resetsAt: JSON.date(resets), source: .undocumentedAPI, observedAt: now)
        }

        // Current format: a list of limits. Older responses only have the flat keys.
        if let limits = object["limits"] as? [[String: Any]], !limits.isEmpty {
            for limit in limits {
                guard let kind = limit["kind"] as? String else { continue }
                let scope = scopeName(limit["scope"])
                let key = scope.map { "\(kind).\($0.lowercased())" } ?? kind
                if let item = window(key: key, name: limitName(kind: kind, scope: scope),
                                     percent: limit["percent"], resets: limit["resets_at"]) {
                    snapshot.windows.append(item)
                }
            }
        } else {
            let flat = [("five_hour", "session", "Session"), ("seven_day", "weekly_all", "Weekly"),
                        ("seven_day_opus", "weekly_scoped.opus", "Weekly · Opus"),
                        ("seven_day_sonnet", "weekly_scoped.sonnet", "Weekly · Sonnet")]
            for (field, key, name) in flat {
                guard let entry = object[field] as? [String: Any] else { continue }
                if let item = window(key: key, name: name, percent: entry["utilization"], resets: entry["resets_at"]) {
                    snapshot.windows.append(item)
                }
            }
        }

        if let extra = object["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = JSON.double(extra["used_credits"]), let currency = extra["currency"] as? String {
            let places = JSON.double(extra["decimal_places"]) ?? 0
            snapshot.money.append(MoneyFigure(id: "claudeCode.extraUsage", provider: .claudeCode,
                                              name: "Extra usage this month", kind: .spend,
                                              amount: used / pow(10, places), currency: currency,
                                              source: .undocumentedAPI, observedAt: now))
        }

        guard !snapshot.windows.isEmpty || !snapshot.money.isEmpty else {
            throw ProviderError.format("Anthropic's usage response had no limits Usage Orb recognises.")
        }
        return snapshot
    }

    static func limitName(kind: String, scope: String?) -> String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Weekly"
        case "weekly_scoped": return "Weekly · \(scope ?? "one model")"
        default:
            let words = kind.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst() + (scope.map { ", \($0)" } ?? "")
        }
    }

    private static func scopeName(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string.capitalized }
        if let object = value as? [String: Any] {
            for key in ["display_name", "name", "model", "model_family"] {
                if let string = object[key] as? String, !string.isEmpty { return string.capitalized }
            }
        }
        return nil
    }
}

/// The Claude Code token held between refreshes, and the Keychain item's modification date (`stamp`)
/// from when it was read. A nil stamp means the date is unknown, so nothing can be ruled out.
/// Providers fetch concurrently, so access is locked.
final class TokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var expiry: Date?
    private var stamp: Date?
    private var failure: ProviderError?

    func token(now: Date) -> String? {
        lock.withLock {
            if let expiry, expiry <= now { token = nil }
            return token
        }
    }

    func store(_ token: String, expiry: Date?, stamp: Date?) {
        lock.withLock { (self.token, self.expiry, self.stamp, failure) = (token, expiry, stamp, nil) }
    }

    func store(failure: ProviderError, stamp: Date?) {
        lock.withLock { (token, expiry, self.stamp, self.failure) = (nil, nil, stamp, failure) }
    }

    func hasChanged(stamp: Date?) -> Bool {
        lock.withLock { stamp == nil || stamp != self.stamp }
    }

    /// Why reading the Keychain would be pointless: the item is the one that already failed or expired.
    func knownFailure(stamp: Date?) -> ProviderError? {
        lock.withLock {
            guard let stamp, stamp == self.stamp else { return nil }
            return failure ?? .auth(ClaudeCodeProvider.expiredMessage)
        }
    }

    func clear() {
        lock.withLock { (token, expiry, stamp, failure) = (nil, nil, nil, nil) }
    }
}

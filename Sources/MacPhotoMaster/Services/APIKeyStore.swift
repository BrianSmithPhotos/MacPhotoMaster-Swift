import Foundation
import Security

/// Resolves API keys (eBird, OpenRouter) from the process environment first, then falls back to
/// the macOS Keychain — replaces the environment-only rule CLAUDE.md used to document, which broke
/// for any GUI-launched process (Xcode's Run button, Finder, Dock all inherit `launchd`'s
/// environment, not a shell's `.zshrc` exports; see `docs/MLX_PROVIDER.md`-adjacent debugging from
/// 2026-07-08). Keychain was chosen over `UserDefaults` because a `UserDefaults`-backed secret is
/// a cleartext plist under `~/Library/Preferences` — not appropriate for API keys.
enum APIKeyStore {
    /// Matches this app's bundle identifier (`scripts/build-app-bundle.sh`'s `BUNDLE_ID`) so
    /// Keychain items are scoped to this app rather than shared/ambiguous across other tools.
    private static let service = "com.briansmithphotos.macphotomaster.apikeys"

    /// `envVar` wins when set (keeps `swift run`/terminal-launched debugging simple, matching the
    /// existing test suite's `setenv`/`unsetenv` pattern); otherwise falls back to whatever's saved
    /// in the Keychain under `account` via `SettingsView`.
    static func resolve(envVar: String, account: String) -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment[envVar], !fromEnv.isEmpty {
            return fromEnv
        }
        return read(account: account)
    }

    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Passing `nil` or an empty string deletes the stored item rather than saving a blank secret.
    @discardableResult
    static func save(_ value: String?, account: String) -> Bool {
        guard let value, !value.isEmpty else { return delete(account: account) }

        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: Data(value.utf8)]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = Data(value.utf8)
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

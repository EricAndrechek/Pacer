import Foundation

/// Who Claude Code's global config says is signed in, read without parsing
/// the rest of the file (#192).
///
/// The config is ~235 KB and Claude Code rewrites it wholesale every 5–15 s
/// while it runs, almost never because the login changed. The login watcher
/// has to look at every one of those rewrites, so the question it asks must
/// cost next to nothing: find the `oauthAccount` object, parse only that.
/// A JSON parse of the whole file on every rewrite is what #188 ruled the
/// watcher out on; this is the cheap filter that makes it affordable.
///
/// It is a *filter*, not the record. The attribution trail still parses the
/// file properly and still runs the stale-config veto; all this decides is
/// whether a rewrite is worth waking it for. A false "changed" costs one
/// login pass; a false "unchanged" leaves the switch to the next scan cycle,
/// which is where it was found before this existed.
public struct ConfigLoginIdentity: Sendable, Equatable {
    /// `oauthAccount.organizationUuid` — `Account.id`'s source.
    public let organizationId: String?
    /// `oauthAccount.accountUuid`, which tells two logins in one org apart.
    public let accountUuid: String?

    public init(organizationId: String?, accountUuid: String?) {
        self.organizationId = organizationId
        self.accountUuid = accountUuid
    }

    private static let key = Data("\"oauthAccount\"".utf8)

    /// The identity `oauthAccount` names, or nil when the config has none —
    /// logged out, mid-write, not JSON there, or an object with neither id.
    /// Never throws and never reads past the object it found.
    public static func extract(from data: Data) -> ConfigLoginIdentity? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ConfigLoginIdentity? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var searchFrom = data.startIndex
            while let hit = data.range(of: key, in: searchFrom..<data.endIndex) {
                searchFrom = hit.upperBound
                let start = hit.lowerBound - data.startIndex
                // Inside a string value the quotes are escaped, so a key that
                // only appears in someone's pasted prompt is `\"oauthAccount\"`.
                if start > 0, bytes[start - 1] == UInt8(ascii: "\\") { continue }
                guard let object = objectSpan(in: bytes, after: hit.upperBound - data.startIndex)
                else { continue }
                let slice = Data(bytes[object])
                guard let parsed = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                else { continue }
                let org = (parsed["organizationUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let account = (parsed["accountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard org != nil || account != nil else { return nil }
                return ConfigLoginIdentity(organizationId: org, accountUuid: account)
            }
            return nil
        }
    }

    /// The byte range of the `{…}` that follows `"key"` + `:`, honouring
    /// strings and escapes so a brace inside a value cannot end it early.
    /// nil when what follows is not an object (`null` after a logout).
    private static func objectSpan(in bytes: UnsafeBufferPointer<UInt8>, after index: Int) -> Range<Int>? {
        var i = index
        func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }
        skipSpace()
        guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
        i += 1
        skipSpace()
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }
        let open = i
        var depth = 0
        var inString = false
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if b == UInt8(ascii: "\\") { i += 2; continue }
                if b == UInt8(ascii: "\"") { inString = false }
            } else if b == UInt8(ascii: "\"") {
                inString = true
            } else if b == UInt8(ascii: "{") {
                depth += 1
            } else if b == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return open..<(i + 1) }
            }
            i += 1
        }
        return nil  // truncated mid-write
    }
}

/// When the keychain item Claude Code bills was last written, asked without
/// reading the secret (#192).
///
/// cswap switches by rewriting the `Claude Code-credentials` item, and so does
/// `/login`; neither has to touch the config first. The login keychain file is
/// written by every app that stores anything, though, so a write to it is only
/// worth a credential read when *this* item's modification date moved.
///
/// Asked through `/usr/bin/security find-generic-password` **without** `-w` or
/// `-g`: that prints the item's attributes and never fetches its data, so the
/// keychain's access control is never consulted and nothing can prompt —
/// `security dump-keychain` lists every item the same way. The same
/// Apple-signed tool the credential reader already uses (see `KeychainOAuth`
/// for why not `SecItem`), and the same two items it tries, in the same order.
public enum KeychainItemStamp {

    /// The item's modification stamp as `security` prints it
    /// (`"20261009120000Z"`), or nil when there is no such item or it could
    /// not be asked. Compared as an opaque string; never parsed into a date,
    /// because the only question is "did it move".
    public static func current(service: String = KeychainOAuth.serviceName) -> String? {
        // Never the machine's keychain from a test process, even read-only:
        // the same rule `OAuthClient.defaultParkedCredentials` follows.
        if PacerPreferences.isTestProcess { return nil }
        switch SecurityCLI.run(["find-generic-password", "-s", service, "-a", NSUserName()]) {
        case .success(let out):
            return modificationStamp(inSecurityOutput: String(decoding: out, as: UTF8.self))
        case .failure(.notFound):
            break
        case .failure:
            return nil
        }
        // The legacy no-account item, for an install that never wrote the
        // per-user one — the reader's fallback, mirrored.
        guard case .success(let out) = SecurityCLI.run(["find-generic-password", "-s", service])
        else { return nil }
        return modificationStamp(inSecurityOutput: String(decoding: out, as: UTF8.self))
    }

    /// `"mdat"<timedate>=0x3230…  "20261009120000Z\000"` → `20261009120000Z`.
    public static func modificationStamp(inSecurityOutput text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"mdat\"") {
            // The readable copy is the last quoted string on the line.
            guard let close = line.lastIndex(of: "\""),
                  let open = line[..<close].lastIndex(of: "\"")
            else { continue }
            var value = String(line[line.index(after: open)..<close])
            if let nul = value.range(of: "\\000") { value.removeSubrange(nul.lowerBound...) }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

import Foundation

/// Cheap, offline sanity-check of a pasted OAuth token — so an obviously
/// wrong paste (an API key, a session key, truncated text) is rejected
/// instantly with a helpful message, *before* we spend a network request
/// on it. What we can verify from the string alone is limited: the token
/// is opaque, so its **expiry, source, and scope are NOT encoded in it** —
/// those only come from the source (keychain blob) or the server's
/// response (a 200 confirms `user:profile` access; a 403 means it lacks
/// the scope). So this is a *format* gate, not a full validation.
///
/// The shape is derived from the tokens Pacer already reads: a Claude
/// `user:profile` access token is `sk-ant-oat01-` (OAuth Access Token,
/// version 01) followed by a base64url body.
public enum TokenFormat {
    /// Prefix of the interactive `user:profile` OAuth access token that
    /// `/api/oauth/usage` accepts.
    public static let oauthPrefix = "sk-ant-oat01-"

    public enum Verdict: Sendable, Equatable {
        case ok
        /// Fails the format gate; the string is a user-facing reason.
        case invalid(String)
    }

    /// base64url alphabet used by the token body.
    private static let bodyAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    public static func validate(_ raw: String) -> Verdict {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .invalid("Empty.") }

        // Recognizable wrong *kinds* of Anthropic key → specific guidance.
        if t.hasPrefix("sk-ant-api") {
            return .invalid("That's an API key (sk-ant-api…), not a Claude OAuth token — the usage endpoint needs the interactive user:profile access token.")
        }
        if t.hasPrefix("sk-ant-sid") {
            return .invalid("That's a session key (sk-ant-sid…), not the user:profile OAuth access token.")
        }
        guard t.hasPrefix(oauthPrefix) else {
            return .invalid("Doesn't look like a Claude OAuth token — it should start with “\(oauthPrefix)”.")
        }

        let body = t.dropFirst(oauthPrefix.count)
        if body.count < 40 {
            return .invalid("Token looks truncated — did the whole thing get copied?")
        }
        guard body.unicodeScalars.allSatisfy({ Self.bodyAllowed.contains($0) }) else {
            return .invalid("Token has unexpected characters — check for stray spaces or line breaks.")
        }
        return .ok
    }
}

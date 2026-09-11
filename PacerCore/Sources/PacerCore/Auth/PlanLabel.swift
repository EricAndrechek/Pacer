import Foundation

/// Turning what Anthropic reports about a plan into something a person — or an
/// agent sizing a fan-out — can act on.
///
/// Two fields describe a plan and only one of them is useful for pacing:
/// `subscriptionType` is the family (`free`, `pro`, `max`) and calls both Max
/// tiers `max`, while `rateLimitTier` (`default_claude_max_20x`) says how big
/// the budget actually is. 20% of a Max 20× budget is four times 20% of a Max
/// 5× one, so a percentage per hour means little without it.
///
/// Lives here rather than on either type because three surfaces need the same
/// answer — the HTTP API, the Settings accounts list, and the dashboard's
/// per-account pace group — and a plan rendered one way in Settings and another
/// on the dashboard is the kind of drift that starts with a copied helper.
public enum PlanLabel {

    /// A readable plan name, or nil when nothing was reported.
    ///
    /// **Parsed, not enumerated.** The observed tiers are
    /// `default_claude_<family>[_<multiplier>]`, so the multiplier is read off
    /// the end rather than matched against a list that goes stale the day a new
    /// tier ships. An unfamiliar shape renders as itself, which is still more
    /// informative than dropping it — the same rule Pacer applies to every
    /// other open vocabulary the server owns.
    public static func describe(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let tier = rateLimitTier?.trimmingCharacters(in: .whitespaces), !tier.isEmpty else {
            return subscriptionType.map { $0.capitalized }
        }
        var parts = tier.lowercased().split(separator: "_").map(String.init)
        if parts.first == "default" { parts.removeFirst() }
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return tier }
        guard let multiplier = parts.dropFirst().first(where: { $0.hasSuffix("x") }) else {
            return family.capitalized
        }
        return "\(family.capitalized) \(multiplier.dropLast())×"
    }
}

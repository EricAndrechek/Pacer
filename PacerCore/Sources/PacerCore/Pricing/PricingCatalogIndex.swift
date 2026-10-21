import Foundation

/// A pricing catalog's keys, indexed by `CanonicalModelID`, so a lookup is a
/// deterministic dictionary hit rather than a scan.
///
/// Built once per catalog (a few thousand keys) and shared by every lookup
/// against it. Resolution, in order:
///
/// 1. **Exact** on the parsed identity — model, provider and region.
/// 2. **The longest version-complete prefix** under the same provider and
///    region: `claude-opus-4-7-thinking` → `claude-opus-4-7`, but never
///    `claude-sonnet-5-5` → `claude-sonnet-5` (see
///    `CanonicalModelID.isVersionCompletePrefix(of:)`).
/// 3. For a Claude API id only: **the same model on another provider's global
///    endpoint** (Vertex, then Foundry, then Bedrock). Anthropic prices the
///    global endpoints of the partner clouds at the Claude API's rates, and a
///    catalog sometimes lists a new model under a partner key a few days
///    before the plain one. This is the same model, not a sibling.
/// 4. Otherwise nil, and the caller treats the model as unpriced.
///
/// When several catalog keys parse to one identity (`claude-haiku-4-5` and
/// `claude-haiku-4-5-20251001`), the winner is chosen by a total order on the
/// keys — undecorated first, then shortest, then lexicographic — so it can
/// never depend on `Dictionary` iteration order.
final class PricingCatalogIndex: @unchecked Sendable {

    private let keyByID: [CanonicalModelID: String]
    /// Per (provider, region), identities longest-model-first, for step 2.
    private let prefixCandidates: [ProviderRegion: [CanonicalModelID]]
    private let lock = NSLock()
    private var memo: [String: String?] = [:]

    private struct ProviderRegion: Hashable {
        let provider: CanonicalModelID.Provider
        let region: CanonicalModelID.Region
    }

    init<V>(_ table: [String: V]) {
        var best: [CanonicalModelID: String] = [:]
        for key in table.keys {
            let id = CanonicalModelID.parse(key)
            if let incumbent = best[id] {
                if Self.ranks(key, before: incumbent, id: id) { best[id] = key }
            } else {
                best[id] = key
            }
        }
        keyByID = best
        var candidates: [ProviderRegion: [CanonicalModelID]] = [:]
        for id in best.keys {
            candidates[ProviderRegion(provider: id.provider, region: id.region), default: []]
                .append(id)
        }
        for k in candidates.keys {
            candidates[k]!.sort {
                $0.model.count != $1.model.count ? $0.model.count > $1.model.count : $0.model < $1.model
            }
        }
        prefixCandidates = candidates
    }

    /// The catalog key `model` resolves to, or nil.
    func matchKey(_ model: String) -> String? {
        lock.lock()
        if let hit = memo[model] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let resolved = resolve(CanonicalModelID.parse(model))
        lock.lock()
        memo[model] = .some(resolved)
        lock.unlock()
        return resolved
    }

    /// The catalog key for an already-parsed identity, or nil.
    func matchKey(_ id: CanonicalModelID) -> String? { resolve(id) }

    private func resolve(_ id: CanonicalModelID) -> String? {
        if let exact = keyByID[id] { return exact }
        if let prefix = prefixCandidates[ProviderRegion(provider: id.provider, region: id.region)]?
            .first(where: { $0.isVersionCompletePrefix(of: id.model) }) {
            return keyByID[prefix]
        }
        guard id.provider == .anthropic, id.region == .global else { return nil }
        for provider in [CanonicalModelID.Provider.vertex, .foundry, .bedrock] {
            if let key = keyByID[CanonicalModelID(model: id.model, provider: provider, region: .global)] {
                return key
            }
        }
        return nil
    }

    /// Total order for keys that share an identity.
    private static func ranks(_ a: String, before b: String, id: CanonicalModelID) -> Bool {
        let aPlain = a.lowercased() == id.model, bPlain = b.lowercased() == id.model
        if aPlain != bPlain { return aPlain }
        if a.count != b.count { return a.count < b.count }
        return a < b
    }
}

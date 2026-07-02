import Foundation

/// Structured decomposition of a raw model id (`claude-opus-4-7`,
/// `anthropic/claude-3-5-sonnet-20241022`, `claude-sonnet-5[1m]`, …) into
/// the parts Pacer names, groups, and colors by: the model *family*
/// (Opus / Sonnet / Haiku / Fable / Mythos), its major/minor version, an
/// optional date pin, and the 1M-context variant flag.
///
/// Why this exists: a model id is the one identity in Pacer that is stable
/// and shared across every user — unlike a project path, which is personal.
/// That lets us hand-pick a semantic color per family + version and derive
/// a clean display name, both a *pure function of the id*: everyone's Opus
/// is the same indigo, and everyone sees "Opus 4.7" rather than
/// `claude-opus-4-7`. Everything the app shows about a model routes here.
///
/// The parser is deliberately tolerant. It accepts:
///   - modern order `claude-<family>-<major>[-<minor>]` (`claude-opus-4-8`)
///   - legacy order `claude-<major>[-<minor>]-<family>` (`claude-3-5-sonnet`)
///   - provider prefixes (`anthropic/`, `us.anthropic.`, `vertex_ai/`, …)
///   - date pins (`-20251001`) and region/rev suffixes (`-v1:0`, `@default`)
///   - the 1M-context marker `[1m]`
///   - **its own display form** (`"Opus 4.7"`) — so a color or grouping
///     keyed on the pretty label resolves the same as one keyed on the raw
///     id. Callers can pass whichever they have.
/// Anything it can't recognize leaves `family == nil`; callers fall back to
/// the deprefixed short name and the generated (hashed) color, so a brand-
/// new family never breaks — it just isn't hand-colored until we name it.
public struct PacerModelIdentity: Equatable, Sendable {

    /// The families Pacer hand-colors and groups by. `rawValue` is the
    /// lowercase token as it appears in an id.
    public enum Family: String, CaseIterable, Sendable {
        case haiku, sonnet, opus, fable, mythos

        /// Capitalized display form ("Opus").
        public var label: String {
            switch self {
            case .haiku:  return "Haiku"
            case .sonnet: return "Sonnet"
            case .opus:   return "Opus"
            case .fable:  return "Fable"
            case .mythos: return "Mythos"
            }
        }
    }

    /// The original id, untouched — always available for the monospace
    /// subtitle, "Copy model name", CSV export, and pricing lookups.
    public let raw: String
    /// The parsed family, or nil when the id is unrecognized.
    public let family: Family?
    public let major: Int?
    public let minor: Int?
    /// 8-digit `YYYYMMDD` snapshot pin when the id carries one, else nil.
    public let datePin: String?
    /// True for the extended-context variant marked `[1m]`.
    public let context1M: Bool

    public init(_ raw: String) {
        self.raw = raw

        // 1. Pull the 1M-context marker out before tokenizing (its brackets
        //    would otherwise just be dropped as separators, losing the flag).
        var working = raw.lowercased()
        let has1M = working.contains("[1m]") || working.contains("(1m)")
        working = working.replacingOccurrences(of: "[1m]", with: " ")
                         .replacingOccurrences(of: "(1m)", with: " ")
        self.context1M = has1M

        // 2. Tokenize on every non-alphanumeric, so provider prefixes,
        //    slashes, dots, `@`, `:`, and the "." in a display name like
        //    "Opus 4.7" all split cleanly into tokens.
        let tokens = working.split { !$0.isLetter && !$0.isNumber }.map(String.init)

        // 3. Locate the family token.
        let familyByToken: [String: Family] = Dictionary(
            uniqueKeysWithValues: Family.allCases.map { ($0.rawValue, $0) }
        )
        guard let familyIdx = tokens.firstIndex(where: { familyByToken[$0] != nil }) else {
            self.family = nil
            self.major = nil
            self.minor = nil
            self.datePin = nil
            return
        }
        self.family = familyByToken[tokens[familyIdx]]

        // 4. Date pin = the first 8-digit run anywhere in the id.
        self.datePin = tokens.first { $0.count == 8 && $0.allSatisfy(\.isNumber) }

        // 5. Version. Prefer the contiguous numeric run immediately AFTER the
        //    family token (modern order); else the contiguous run immediately
        //    BEFORE it (legacy `claude-3-5-sonnet`). Only digits *adjacent* to
        //    the family word count, so a provider region like `us-gov-east-1`
        //    never leaks into the version (its `1` is not adjacent to the
        //    family). An 8-digit token is a date and ends the run.
        func isVer(_ t: String) -> Bool { t.count != 8 && !t.isEmpty && t.allSatisfy(\.isNumber) }
        var run: [String] = []
        for t in tokens[(familyIdx + 1)...] {
            guard isVer(t) else { break }
            run.append(t)
            if run.count == 2 { break }
        }
        if run.isEmpty {
            var j = familyIdx - 1
            while j >= 0, isVer(tokens[j]) {
                run.insert(tokens[j], at: 0)
                j -= 1
                if run.count == 2 { break }
            }
        }
        if run.count >= 2 {
            self.major = Int(run[0])
            self.minor = Int(run[1])
        } else if let one = run.first {
            if one.count == 2,
               let first = one.first.flatMap({ Int(String($0)) }), first >= 3,
               let second = one.last.flatMap({ Int(String($0)) }) {
                // Compressed provider form like `opus-41` → major 4, minor 1
                // (a leading digit < 3 stays a real major, e.g. `10` → 10).
                self.major = first
                self.minor = second
            } else {
                self.major = Int(one)
                self.minor = nil
            }
        } else {
            self.major = nil
            self.minor = nil
        }
    }

    /// `"4.7"`, `"5"`, or nil when no version parsed.
    public var versionLabel: String? {
        guard let major else { return nil }
        if let minor { return "\(major).\(minor)" }
        return "\(major)"
    }

    /// Numeric rank for shading/sorting within a family (`major + minor/10`).
    /// A bare flagship (no minor, e.g. `sonnet-5`) ranks as the `.0`.
    public var versionRank: Double? {
        guard let major else { return nil }
        return Double(major) + Double(minor ?? 0) / 10.0
    }

    /// Canonical `(family, major, minor)` for color placement — a bare major
    /// counts as minor `0` (so `Opus 4` and `Opus 4.0` place identically),
    /// even though `displayName` still renders "Opus 4". nil unless both the
    /// family and a major version parsed.
    public var canonical: (family: Family, major: Int, minor: Int)? {
        guard let family, let major else { return nil }
        return (family, major, minor ?? 0)
    }

    /// Pretty, user-facing name — `"Opus 4.7"`, `"Sonnet 5"`, `"Haiku 4.5"`.
    /// Falls back to the deprefixed short id for anything unrecognized so a
    /// new model still reads cleanly. The raw id stays in `raw` for the
    /// subtitle and copy actions.
    public var displayName: String {
        guard let family else { return pacerShortModel(raw) }
        var name = family.label
        if let versionLabel { name += " " + versionLabel }
        if context1M { name += " 1M" }
        return name
    }
}

/// The pretty display name for a raw model id — `"Opus 4.7"`, `"Sonnet 5"`.
/// Thin wrapper over `PacerModelIdentity.displayName` for call sites that
/// just want the string. Idempotent: passing an already-pretty name returns
/// it unchanged.
public func pacerModelDisplayName(_ model: String) -> String {
    PacerModelIdentity(model).displayName
}

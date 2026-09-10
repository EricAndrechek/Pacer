import Foundation
import Testing
@testable import PacerCore

/// Coverage for the menu-bar chip CSV model: the `MenuBarChipItem` parse /
/// serialize round trip, including the scoped per-model window chips encoded as
/// `scoped_pct:<identity>`. These pins are what guarantee (a) an existing
/// install's fixed-only list is byte-for-byte unchanged, and (b) an OLDER
/// client silently skips a scoped chip it doesn't understand rather than
/// choking — the whole reason scoped chips ride in the same String CSV.
struct MenuBarChipsTests {

    // MARK: - Fixed-only back-compat

    @Test func fixedOnlyCSVRoundTripsUnchanged() {
        let csv = "icon,five_hour_pct,seven_day_pct,today_cost,today_tokens,active_model"
        let items = MenuBarChipItem.parseList(csv)
        #expect(items == [
            .fixed(.icon), .fixed(.fiveHourPct), .fixed(.sevenDayPct),
            .fixed(.todayCost), .fixed(.todayTokens), .fixed(.activeModel),
        ])
        // Byte-for-byte stable so an existing install's persisted value never
        // rewrites on save.
        #expect(MenuBarChipItem.serializeList(items) == csv)
    }

    @Test func defaultCSVUnchanged() {
        // The shipped default. Round-trips exactly.
        #expect(MenuBarChipItem.serializeList(MenuBarChipItem.parseList("icon,five_hour_pct"))
                == "icon,five_hour_pct")
    }

    // MARK: - Scoped chips

    @Test func scopedTokenParsesToScopedIdentity() {
        let item = MenuBarChipItem.parse(token: "scoped_pct:weekly_scoped|Fable|")
        #expect(item == .scoped(identity: "weekly_scoped|Fable|"))
        #expect(item?.scopedIdentity == "weekly_scoped|Fable|")
        // And serializes back to the exact same token.
        #expect(item?.serialized == "scoped_pct:weekly_scoped|Fable|")
    }

    @Test func mixedFixedAndScopedRoundTrips() {
        let csv = "icon,five_hour_pct,scoped_pct:weekly_scoped|Fable|"
        let items = MenuBarChipItem.parseList(csv)
        #expect(items == [
            .fixed(.icon), .fixed(.fiveHourPct), .scoped(identity: "weekly_scoped|Fable|"),
        ])
        #expect(MenuBarChipItem.serializeList(items) == csv)
    }

    @Test func scopedTokenWithEmptyIdentityIsSkipped() {
        // Nothing to render ⇒ drop it (never a blank chip).
        #expect(MenuBarChipItem.parse(token: "scoped_pct:") == nil)
        #expect(MenuBarChipItem.parseList("icon,scoped_pct:,five_hour_pct")
                == [.fixed(.icon), .fixed(.fiveHourPct)])
    }

    // MARK: - Unknown / empty tokens skipped

    @Test func unknownFixedTokenIsSkipped() {
        // A future build's chip id (or a dropped one) is skipped — the
        // forward/backward-compat contract.
        #expect(MenuBarChipItem.parse(token: "made_up_future_chip") == nil)
        #expect(MenuBarChipItem.parseList("icon,made_up_future_chip,seven_day_pct")
                == [.fixed(.icon), .fixed(.sevenDayPct)])
    }

    @Test func emptyAndWhitespaceTokensSkipped() {
        #expect(MenuBarChipItem.parse(token: "") == nil)
        #expect(MenuBarChipItem.parse(token: "   ") == nil)
        #expect(MenuBarChipItem.parseList("") == [])
        // Whitespace around real tokens is tolerated (trimmed).
        #expect(MenuBarChipItem.parseList(" icon , five_hour_pct ")
                == [.fixed(.icon), .fixed(.fiveHourPct)])
    }

    // MARK: - Order + dedupe

    @Test func orderIsPreserved() {
        // Deliberately non-default order.
        let items = MenuBarChipItem.parseList("seven_day_pct,scoped_pct:weekly_scoped|Fable|,icon")
        #expect(items == [
            .fixed(.sevenDayPct), .scoped(identity: "weekly_scoped|Fable|"), .fixed(.icon),
        ])
    }

    @Test func duplicatesCollapseKeepingFirst() {
        let items = MenuBarChipItem.parseList(
            "icon,five_hour_pct,icon,scoped_pct:weekly_scoped|Fable|,scoped_pct:weekly_scoped|Fable|")
        #expect(items == [
            .fixed(.icon), .fixed(.fiveHourPct), .scoped(identity: "weekly_scoped|Fable|"),
        ])
    }

    @Test func setSerializesDedupedPreservingOrder() {
        let items: [MenuBarChipItem] = [
            .fixed(.icon), .fixed(.icon),
            .scoped(identity: "weekly_scoped|Fable|"),
            .scoped(identity: "weekly_scoped|Fable|"),
        ]
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        #expect(MenuBarChipItem.serializeList(unique)
                == "icon,scoped_pct:weekly_scoped|Fable|")
    }

    // MARK: - Dormant display-name recovery

    @Test func scopedDisplayNameRecoversModel() {
        // A dormant chip has only the identity to show a name from.
        #expect(MenuBarChipItem.scopedDisplayName(fromIdentity: "weekly_scoped|Fable|") == "Fable")
        #expect(MenuBarChipItem.scopedDisplayName(fromIdentity: "session_scoped|Cowork|") == "Cowork")
    }

    @Test func scopedDisplayNameHandlesSurfaceAndFallback() {
        #expect(MenuBarChipItem.scopedDisplayName(fromIdentity: "weekly_scoped|Fable|api")
                == "Fable · api")
        #expect(MenuBarChipItem.scopedDisplayName(fromIdentity: "weekly_scoped||chat")
                == "chat")
        // No model/surface at all: fall back to the raw identity rather than "".
        #expect(MenuBarChipItem.scopedDisplayName(fromIdentity: "weekly_all||")
                == "weekly_all||")
    }

    // MARK: - Account-pinned chips

    /// The menu bar is the tightest surface in the app and there is no honest
    /// combined number across accounts, so a chip can name the account it
    /// means. Round-trip, including a scoped identity whose own pipes must not
    /// confuse the split.
    @Test("an account-pinned chip round-trips, pipes and all")
    func accountChipRoundTrips() {
        let fixed = MenuBarChipItem.account(
            accountId: "00000000-1111-2222-3333-444444444444", window: "five_hour")
        #expect(fixed.serialized
                == "account_pct:00000000-1111-2222-3333-444444444444|five_hour")
        #expect(MenuBarChipItem.parse(token: fixed.serialized) == fixed)
        #expect(fixed.pinnedAccountId == "00000000-1111-2222-3333-444444444444")

        // A scoped identity carries pipes of its own; only the first splits.
        let scoped = MenuBarChipItem.account(
            accountId: "acct-1", window: "weekly_scoped|Fable|")
        #expect(MenuBarChipItem.parse(token: scoped.serialized) == scoped)
    }

    /// Same forward-compat contract the scoped prefix has: a client that does
    /// not know this token skips it rather than choking, and malformed tokens
    /// are skipped rather than rendering a phantom chip.
    @Test("malformed account tokens are skipped, not rendered")
    func malformedAccountTokensSkipped() {
        for bad in ["account_pct:", "account_pct:|five_hour", "account_pct:acct-1|",
                    "account_pct:no-pipe-here"] {
            #expect(MenuBarChipItem.parse(token: bad) == nil, "\(bad)")
        }
        // And it survives a round trip through a full CSV beside other kinds.
        let csv = "icon,five_hour_pct,account_pct:acct-2|seven_day,scoped_pct:weekly_scoped|Fable|"
        let items = MenuBarChipItem.parseList(csv)
        #expect(items.count == 4)
        #expect(items[2] == .account(accountId: "acct-2", window: "seven_day"))
        #expect(MenuBarChipItem.serializeList(items) == csv)
    }
}

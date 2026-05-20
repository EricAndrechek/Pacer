import Foundation
import Testing
@testable import PacerUI

/// Pacer's cost / token formatters serve two distinct roles — compact
/// for summary surfaces (tiles, chart axes, menu bar, widgets) and
/// exact for tables / hover tooltips / CSV. The compact form has to
/// fit 5- and 6-digit values in narrow LazyVGrid columns without
/// wrapping, which means K/M/B suffixes at every threshold past
/// 1000. Lock the contract here so a future "just one more digit"
/// tweak doesn't quietly reintroduce the wrap.
///
/// All assertions are USD; the currency-code plumbing is exercised
/// separately so we can swap it later without touching the rest of
/// these.

// MARK: - pacerCost (compact)

@Test func costRendersSubDollarWithCents() {
    #expect(pacerCost(0) == "$0")
    #expect(pacerCost(0.004) == "$0")
    #expect(pacerCost(0.42) == "$0.42")
    #expect(pacerCost(0.99) == "$0.99")
}

@Test func costRendersSinglesWithTwoDecimals() {
    #expect(pacerCost(1.00) == "$1.00")
    #expect(pacerCost(4.23) == "$4.23")
    #expect(pacerCost(9.99) == "$9.99")
}

@Test func costRendersTensWithOneDecimal() {
    #expect(pacerCost(10) == "$10.0")
    #expect(pacerCost(42.5) == "$42.5")
    #expect(pacerCost(99.9) == "$99.9")
}

@Test func costRendersHundredsWithoutDecimals() {
    #expect(pacerCost(100) == "$100")
    #expect(pacerCost(340) == "$340")
    #expect(pacerCost(999) == "$999")
}

@Test func costRendersThousandsCompact() {
    #expect(pacerCost(1_000) == "$1.0k")
    #expect(pacerCost(1_234) == "$1.2k")
    #expect(pacerCost(4_700) == "$4.7k")
    #expect(pacerCost(9_999) == "$10.0k")  // rounds up at boundary
}

/// The critical case that broke the layout. Before this refactor,
/// `pacerCost(10770)` returned the full "$10770", which wrapped in a
/// 6-column hero grid. Lock the compact rendering here.
@Test func costRendersFiveDigitThousandsCompact() {
    #expect(pacerCost(10_000) == "$10.0k")
    #expect(pacerCost(10_770) == "$10.8k")
    #expect(pacerCost(42_500) == "$42.5k")
    #expect(pacerCost(99_900) == "$99.9k")
}

@Test func costRendersHundredsOfThousandsWithoutDecimals() {
    #expect(pacerCost(100_000) == "$100k")
    #expect(pacerCost(340_000) == "$340k")
    #expect(pacerCost(999_000) == "$999k")
}

@Test func costRendersMillions() {
    #expect(pacerCost(1_000_000) == "$1.0M")
    #expect(pacerCost(1_234_000) == "$1.2M")
    #expect(pacerCost(12_300_000) == "$12.3M")
    #expect(pacerCost(340_000_000) == "$340M")
}

@Test func costRendersBillions() {
    #expect(pacerCost(1_000_000_000) == "$1.0B")
    #expect(pacerCost(12_300_000_000) == "$12.3B")
    #expect(pacerCost(340_000_000_000) == "$340B")
    #expect(pacerCost(1_500_000_000_000) == "$1500B")  // past last bucket
}

@Test func costHandlesNegativeValues() {
    // Refunds / adjustments. Symbol stays leading; sign stays leading
    // the symbol so it reads like a system currency formatter.
    #expect(pacerCost(-4.23) == "-$4.23")
    #expect(pacerCost(-10_770) == "-$10.8k")
}

// MARK: - pacerCostExact

@Test func costExactGroupsAndShowsCents() {
    // Locale-grouped, two decimals, currency symbol. Used in tables
    // and hover tooltips where the precise number matters.
    let s = pacerCostExact(10_770.42)
    // We don't assert the exact locale separator here because CI
    // might run in a non-US locale, but every locale Foundation
    // supports renders these three substrings somewhere.
    #expect(s.contains("10") && s.contains("770") && s.contains("42"))
    #expect(s.contains("$"))
}

@Test func costExactHandlesSubDollar() {
    let s = pacerCostExact(0.42)
    #expect(s.contains("0") && s.contains("42"))
    #expect(s.contains("$"))
}

// MARK: - pacerTokens (compact)

@Test func tokensRenderSmallExactly() {
    #expect(pacerTokens(0) == "0")
    #expect(pacerTokens(42) == "42")
    #expect(pacerTokens(999) == "999")
}

@Test func tokensRenderThousands() {
    #expect(pacerTokens(1_000) == "1.0K")
    #expect(pacerTokens(1_234) == "1.2K")
    #expect(pacerTokens(12_300) == "12.3K")
    #expect(pacerTokens(99_900) == "99.9K")
}

@Test func tokensRenderHundredsOfThousands() {
    #expect(pacerTokens(100_000) == "100K")
    #expect(pacerTokens(340_000) == "340K")
}

@Test func tokensRenderMillions() {
    #expect(pacerTokens(1_210_000) == "1.2M")
    #expect(pacerTokens(43_870_000) == "43.9M")
}

@Test func tokensRenderBillions() {
    #expect(pacerTokens(1_000_000_000) == "1.0B")
    #expect(pacerTokens(15_140_000_000) == "15.1B")
}

// MARK: - pacerTokensExact

@Test func tokensExactGroups() {
    let s = pacerTokensExact(10_770)
    #expect(s.contains("10") && s.contains("770"))
}

// MARK: - Currency configuration

@Test func currencyDisplayDefaultsToUSD() {
    #expect(pacerDisplayCurrencyCode == "USD")
}

@Test func currencySymbolLookup() {
    #expect(pacerCurrencySymbol(for: "USD") == "$")
    #expect(pacerCurrencySymbol(for: "EUR") == "€")
    #expect(pacerCurrencySymbol(for: "GBP") == "£")
    // Unknown codes fall back to "$" so the UI never renders an
    // empty currency symbol.
    #expect(pacerCurrencySymbol(for: "XYZ") == "$")
}

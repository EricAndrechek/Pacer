import Foundation
import Testing
@testable import PacerCore

@Test func csvFieldPlainStringPassesThrough() {
    #expect(CSVField.escape("hello") == "hello")
    #expect(CSVField.escape("2026-04-30") == "2026-04-30")
    #expect(CSVField.escape("") == "")
}

@Test func csvFieldWrapsCommas() {
    #expect(CSVField.escape("a,b") == "\"a,b\"")
}

@Test func csvFieldWrapsNewlines() {
    #expect(CSVField.escape("line1\nline2") == "\"line1\nline2\"")
    #expect(CSVField.escape("line1\rline2") == "\"line1\rline2\"")
}

@Test func csvFieldDoublesInternalQuotes() {
    #expect(CSVField.escape("he said \"hi\"") == "\"he said \"\"hi\"\"\"")
}

@Test func csvFieldFormatUSDSixDecimals() {
    #expect(CSVField.formatUSD(0) == "0.000000")
    #expect(CSVField.formatUSD(1.234567) == "1.234567")
    // 7th decimal rounds away (Double can't represent 0.0000005 exactly,
    // and String(format:) follows printf semantics — slight precision
    // loss is fine; export is for spreadsheet inspection, not science).
    let str = CSVField.formatUSD(0.0000015)
    #expect(str == "0.000002" || str == "0.000001")
}

@Test func csvFieldRowJoinsAndTerminates() {
    let row = CSVField.row(["a", "b", "c"])
    #expect(row == "a,b,c\n")
}

@Test func csvFieldRowEscapeRoundtrip() {
    // Realistic case: a project path with a comma in it. Caller has to
    // escape before calling row(); the function is just join+newline.
    let escaped = CSVField.escape("/Users/eric/Code/foo,bar")
    let row = CSVField.row([escaped, "100", "1.234567"])
    #expect(row == "\"/Users/eric/Code/foo,bar\",100,1.234567\n")
}

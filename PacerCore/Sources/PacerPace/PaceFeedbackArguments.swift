import Foundation

/// How `pacer feedback` reads its arguments (#292).
///
/// Everything after the first word is the report's text, flags and all: it is
/// a record of what was run, and dashes in it are what was typed. Only the
/// leading words are flags. They are checked because `pacer feedback --help`
/// used to save "--help" as a report, and a typo'd flag the same, which once
/// reports are sent on their own becomes a filed issue per agent that explores
/// the command.
enum PaceFeedbackArguments: Equatable {
    case help
    case report(text: String, local: Bool)
    /// A leading `-flag` that is not one of ours.
    case unknownFlag(String)

    static let usage = """
    usage: pacer feedback [--local] [--] "TEXT"

      Report a wrong verdict or a missing flag. Saved to
      ~/.claude/pace/feedback.jsonl and, unless kept local, sent to Pacer's
      issue tracker (the text only, scrubbed of paths and names).

      --local     keep it on this machine (also PACER_FEEDBACK=local)
      -h, --help  print this and exit
      --          end of flags, so text may start with a dash:
                  pacer feedback -- "--cap 85 paused me"

    """

    static func parse(_ words: [String]) -> PaceFeedbackArguments {
        var rest = words[...]
        var local = false
        while let word = rest.first, word.hasPrefix("-"), word != "-" {
            rest.removeFirst()
            switch word {
            case "--": return .report(text: join(rest), local: local)
            case "-h", "--help": return .help
            case "--local": local = true
            default: return .unknownFlag(word)
            }
        }
        return .report(text: join(rest), local: local)
    }

    private static func join(_ words: ArraySlice<String>) -> String {
        words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

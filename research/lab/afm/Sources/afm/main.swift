import Foundation
import FoundationModels

@Generable struct Forecast {
    @Guide(description: "Predicted final usage percent at reset, 0 to 100")
    var finalPercent: Double
}
@Generable struct Pick {
    @Guide(description: "Index of the candidate to trust, starting at 0")
    var candidate: Int
}

let args = CommandLine.arguments
let model = SystemLanguageModel.default
switch model.availability {
case .available: FileHandle.standardError.write(Data("availability: available\n".utf8))
case .unavailable(let r):
    FileHandle.standardError.write(Data("availability: unavailable (\(r))\n".utf8)); exit(3)
}
if args.count < 3 { print("usage: afm <in.jsonl> <out.jsonl>"); exit(0) }
let lines = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n")
FileManager.default.createFile(atPath: args[2], contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
let sem = DispatchSemaphore(value: 0)
Task {
    for l in lines {
        guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
              let id = o["id"] as? String, let prompt = o["prompt"] as? String,
              let kind = o["kind"] as? String else { continue }
        let t0 = Date()
        var res: [String: Any] = ["id": id]
        do {
            let s = LanguageModelSession(instructions: "You forecast rate-limit usage. Answer only with the requested number.")
            let opts = GenerationOptions(temperature: 0)
            if kind == "forecast" {
                let r = try await s.respond(to: prompt, generating: Forecast.self, options: opts)
                res["value"] = r.content.finalPercent
            } else {
                let r = try await s.respond(to: prompt, generating: Pick.self, options: opts)
                res["value"] = r.content.candidate
            }
        } catch { res["error"] = "\(error)" }
        res["latency"] = Date().timeIntervalSince(t0)
        out.write(try! JSONSerialization.data(withJSONObject: res) + Data("\n".utf8))
    }
    sem.signal()
}
sem.wait()

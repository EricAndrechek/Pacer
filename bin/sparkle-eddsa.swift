// sparkle-eddsa.swift — check a Sparkle EdDSA (Ed25519) signature the way an
// installed Pacer does, with nothing but the OS (CryptoKit).
//
// Usage:
//   swift bin/sparkle-eddsa.swift verify <public-key-b64> <signature-b64> <file>
//   swift bin/sparkle-eddsa.swift keygen <private-key-file>   # THROWAWAY test keys only
//   swift bin/sparkle-eddsa.swift pubkey <private-key-file>
//
// `verify` exits 0 and prints OK when <signature> is a valid Ed25519 signature
// of the whole file under <public-key> (the app's SUPublicEDKey), else 1.
// Sparkle signs the raw bytes of the archive or delta, not a digest of it, so
// this is the same check its installer runs before it touches a delta.
//
// `keygen` writes a key file in the format `sign_update -f` reads (base64 of
// the 32-byte private seed) and prints its public key. It exists so local
// tests never need Sparkle's `generate_keys`, which only works through the
// login Keychain. The release key lives in the SPARKLE_ED_PRIVATE_KEY secret
// and nowhere else; never point anything here at it.
//
// sign_update also accepts the older 96-byte key format; `pubkey` reads only
// the 32-byte seed format that `keygen` writes.

import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func decodeBase64(_ text: String, what: String) -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed) else { fail("not base64: \(what)") }
    return data
}

func readSeed(_ path: String) -> Data {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let seed = decodeBase64(text, what: path)
    guard seed.count == 32 else { fail("\(path): expected a 32-byte seed, got \(seed.count) bytes") }
    return seed
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: sparkle-eddsa.swift verify|keygen|pubkey …") }

switch args[1] {
case "verify":
    guard args.count == 5 else { fail("usage: sparkle-eddsa.swift verify <public-key-b64> <signature-b64> <file>") }
    let keyData = decodeBase64(args[2], what: "public key")
    let signature = decodeBase64(args[3], what: "signature")
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
        fail("public key is not a 32-byte Ed25519 key")
    }
    guard let file = try? Data(contentsOf: URL(fileURLWithPath: args[4]), options: .alwaysMapped) else {
        fail("cannot read \(args[4])")
    }
    if key.isValidSignature(signature, for: file) {
        print("OK")
    } else {
        print("BAD")
        exit(1)
    }

case "keygen":
    guard args.count == 3 else { fail("usage: sparkle-eddsa.swift keygen <private-key-file>") }
    let path = args[2]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists; refusing to overwrite a key") }
    let key = Curve25519.Signing.PrivateKey()
    let created = FileManager.default.createFile(
        atPath: path,
        contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
        attributes: [.posixPermissions: 0o600]
    )
    guard created else { fail("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "pubkey":
    guard args.count == 3 else { fail("usage: sparkle-eddsa.swift pubkey <private-key-file>") }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: readSeed(args[2])) else {
        fail("not an Ed25519 seed")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())

default:
    fail("unknown command \(args[1]); expected verify, keygen or pubkey")
}

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: sparkle-public-key.swift <private-key-file>\n".utf8))
    exit(64)
}

let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let encodedKey = try String(contentsOf: keyURL, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)

guard let seed = Data(base64Encoded: encodedKey), seed.count == 32 else {
    FileHandle.standardError.write(
        Data("Sparkle private key must be a base64-encoded 32-byte Ed25519 seed.\n".utf8)
    )
    exit(65)
}

let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(privateKey.publicKey.rawRepresentation.base64EncodedString())

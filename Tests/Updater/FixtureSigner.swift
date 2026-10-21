import CryptoKit
import Foundation

// This key exists only in the temporary fixture; production keys stay in Keychain.
let keyFile = URL(fileURLWithPath: CommandLine.arguments[2])
switch CommandLine.arguments[1] {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: keyFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyFile))
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    print(try key.signature(for: archive).base64EncodedString())
default: fatalError("Unknown fixture signing command")
}

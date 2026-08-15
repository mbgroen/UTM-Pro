//
// Copyright © 2026 UTM Pro contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import CryptoKit
import Foundation

public enum SSHKeyImportError: Error, Sendable, Equatable {
    case notAnOpenSSHKey
    case malformed(String)
    /// The key is protected by a passphrase. We do not prompt for one.
    case encrypted
    /// Correctly formed, but of a type SSH in this app cannot use.
    case unsupportedKeyType(String)
}

extension SSHKeyImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnOpenSSHKey:
            return NSLocalizedString("This does not look like an OpenSSH private key.", comment: "SSHKeyImportError")
        case .malformed(let detail):
            return String(format: NSLocalizedString("The key file could not be read: %@", comment: "SSHKeyImportError"), detail)
        case .encrypted:
            return NSLocalizedString("The key is protected by a passphrase. Import an unencrypted key, or use a key generated here.", comment: "SSHKeyImportError")
        case .unsupportedKeyType(let type):
            return String(format: NSLocalizedString("'%@' keys are not supported. Use an Ed25519 or ECDSA key.", comment: "SSHKeyImportError"), type)
        }
    }
}

public extension SSHPrivateKey {
    /// Generates a fresh Ed25519 key.
    ///
    /// Ed25519 rather than RSA because the SSH implementation here does not
    /// implement RSA at all, and Ed25519 is the modern default besides.
    static func generateEd25519(comment: String = "UTM Pro") -> SSHPrivateKey {
        SSHPrivateKey(ed25519: Curve25519.Signing.PrivateKey(), comment: comment)
    }

    /// Parses an unencrypted OpenSSH private key.
    ///
    /// Only the `openssh-key-v1` container is understood — the format
    /// `ssh-keygen` has produced by default for years. Encrypted keys are
    /// rejected rather than prompting, and RSA is rejected because the
    /// transport cannot sign with it.
    init(openSSHPrivateKey pem: String) throws {
        let body = try Self.base64Body(of: pem)
        guard let blob = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
            throw SSHKeyImportError.malformed("body is not valid base64")
        }

        var reader = SSHWireReader(blob)

        let magic = "openssh-key-v1\0"
        guard let prefix = reader.readBytes(magic.utf8.count),
              String(decoding: prefix, as: UTF8.self) == magic else {
            throw SSHKeyImportError.notAnOpenSSHKey
        }

        guard let cipherName = reader.readString() else {
            throw SSHKeyImportError.malformed("missing cipher name")
        }
        guard cipherName == "none" else {
            throw SSHKeyImportError.encrypted
        }
        _ = reader.readString()          // kdfname
        _ = reader.readData()            // kdfoptions
        guard let keyCount = reader.readUInt32(), keyCount == 1 else {
            throw SSHKeyImportError.malformed("expected exactly one key")
        }
        _ = reader.readData()            // public key blob

        guard let privateSection = reader.readData() else {
            throw SSHKeyImportError.malformed("missing private section")
        }

        var privateReader = SSHWireReader(privateSection)
        guard let check1 = privateReader.readUInt32(),
              let check2 = privateReader.readUInt32() else {
            throw SSHKeyImportError.malformed("missing checksum")
        }
        // Mismatched check words is how OpenSSH detects a wrong passphrase; on
        // an unencrypted key it means the file is damaged.
        guard check1 == check2 else {
            throw SSHKeyImportError.malformed("checksum mismatch")
        }

        guard let keyType = privateReader.readString() else {
            throw SSHKeyImportError.malformed("missing key type")
        }

        switch keyType {
        case "ssh-ed25519":
            _ = privateReader.readData() // public key
            guard let secret = privateReader.readData(), secret.count >= 32 else {
                throw SSHKeyImportError.malformed("short Ed25519 private key")
            }
            // The field is seed(32) || public(32); CryptoKit wants the seed.
            let seed = secret.prefix(32)
            let comment = privateReader.readString() ?? ""
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                self.init(ed25519: key, comment: comment)
            } catch {
                throw SSHKeyImportError.malformed("invalid Ed25519 scalar")
            }

        case "ecdsa-sha2-nistp256":
            _ = privateReader.readString() // curve name
            _ = privateReader.readData()   // public point
            guard let scalar = privateReader.readData() else {
                throw SSHKeyImportError.malformed("short ECDSA private key")
            }
            let comment = privateReader.readString() ?? ""
            // mpint values carry a leading zero byte when the high bit is set.
            let trimmed = scalar.drop { $0 == 0 }
            let padded = Data(repeating: 0, count: max(0, 32 - trimmed.count)) + trimmed
            do {
                let key = try P256.Signing.PrivateKey(rawRepresentation: padded)
                self.init(p256: key, comment: comment)
            } catch {
                throw SSHKeyImportError.malformed("invalid P-256 scalar")
            }

        case "ssh-rsa":
            // Deliberately distinct from the generic unsupported case: this is
            // the one people actually hit, and the fix is specific.
            throw SSHKeyImportError.unsupportedKeyType("RSA")

        default:
            throw SSHKeyImportError.unsupportedKeyType(keyType)
        }
    }

    private static func base64Body(of pem: String) throws -> String {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard let start = pem.range(of: begin), let finish = pem.range(of: end) else {
            // An RSA key in the older PEM container is common enough to name.
            if pem.contains("BEGIN RSA PRIVATE KEY") {
                throw SSHKeyImportError.unsupportedKeyType("RSA")
            }
            throw SSHKeyImportError.notAnOpenSSHKey
        }
        return String(pem[start.upperBound..<finish.lowerBound])
    }
}

/// Reads the length-prefixed fields of the SSH wire format.
private struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// A `string` field: a big-endian length followed by that many bytes.
    mutating func readData() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }

    mutating func readString() -> String? {
        readData().map { String(decoding: $0, as: UTF8.self) }
    }
}

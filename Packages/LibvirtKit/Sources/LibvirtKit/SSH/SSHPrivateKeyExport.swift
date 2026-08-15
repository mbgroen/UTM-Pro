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

public extension SSHPrivateKey {
    /// Serialises an Ed25519 key in the unencrypted `openssh-key-v1` format.
    ///
    /// This is what gets written to the Keychain, so a key generated in the
    /// app reads back through the same parser as one the user pasted in —
    /// there is no second, private storage format to keep working.
    ///
    /// Returns nil for key types that cannot be exported, notably Secure
    /// Enclave keys: their private half cannot leave the enclave, which is the
    /// entire point of using one.
    var openSSHPrivateKey: String? {
        guard let seed = ed25519Seed else { return nil }
        let publicKeyBlob = Self.ed25519PublicKeyBlob(from: openSSHPublicKey)
        guard let publicKeyBlob else { return nil }

        let comment = openSSHPublicKey.split(separator: " ").dropFirst(2)
            .joined(separator: " ")

        var privateSection = SSHWireWriter()
        // The two check words match on an unencrypted key; OpenSSH uses them
        // to detect a wrong passphrase.
        let check = UInt32.random(in: .min ... .max)
        privateSection.writeUInt32(check)
        privateSection.writeUInt32(check)
        privateSection.writeString("ssh-ed25519")
        privateSection.writeData(publicKeyBlob)
        privateSection.writeData(seed + publicKeyBlob)
        privateSection.writeString(comment)
        // Padded to the cipher block size with an incrementing sequence.
        var padding: UInt8 = 1
        while privateSection.bytes.count % 8 != 0 {
            privateSection.writeByte(padding)
            padding += 1
        }

        var outer = SSHWireWriter()
        outer.writeRaw(Data("openssh-key-v1\0".utf8))
        outer.writeString("none")           // cipher
        outer.writeString("none")           // kdf
        outer.writeData(Data())             // kdf options
        outer.writeUInt32(1)                // key count
        var publicBlob = SSHWireWriter()
        publicBlob.writeString("ssh-ed25519")
        publicBlob.writeData(publicKeyBlob)
        outer.writeData(publicBlob.bytes)
        outer.writeData(privateSection.bytes)

        let base64 = outer.bytes.base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.count - offset))
            return String(base64[start..<end])
        }.joined(separator: "\n")

        // The trailing newline is required: OpenSSH rejects a key file whose
        // final armour line is not terminated.
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrapped)
        -----END OPENSSH PRIVATE KEY-----

        """
    }

    /// The form written to the Keychain.
    ///
    /// Traps rather than silently storing something unusable: every path that
    /// reaches here is a key we generated, and an unexportable key stored as
    /// an empty string would fail much later with a confusing message.
    var privateKeyStorageRepresentation: String {
        guard let exported = openSSHPrivateKey else {
            preconditionFailure("this key cannot be exported for storage")
        }
        return exported
    }

    /// Extracts the raw 32-byte public key from the authorized_keys line.
    private static func ed25519PublicKeyBlob(from openSSHPublicKey: String) -> Data? {
        let fields = openSSHPublicKey.split(separator: " ")
        guard fields.count >= 2, fields[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(fields[1])) else {
            return nil
        }
        // The blob is: string "ssh-ed25519", string key.
        var reader = SSHWireReaderLite(blob)
        guard let algorithm = reader.readData(),
              String(decoding: algorithm, as: UTF8.self) == "ssh-ed25519",
              let key = reader.readData(), key.count == 32 else {
            return nil
        }
        return key
    }
}

/// Writes the length-prefixed fields of the SSH wire format.
private struct SSHWireWriter {
    private(set) var bytes = Data()

    mutating func writeByte(_ byte: UInt8) {
        bytes.append(byte)
    }

    mutating func writeRaw(_ data: Data) {
        bytes.append(data)
    }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func writeData(_ data: Data) {
        writeUInt32(UInt32(data.count))
        bytes.append(data)
    }

    mutating func writeString(_ string: String) {
        writeData(Data(string.utf8))
    }
}

private struct SSHWireReaderLite {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readData() -> Data? {
        guard offset + 4 <= data.endIndex else { return nil }
        let length = data[offset..<(offset + 4)].reduce(Int(0)) { ($0 << 8) | Int($1) }
        offset += 4
        guard offset + length <= data.endIndex else { return nil }
        defer { offset += length }
        return data[offset..<(offset + length)]
    }
}

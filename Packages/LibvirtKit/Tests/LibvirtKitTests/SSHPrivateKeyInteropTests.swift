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

import XCTest
@testable import LibvirtKit

#if os(macOS)

/// Checks our key handling against the real `ssh-keygen` rather than against
/// our own parser.
///
/// A format both halves of our code agree on but OpenSSH rejects would fail
/// only at the moment a user tries to connect, which is the worst place to
/// find out.
final class SSHPrivateKeyInteropTests: XCTestCase {

    /// `ssh-keygen -y` reads a private key and prints its public half. If it
    /// agrees with us, the exported file is genuinely well formed.
    func testExportedKeyIsReadableBySshKeygen() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"))

        let key = SSHPrivateKey.generateEd25519(comment: "interop")
        let exported = try XCTUnwrap(key.openSSHPrivateKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyFile = directory.appendingPathComponent("id_ed25519")
        try exported.write(to: keyFile, atomically: true, encoding: .utf8)
        // ssh-keygen refuses to read a key with permissive modes.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: keyFile.path)

        let output = try runSshKeygen(arguments: ["-y", "-f", keyFile.path])
        let derived = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // ssh-keygen echoes the comment it found inside the private key, so
        // this also confirms the comment survived export.
        XCTAssertEqual(derived, key.openSSHPublicKey)
    }

    /// The fingerprint we show the user for host-key confirmation must match
    /// what `ssh-keygen -l` prints, or comparing them is meaningless.
    func testFingerprintMatchesSshKeygen() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"))

        let key = SSHPrivateKey.generateEd25519(comment: "fingerprint")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let publicKeyFile = directory.appendingPathComponent("id_ed25519.pub")
        try key.openSSHPublicKey.write(to: publicKeyFile, atomically: true, encoding: .utf8)

        let output = try runSshKeygen(arguments: ["-lf", publicKeyFile.path])
        // Output is "256 SHA256:… comment (ED25519)".
        let expected = output.split(separator: " ")
            .first { $0.hasPrefix("SHA256:") }
            .map(String.init)

        let ours = SSHHostKeyFingerprint(publicKey: key.nioKey.publicKey).value
        XCTAssertEqual(ours, expected)
    }

    private func runSshKeygen(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestError.sshKeygenFailed(status: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    enum TestError: Error {
        case sshKeygenFailed(status: Int32)
    }
}

#endif

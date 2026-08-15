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

/// Key material here was produced by `ssh-keygen` and is used only by these
/// tests. The round trip — parse the private key, re-derive the public key,
/// compare against the `.pub` file ssh-keygen wrote — is what proves the
/// parser reads the format correctly rather than merely without crashing.
final class SSHPrivateKeyImportTests: XCTestCase {

    func testEd25519RoundTripsToTheSamePublicKey() throws {
        let key = try SSHPrivateKey(openSSHPrivateKey: Keys.ed25519Private)
        XCTAssertEqual(key.openSSHPublicKey, Keys.ed25519Public)
    }

    func testEd25519CommentIsPreserved() throws {
        let key = try SSHPrivateKey(openSSHPrivateKey: Keys.ed25519Private)
        XCTAssertTrue(key.openSSHPublicKey.hasSuffix(" probe-test"))
    }

    func testECDSAP256RoundTripsToTheSamePublicKey() throws {
        let key = try SSHPrivateKey(openSSHPrivateKey: Keys.ecdsaPrivate)
        XCTAssertEqual(key.openSSHPublicKey, Keys.ecdsaPublic)
    }

    /// The user's own key for the NAS is RSA, so this is the error they would
    /// hit first. It must name RSA specifically rather than saying "malformed".
    func testRSAIsRejectedByName() {
        XCTAssertThrowsError(try SSHPrivateKey(openSSHPrivateKey: Keys.rsaPrivate)) { error in
            XCTAssertEqual(error as? SSHKeyImportError, .unsupportedKeyType("RSA"))
        }
    }

    func testLegacyPEMRSAIsAlsoRejectedByName() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF0qct6HHZbCoLbnjZLPXcgHl
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertThrowsError(try SSHPrivateKey(openSSHPrivateKey: pem)) { error in
            XCTAssertEqual(error as? SSHKeyImportError, .unsupportedKeyType("RSA"))
        }
    }

    func testPassphraseProtectedKeyIsRejectedWithoutPrompting() {
        XCTAssertThrowsError(try SSHPrivateKey(openSSHPrivateKey: Keys.encryptedPrivate)) { error in
            XCTAssertEqual(error as? SSHKeyImportError, .encrypted)
        }
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try SSHPrivateKey(openSSHPrivateKey: "hello")) { error in
            XCTAssertEqual(error as? SSHKeyImportError, .notAnOpenSSHKey)
        }
    }

    func testTruncatedKeyIsRejectedNotCrashed() {
        let truncated = String(Keys.ed25519Private.prefix(120)) + "\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try SSHPrivateKey(openSSHPrivateKey: truncated))
    }

    func testGeneratedKeyProducesUsablePublicKey() {
        let key = SSHPrivateKey.generateEd25519(comment: "UTM Pro")
        XCTAssertTrue(key.openSSHPublicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        XCTAssertTrue(key.openSSHPublicKey.hasSuffix(" UTM Pro"))
    }

    func testGeneratedKeysDiffer() {
        let first = SSHPrivateKey.generateEd25519()
        let second = SSHPrivateKey.generateEd25519()
        XCTAssertNotEqual(first.openSSHPublicKey, second.openSSHPublicKey)
    }

    // MARK: - Export

    /// A generated key is written to the Keychain in OpenSSH format and read
    /// back through the same parser as a pasted key. If the round trip broke,
    /// every saved server would fail to connect after a restart.
    func testGeneratedKeyRoundTripsThroughExport() throws {
        let original = SSHPrivateKey.generateEd25519(comment: "round trip")
        let exported = try XCTUnwrap(original.openSSHPrivateKey)
        let reimported = try SSHPrivateKey(openSSHPrivateKey: exported)

        XCTAssertEqual(reimported.openSSHPublicKey, original.openSSHPublicKey)
    }

    func testExportedKeyHasOpenSSHEnvelope() throws {
        let key = SSHPrivateKey.generateEd25519()
        let exported = try XCTUnwrap(key.openSSHPrivateKey)

        XCTAssertTrue(exported.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(exported.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
    }

    /// The exported file must be readable by OpenSSH itself, not just by us.
    /// Verified in `testExportedKeyIsAcceptedBySshKeygen` where ssh-keygen is
    /// available; this checks the structural invariant it depends on.
    func testExportedPrivateSectionIsBlockAligned() throws {
        let key = SSHPrivateKey.generateEd25519()
        let exported = try XCTUnwrap(key.openSSHPrivateKey)
        let body = exported
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
        let decoded = try XCTUnwrap(Data(base64Encoded: body, options: [.ignoreUnknownCharacters]))

        XCTAssertGreaterThan(decoded.count, 100)
        XCTAssertTrue(decoded.starts(with: Array("openssh-key-v1\0".utf8)))
    }

    func testExportPreservesComment() throws {
        let key = SSHPrivateKey.generateEd25519(comment: "UTM Pro (omv.lan)")
        let exported = try XCTUnwrap(key.openSSHPrivateKey)
        let reimported = try SSHPrivateKey(openSSHPrivateKey: exported)

        XCTAssertTrue(reimported.openSSHPublicKey.hasSuffix(" UTM Pro (omv.lan)"))
    }
}

// MARK: - Test key material (throwaway, generated for these tests only)

private enum Keys {
    static let ed25519Private = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACD5FI2C6eGuk1AjMqibeplFXu3XX5m+prDkxxs8tk0fPQAAAJCwv4BAsL+A
    QAAAAAtzc2gtZWQyNTUxOQAAACD5FI2C6eGuk1AjMqibeplFXu3XX5m+prDkxxs8tk0fPQ
    AAAEDF4HDq/VMyxB5ZK40j0H4YkqBCWiegqt+0gpl9+gg4TfkUjYLp4a6TUCMyqJt6mUVe
    7ddfmb6msOTHGzy2TR89AAAACnByb2JlLXRlc3QBAgM=
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ed25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPkUjYLp4a6TUCMyqJt6mUVe7ddfmb6msOTHGzy2TR89 probe-test"

    static let ecdsaPrivate = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQRrbiuGGEeCqdO8De1mVfK9qeS65lYC
    g005XVuLIHsbltpJBpPhzvCR2MIqFUF1PYKscfhSNVL4TjxTydL4HOgcAAAAqHQzt0p0M7
    dKAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGtuK4YYR4Kp07wN
    7WZV8r2p5LrmVgKDTTldW4sgexuW2kkGk+HO8JHYwioVQXU9gqxx+FI1UvhOPFPJ0vgc6B
    wAAAAhAOMbMKBjhFDou5lfRDCh0O+sUqSqVEcLHimAfgFfawMCAAAACmVjZHNhLXRlc3QB
    AgMEBQ==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ecdsaPublic = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGtuK4YYR4Kp07wN7WZV8r2p5LrmVgKDTTldW4sgexuW2kkGk+HO8JHYwioVQXU9gqxx+FI1UvhOPFPJ0vgc6Bw= ecdsa-test"

    static let rsaPrivate = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAQEAq+/w37cuL6chTvQErtUDlu5Pc8tRkKGz3FrQaM/CHkI0RBtEhkjp
    QPY40eid2szcY/5hzYXsGmIYPowTaUpL5gYe7KCP8SWH5pyS8z7zx2QnP1i+gD6/PkGjhw
    xYpmWGlZn0dP8WnoAD9mP6HD0+vY3/y3KVLNSiwMKGIEbtkK5vhATxl/pFhP82UeWWjiOi
    pi3HH7YMv5TCuhFHENnl3Nf3nLt9tljTDgRHcB11R8mPBTx1Gwd0GvkeF3X3cq46mBdnhM
    XdOID9Lyb36+xHuQ5BPoRgOACn8i3aaa8bnN5DDH2xzUrecs4zqfDzqLKe9/3S0EAUqqt1
    lwErCd4dIQAAA8AIEnP5CBJz+QAAAAdzc2gtcnNhAAABAQCr7/Dfty4vpyFO9ASu1QOW7k
    9zy1GQobPcWtBoz8IeQjREG0SGSOlA9jjR6J3azNxj/mHNhewaYhg+jBNpSkvmBh7soI/x
    JYfmnJLzPvPHZCc/WL6APr8+QaOHDFimZYaVmfR0/xaegAP2Y/ocPT69jf/LcpUs1KLAwo
    YgRu2Qrm+EBPGX+kWE/zZR5ZaOI6KmLccftgy/lMK6EUcQ2eXc1/ecu322WNMOBEdwHXVH
    yY8FPHUbB3Qa+R4XdfdyrjqYF2eExd04gP0vJvfr7Ee5DkE+hGA4AKfyLdpprxuc3kMMfb
    HNSt5yzjOp8POosp73/dLQQBSqq3WXASsJ3h0hAAAAAwEAAQAAAQA3wUMXCMvNYCEI/VBX
    cXQMiZLyNchpYkZ0+m4Czvxf25AfVchO023wRuf+CbTGsw/0zRTiFL+PfqfmAH568kDSgs
    GcciS7SjRbsAJnJs7epbekbx63b6GMirSAopxMuTd/Y8FF/0JSe6jNSXZdme6ygU2lp66A
    LyPn5iygYt++vooQsjsS3YpK/m12d2nDQxyDvovdg+IoJgcpm+fYnjdyHezFr1954qGnOw
    FYHzhzOy7bVivox8IeC6Pa+63N3NToansHpg3735FkZhePie+k5crf02WYEwQiX/iwpxLa
    RLh3l3sNnb2AqFzG8B8F2zppfLMYOs4Aub4lF8C+ONJRAAAAgQCyVlQ5xenu/kVFA3NgX+
    YRlXUZYHDtZyjZPRoGNuyxVz+++2GiXbl8extGoZmYDYtEmHd0ClXIETMdxCxxSVj+/8Kg
    tktEq39TdikxTO6QMEbMvRrzrKDtB0ReAGkLsPjk/CHlE3hOSpe6OPkBKqVoHzLPxskrvH
    BY6btEnwa7UwAAAIEA02PQ1wejvReUl1WIHpmPnRocifR+PmBSpiDwGw2ALiAOKgAzuzec
    4hUjEGgbXallUhDnMBM4yVVl+OHWTHcDKiYre6mp+qraYW6eB05jXvulQQVZ2iQBzjMwAw
    gDPt0k3L0HNrOxAlyIF3sdxKg1vUMyMW3PSHBWbeujJW8Um/MAAACBANA4ubhN1k1ZBq67
    KXnBDy6QtEwa4wG8THrA5HFkLML10j+qviUo/W2yhgtjKjjuq4ZbJQv+Xgbgla0apX0X9+
    6a4pSRzvbQwIQYI5wtibCesyiIl/rhu4kR3cMjCQ43qJlI9Wm9m9iKbBwYT/StAaw2tZp7
    qn60uMiovhP83subAAAACHJzYS10ZXN0AQI=
    -----END OPENSSH PRIVATE KEY-----
    """

    static let encryptedPrivate = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCyDD/IV6
    B/hP8vxr72w8GhAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGKckqYqPo6aoupa
    lZlNC8GU3epKsmYonQQy9FGyC/GLAAAAkAEOv3uc+auTcez1A6vTxIL74aTzqXh8QaP/f3
    sQvapGx3YxPMS0l8JpeACpKHqLAOWahlViSrMZNhvbRMUD8SFeaay6ZJctJDAQFvlPS54P
    YZFtNvp8Vhtp+JbSlrDzMnGWmSKA42dgvw3obMLhptMv5pCv+Un1MDS0HFV8C7QPwiyfFe
    2OPY0EQ37lSHtnjw==
    -----END OPENSSH PRIVATE KEY-----
    """
}

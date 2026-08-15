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

import Foundation
import LibvirtKit

// A read-only probe: it connects, enumerates and prints. Nothing here starts,
// stops, defines or deletes anything, so it is safe to point at a production
// host.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: libvirtprobe <user>@<host> [port]

    Authentication comes from the environment:
      LIBVIRT_SSH_PASSWORD   password authentication
      LIBVIRT_SSH_KEY_FILE   path to an unencrypted Ed25519 OpenSSH key

    Host key:
      LIBVIRT_SSH_FINGERPRINT  pin this SHA256 fingerprint. When unset the
                               probe trusts on first use and prints what it saw.

    """.utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }

let target = arguments[1]
let parts = target.split(separator: "@", maxSplits: 1)
guard parts.count == 2 else { usage() }
let username = String(parts[0])
let host = String(parts[1])
let port = arguments.count >= 3 ? Int(arguments[2]) ?? 22 : 22

let environment = ProcessInfo.processInfo.environment

let credential: SSHCredential
if let password = environment["LIBVIRT_SSH_PASSWORD"] {
    credential = .password(password)
} else if let keyPath = environment["LIBVIRT_SSH_KEY_FILE"] {
    do {
        let contents = try String(contentsOfFile: keyPath, encoding: .utf8)
        credential = .privateKey(try SSHPrivateKey(openSSHPrivateKey: contents))
    } catch {
        FileHandle.standardError.write(Data("could not read key: \(error)\n".utf8))
        exit(1)
    }
} else {
    usage()
}

let policy: SSHHostKeyPolicy
if let fingerprint = environment["LIBVIRT_SSH_FINGERPRINT"] {
    policy = .pinned(SSHHostKeyFingerprint(value: fingerprint))
} else {
    policy = .trustOnFirstUse
}

func format(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

let destination = SSHDestination(host: host,
                                 port: port,
                                 username: username,
                                 credential: credential,
                                 hostKeyPolicy: policy)
let connection = SSHConnection(destination: destination)

do {
    print("connecting to \(username)@\(host):\(port) …")
    try await connection.connect()
    if let fingerprint = await connection.presentedHostKey {
        print("host key: \(fingerprint)")
    }

    let libvirt = LibvirtHost(connection: connection)
    try await libvirt.checkAvailability()

    let info = try await libvirt.hostInfo()
    print("host: \(info.hostname ?? "?")  cpus: \(info.cpuCount.map(String.init) ?? "?")  "
          + "memory: \(info.memoryBytes.map(format) ?? "?")")
    print("libvirt: \(info.libvirtVersion ?? "?")")

    print("\n── domains ──")
    let domains = try await libvirt.listDomains()
    for domain in domains {
        let console = domain.preferredGraphics.map { graphics -> String in
            let port = graphics.port.map(String.init) ?? "—"
            let exposure = graphics.isListeningOnAllInterfaces && !graphics.hasPassword
                ? " [open on all interfaces, no password]"
                : ""
            return "\(graphics.kind.rawValue):\(port)\(exposure)"
        } ?? "no console"
        print("  \(domain.name)  \(domain.state.rawValue)  "
              + "\(domain.vcpuCount) vcpu  \(format(domain.memoryBytes))  \(console)")
        for disk in domain.disks {
            print("      disk \(disk.target) \(disk.format ?? "?") "
                  + "\(disk.supportsInternalSnapshots ? "snapshottable" : "no internal snapshots")")
        }
    }

    print("\n── snapshots ──")
    for domain in domains {
        let snapshots = try await libvirt.snapshots(ofDomain: domain.name)
        guard !snapshots.isEmpty else { continue }
        print("  \(domain.name):")
        for snapshot in snapshots {
            let date = snapshot.creationDate.map {
                DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
            } ?? "—"
            print("      \(snapshot.name)  \(date)  \(snapshot.state ?? "?")"
                  + (snapshot.isCurrent ? "  (current)" : ""))
        }
    }

    print("\n── pools ──")
    let pools = try await libvirt.listPools()
    for pool in pools {
        print("  \(pool.name)  \(pool.isActive ? "active" : "inactive")  "
              + "\(format(pool.allocationBytes)) / \(format(pool.capacityBytes))  "
              + "\(pool.targetPath ?? "")")
        let volumes = try await libvirt.listVolumes(inPool: pool.name)
        for volume in volumes {
            print("      \(volume.name)  \(volume.format ?? "?")  "
                  + "\(format(volume.allocationBytes)) / \(format(volume.capacityBytes))")
        }
    }

    // Opt-in only, and only against the objects named here.
    if let target = environment["LIBVIRT_WRITE_TEST_DOMAIN"],
       let pool = environment["LIBVIRT_WRITE_TEST_POOL"] {
        try await WriteTest.run(libvirt: libvirt, domain: target, pool: pool)
    }

    // Checks the SSH tunnel the console depends on, without opening a console.
    if let target = environment["LIBVIRT_TUNNEL_TEST_DOMAIN"] {
        try await TunnelTest.run(connection: connection, libvirt: libvirt, domain: target)
    }

    await connection.disconnect()
    print("\nok")
} catch {
    FileHandle.standardError.write(Data("failed: \(error.localizedDescription)\n".utf8))
    await connection.disconnect()
    exit(1)
}

# Remote KVM management (UTM Pro)

Extends UTM to manage libvirt/KVM hosts alongside local VMs — specifically an
OpenMediaVault 8 NAS running the `openmediavault-kvm` plugin. Adds snapshot
management for both local and remote VMs, and storage pool and volume
management on remote hosts.

Target platforms: macOS and iOS/iPadOS. The feature is gated behind the
`WITH_REMOTE_KVM` compilation condition, set for the `iOS`, `iOS-SE` and
`macOS` targets. `iOS-Remote` is excluded: it has no local VM backend.

## Why not the existing remote support

UTM already ships a remote mode, but it is a *whole-app* mode, not a per-VM
one. The `iOS-Remote` target compiles out the local QEMU backend (`#if
!WITH_REMOTE` in `Platform/VMData.swift`) and `UTMRemoteData` *replaces* the VM
list rather than adding to it. It also speaks UTM's own protocol to another
copy of UTM — not libvirt.

Coexistence is therefore the core structural change, and it is deliberately
additive: `UTMData.virtualMachines` keeps its existing local-only meaning so
every existing call site — delete, clone, export, move — is untouched. Remote
hosts live in a parallel registry (`UTMLibvirtServerRegistry`) and render as
their own sidebar sections.

## Transport: SSH to libvirt

Management runs over SSH to the host, driving `virsh -c qemu:///system` and
`qemu-img`. This gives the full libvirt surface rather than the subset the OMV
plugin's RPC API exposes, and needs nothing installed on the server.

One SSH connection per host serves two purposes:

- **exec channels** for `virsh` / `qemu-img`
- **direct-tcpip channels** to tunnel the console port

Two things about this are easy to get wrong and worth knowing:

`ClientBootstrap.connect` resolves once TCP is up, several round trips before
user authentication finishes. Commands issued in that window fail with an
opaque channel error, so `connect()` waits for the authentication event before
reporting success.

Every value interpolated into a `virsh` command line is shell-quoted through
`ShellCommand`, which has no interface for appending raw text. Domain, pool and
volume names come from users and from the remote host, and libvirt accepts
names containing quotes and semicolons.

### Authentication

Ed25519 and ECDSA keys, or a password. **RSA is not supported** — the
underlying `swift-nio-ssh` implements Ed25519 and ECDSA only, and that is
surfaced by name at import time rather than as a failed connection later.

Host keys are pinned on first connect. A later mismatch is a hard failure that
requires explicit re-trust, never a prompt to ignore.

Credentials live in the Keychain, keyed by server id, accessible only when the
device is unlocked and never synced.

### Console

Consoles are tunnelled through the SSH connection by default, and UTM connects
to a local forwarded port. This matters: libvirt hosts commonly expose SPICE
and VNC on `0.0.0.0` with no password, so anyone who can reach the host can
open a console.

CocoaSpice has always supported plaintext SPICE; only `UTMSpiceIO` lacked an
initializer for it, because local VMs use a Unix socket and remote UTM servers
use TLS with a pinned key. That initializer is the only change needed to reuse
UTM's entire renderer, input, audio and USB-redirection stack.

libvirt assigns the console port when a domain *starts* — a stopped domain
reports `autoport='yes'` with `port='-1'`. Lifecycle operations therefore
re-read the whole domain, not just its state, or the console has no address to
connect to.

## Layers

| Layer | Location | Contents |
|---|---|---|
| SSH | `Packages/LibvirtKit/Sources/LibvirtKit/SSH/` | `SSHConnection`: auth, host-key pinning, exec, local port forwarding, OpenSSH key import/export |
| libvirt | `Packages/LibvirtKit/Sources/LibvirtKit/Libvirt/` | `LibvirtHost`: domains, lifecycle, snapshots, pools, volumes, networks. `LibvirtDomainTemplate` builds XML for new domains |
| Backend | `Services/Libvirt/` | `UTMLibvirtVirtualMachine`, the domain→configuration projection, server object, credential store |
| Model | `Platform/` | `UTMLibvirtServerRegistry` |
| UI | `Platform/Shared/VMLibvirt*.swift`, `VMSnapshotsView.swift` | Sidebar sections, server setup, storage, disk add, VM creation, snapshots |

### Why remote VMs carry a QEMU configuration

`UTMSpiceVirtualMachine` fixes `Configuration == UTMQemuConfiguration`, and
UTM's display *and* settings views are built on it. A bespoke libvirt
configuration was more honest about the domain but locked remote VMs out of
every existing view — no console, nothing behind Edit.

Each domain is therefore projected into a `UTMQemuConfiguration` for the views,
with everything libvirt-specific that model cannot express kept beside it in
`UTMLibvirtDomainInfo`. The projection is a **read model**: saving reconciles
the changed fields back through libvirt rather than writing the configuration
anywhere.

The display controllers reach the VM through `spiceVM`, typed as the protocol,
for everything the protocol covers. `qemuVM` remains for what genuinely needs a
local QEMU process — monitor, guest agent, host file access, USB auto-connect,
secondary windows — and is optional, so those degrade rather than trap.

### Window semantics

Closing a local VM's window deals with that VM's state, because the window owns
the process. A remote domain outlives the app entirely, so its console closes
without saving, without warning, and without touching the VM. Wiring the local
path to a remote domain would have made closing a window run `virsh destroy`.

## Snapshots

Listing is read from the disk image, not the QEMU monitor, which can save,
restore and delete but cannot enumerate. Reading the image also works while the
VM is stopped. It needs `--force-share`, because a running VM holds a write
lock.

- **Local, running:** QMP `savevm`/`loadvm`/`delvm`
- **Local, stopped:** `qemu-img snapshot -c/-a/-d`. Previously deleting a
  snapshot with the VM off silently did nothing
- **Remote:** `virsh snapshot-list/-create-as/-revert/-delete`

Whether a snapshot captured memory decides what restoring does — resume
mid-execution, or boot from that point — so it is shown on the row rather than
in a dialog.

The precheck only looks for a snapshot-capable disk. The host can still refuse
for reasons the disk format does not reveal: libvirt rejects an internal
snapshot of a UEFI guest whose nvram is not qcow2, for instance. Those errors
are surfaced as libvirt reports them.

## Storage

Pools: list with capacity, define, build, start, stop, autostart, rescan,
undefine. Volumes: create, resize, clone, delete.

Virtual and actual size are shown separately, because a sparse qcow2 reserves
far more than it occupies and collapsing the two makes a pool look full when it
is mostly empty.

Deleting a volume requires typing its name, and names any VM currently using
the image — libvirt will not stop you deleting a disk out from under a running
guest. Shrinking requires acknowledging that the guest filesystem was shrunk
first, because libvirt discards whatever lies past the new end without
checking.

## Creating VMs

The generated XML mirrors what the OMV KVM plugin produces — q35,
host-passthrough CPU, virtio disk, network and video, SPICE with an agent
channel — so a VM created here looks native in that web interface.

One deliberate difference: the console listens on the host's loopback rather
than `0.0.0.0`, since UTM Pro reaches it through the SSH tunnel.

Network options are ranked. A NAS accumulates a bridge per Docker network,
named `br-<hex>`, and those sort ahead of the real bridge alphabetically —
attaching a VM to one produces a guest that boots perfectly and has no
connectivity. Container bridges are recognised, labelled and ranked last.

## Verification

`LibvirtKit` has no dependency on the app and can be tested on its own:

```sh
cd Packages/LibvirtKit
swift test
```

Parsers are tested against XML from a real OpenMediaVault 8 host, and key
handling is checked against `ssh-keygen` rather than only against the matching
parser — that interop test is what caught an exported key missing its trailing
newline, which OpenSSH rejects outright.

`libvirtprobe` exercises a real host. It is read-only by default:

```sh
LIBVIRT_SSH_KEY_FILE=~/.ssh/id_ed25519 swift run libvirtprobe root@my-nas.lan
```

Opt-in checks, each scoped to objects named on the command line:

| Variable | What it does |
|---|---|
| `LIBVIRT_WRITE_TEST_DOMAIN` + `LIBVIRT_WRITE_TEST_POOL` | Snapshot, volume, autostart, hardware and disk-attach round trips, restoring every value afterwards |
| `LIBVIRT_CREATE_TEST_POOL` | Defines a VM from the template, checks what libvirt kept, removes it |
| `LIBVIRT_TUNNEL_TEST_DOMAIN` | Verifies the console tunnel carries data |

The tunnel check tests against the host's own sshd first, because sshd greets
a client on connect and so isolates the forwarder from any service's protocol.
That mattered: an earlier version spoke a hand-rolled SPICE handshake, got no
reply, and looked exactly like a broken tunnel.

## Build prerequisites

UTM cannot build without a prebuilt sysroot, staged at the repo root from the
upstream CI artifact `Sysroot-macos-arm64` (see `AGENTS.md`). Xcode 26 also
needs the Metal toolchain component:

    xcodebuild -downloadComponent MetalToolchain

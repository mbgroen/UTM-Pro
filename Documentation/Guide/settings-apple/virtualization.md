# Virtualization

**macOS**

## Balloon Device
The balloon device allows the guest operating system (with supported drivers) to more intelligently request RAM from the host. This is highly recommended.

## Entropy Device
The entropy device is used by supported guest operating systems for cryptographic tasks.

## **macOS 12+** Sound
Sound support for macOS or **macOS 13+** Linux booting from UEFI.

## **macOS 12+** Keyboard
Keyboard support for macOS or **macOS 13+** Linux booting from UEFI.

## **macOS 12+** Pointer
Pointer support for macOS or **macOS 13+** Linux booting from UEFI.

## **macOS 13+** Trackpad

Emulates a trackpad for macOS guests. Requires Ventura or higher guest. This allows support for trackpad gestures.

## **macOS 13+** Rosetta
See [Rosetta](../advanced/rosetta.md) for more details.

## **macOS 13+** Clipboard Sharing
On Linux guests booting from UEFI, install `spice-vdagent` to enable clipboard sharing.

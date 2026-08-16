# Kali Linux 2022

## Downloads

* [Kali Installer](https://www.kali.org/get-kali/#kali-installer-images)

## Installation

Follow the VM creation wizard and select the ISO that you downloaded. If you are using virtualization, make sure to download the correct ISO for your architecture. If you are using emulation, make sure to select the correct architecture in the wizard.

To set up clipboard and directory sharing, check out [this page](../guest-support/linux.md).

## Troubleshooting

### Black screen on start

There is an issue with the graphics drivers in the live CD. You need to install Kali Linux in a terminal window.

Open the [VM settings](../basics/basics.md) and [create a new serial device](../settings-qemu/devices/devices.md).

Once you complete the installation, you can remove the serial device.

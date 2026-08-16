# Input

## USB
The USB bus hosts emulated devices such as the USB keyboard, mouse, and tablet for input emulation and any drives that are set to the USB interface. USB 3.0 is recommended for the highest performance but some older guest operating systems do not support it and therefore USB 2.0 should be selected. If USB is disabled, make sure ["Force PS/2 controller"](qemu.md#force-ps2-controller) is selected for input device support.

## USB Sharing
You can enable USB sharing and specify the maximum number of shared devices. This creates the right number of emulated USB buses and a higher number could affect performance on older guest operating systems.

**iOS** This option is not supported on most installations. See [the install guide](https://github.com/mbgroen/UTM-Pro#installation) for more details.

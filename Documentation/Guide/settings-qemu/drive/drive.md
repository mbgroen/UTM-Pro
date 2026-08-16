# Drive

## Creation

**macOS**

To add a new drive, click "New..." on the sidebar under "Drives".

**iOS**

To add a new drive, tap the "+" button on the top left in the main settings menu and select "Import Drive" or "New Drive".

### Importing

**iOS** When importing a drive, a removable drive will be created and the selected image will be associated with the new drive.

**macOS** When importing a drive that is non-removable and not a raw image, the selected image will first be converted to the QCOW2 format.

## Deletion

**macOS**

To delete a drive, right/secondary click the drive on the left toolbar and select "Delete".

**iOS**

To delete a drive, swipe left on the drive and tap "Delete".

> [!WARNING]
> When you delete a non-removable drive, the data will be deleted as well. If the drive is removable, no data is deleted.

## Boot Order
The boot order of devices are in the order they appear on the list.

**macOS**

To change the drive order, either right/secondary click the drive on the left toolbar and select "Move Up"/"Move Down" or drag and drop the drive in the desired order.

**iOS**

To change the drive order, tap "Edit" on the top right and you can drag and drop the drive entries.

## Removable Drive
Non-removable drives are stored in the .utm package. Removable drives only store a bookmark to the drive image and should be used for ISOs and other disk images.

## Interface
This is the hardware interface to connect this drive to. Typical users do not need to change from the default interface.

## Image Type
* **None** This drive is not used at all.
* **Disk Image** The drive will be mounted in the bus specified in "interface" with a non-removable media type.
* **CD/DVD (ISO) Image** The drive will be mounted in the bus specified in "interface" with a removable media type.
* **Deprecated** **BIOS** "Interface" is ignored and no drive is emulated. The image will be passed to QEMU through the `-bios` argument.
* **Deprecated** **Linux Kernel** "Interface" is ignored and no drive is emulated. The image will be passed to QEMU through the `-kernel` argument.
* **Deprecated** **Linux RAM Disk** "Interface" is ignored and no drive is emulated. The image will be passed to QEMU through the `-initrd` argument.
* **Deprecated** **Linux Device Tree Binary** "Interface" is ignored and no drive is emulated. The image will be passed to QEMU through the `-dtb` argument.

## Size
When creating a new image, this is the size of the new image. You can toggle between "MB" (mebibyte) or "GB" (gibibyte).

### Raw Image
If selected, a raw empty image will be created inside the .utm package. If the host file system containing the .utm is APFS, then a sparse file will be created (zeros will not take space).

If not selected, a QCOW2 disk image will be created inside the .utm package. The QCOW2 format will grow as the disk image grows.

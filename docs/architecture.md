# How Henge works

A virtual Mac without a hypervisor: arm64 guest code runs through an arm64-to-arm64
JIT instead of hardware virtualization, so the same engine can run on iOS, where
apps have no hypervisor access. The engine is built and tested on the Mac
(`build/hengevm`) and linked into the iPhone app (`make ios-lib`).

The guest's terminal power requests and iOS session cleanup are described in
[Guest shutdown](guest-shutdown.md). Debian guests run on a second board, described
under [Linux guests](#linux-guests).

## Layout

- `core/`: guest CPU state, the block translator, the software MMU, and exceptions.
- `devices/`: the virtual Mac's devices (interrupt controller, timers, UART, RTC,
  config region, AES, PCIe with virtio block, network, input, sound and USB, and
  the virtual GPU), and the Linux board's (`virt.c`, `virt_fdt.c`, `fdt.c`, the
  PL011, PL031 and PL061, and the virtio GPU, entropy and balloon devices).
- `host/`: what runs around the engine (memory, JIT region, disk files, the
  install and USB shims, the Linux kernel loader, and the Mac's command-line tool).
- `ios/`: the iPhone app. See [ios/README.md](../ios/README.md).
- `tests/`: instruction-level and block-level tests that run on the Mac.
- `third_party/`: the restore stack, from upstream sources. See
  [licensing.md](licensing.md).

## How the translator works

The guest and host are both arm64, so most guest instructions are copied into a
translated block unchanged. Only these are rewritten:

- loads and stores, which go through the guest MMU (an inline TLB, with a slow
  path for misses and device accesses);
- PC-relative instructions and branches, which get the guest PC filled in;
  same-page branches chain directly to the target block, including conditional
  ones, and cross-page branches check that the page still maps the same code.
  Indirect branches go through a small cache and fall back to the dispatcher,
  and returns go through a per-CPU return table;
- system register access, exceptions, and barriers that touch guest state, which
  call helpers;
- pointer-authentication instructions, which become a strip or a no-op, since the
  host's keys cannot be the guest's;
- any instruction that uses a register the translator reserves for itself; those
  registers are kept in the guest context instead. Guest x6, x7, x15, x18 and
  x28 are kept in the CPU context, so the host's x6, x7 and x15 are free scratch.

Each block has a hot part and a cold part, so the paths rarely taken don't sit
between the ones that are.

Guest and host both use 16 KB pages, so guest RAM maps onto host pages directly.

## Device model

The machine follows the memory map and devices of QEMU's open-source `vmapple`
machine (hw/vmapple in QEMU, GPL-2.0-or-later). That code is the reference for
device behaviour, and `devices/aes.c` takes its command and register layout from
it. Nothing here comes from Virtualization.framework.

## Graphics

macOS draws through Apple's paravirtual GPU. iOS has no ParavirtualizedGraphics
framework, so `devices/pvg_lite.c` takes the guest's command streams and
`devices/pvg_metal.m` replays them with Metal.

## The trackpad

The device's screen is the Mac's trackpad. It is presented to the guest as a
Magic Trackpad 2 on the xHCI USB bus (`devices/xhci.c`): Apple's vendor-defined
multitouch format, report ID 2 with a 12-byte prefix and nine bytes a finger,
in the pad's 8134 x 5206 sensor units. Because the guest's own multitouch
engine sees a real Apple pad, it does the pointing, the scrolling and the
gestures itself — the app sends only finger positions. Clicking is the volume
buttons' job on iPhone (`VolumeClicks.swift`): up left, down right, hold to drag.
The format follows the Linux kernel's
`hid-magicmouse` MT2 support and VoodooInput's Magic Trackpad II emulation.

## The boot ROM

The first code a virtual Mac runs is Apple's AVPBooter, which starts macOS or, for an
install, waits in DFU mode. It lives in macOS's system image, and since macOS 15 those are
encrypted, but the one in Apple's macOS 14.6.1 restore image is not, and its ROM runs later
versions. `ios/Henge/BootROM.swift` fetches it from Apple: the file is part of one
compressed block of that image, so one request of under a megabyte gets all of it. It then
checks the result against a SHA-256 hash. Nothing is decrypted.

## Sharing

`host/share.c` is a small WebDAV server, because macOS has a WebDAV client built in. The
guest reaches it at 10.0.2.4, which the user-mode network hands to a Unix socket in the
app's storage: no TCP port is open, so other apps on the device can't reach it. Under
`/.henge/` it also has the clipboard and what it takes to install `tools/henge-agent.m`, a
small helper that runs inside macOS as a LaunchAgent, mounts the folder at `~/Henge` and
follows the clipboard. The app types the set up command but never presses Return: it can't
see what has the keyboard on the Mac.

## Installing macOS (no Mac needed)

`hengevm --install IPSW` (and the iOS app's Install macOS) install macOS on a
blank machine the way Virtualization.framework's installer does: the boot ROM
starts in DFU mode (cfg `run_installer`) and shows up as a USB device, and a
standard restore runs over that link. Apple's signing server personalizes the
boot chain for the machine's ECID, as for any Mac; nothing is decrypted or
patched on the host (encrypted images go to the guest as they are, and the
restore OS asks for its keys itself; the host only fetches the URL it names).

- The USB port: Apple's virtio USB device controller, PCI 0x106b:0x1a01 for the
  kernel (`AppleVirtIOUSBDeviceController`), and channel 0x100000 of the boot
  ROM's bdif MMIO transport for AVPBooter and iBoot (devices/virtio_usb.c,
  devices/bdif.c). Requests (host to guest) carry {u32 len, u8 endpoint, u8 type}
  and the data; responses {u8 type, u8 endpoint} and the data.
- The host side: libirecovery, usbmuxd and idevicerestore (third_party, upstream
  sources; the boot-ROM exploit is left out) linked against host/libusb_shim.c,
  a libusb whose one device is that port. usbmuxd sends 16 KB transfers (each
  request is one read on the device side), and ASR sends wait for a slow disk.
- iOS: tools/build_ios_restore.sh builds the same stack (with libplist,
  libimobiledevice, libtatsu, libzip, mbedtls for compiling only) and
  host/curl_shim.m puts libcurl's easy API on NSURLSession.

## Linux guests

Debian runs on a second board, `virt`, which copies QEMU's machine of that name. U-Boot's
`qemu_arm64` build has that layout compiled in, so a stock U-Boot starts on it with no
patch. The CPU core is the one macOS uses. `hengevm --board virt` selects the board, and
the iOS app starts it for a machine of kind `linux`. The tools that build the firmware
and the images are in [tools/linux](../tools/linux/README.md).

### The virt board

`devices/virt.h` has the addresses. They match a device tree that QEMU 11.1.3 dumped with
`-M virt,gic-version=3,highmem=off`.

| Region | Address | Device |
| --- | --- | --- |
| Flash 0 | `0x00000000`, 64 MB | `u-boot.bin`, read-only RAM |
| Flash 1 | `0x04000000`, 64 MB | U-Boot's environment, read-only RAM of `0xff` |
| GICv3 | `0x08000000` and `0x080a0000` | `devices/gicv3.c` |
| UART, RTC, GPIO | `0x09000000`, `0x09010000`, `0x09030000` | PL011, PL031, PL061 (power key on pin 3) |
| PCIe | memory `0x10000000`, ECAM `0x3f000000` | `devices/pcie.c`, INTx on SPIs 3 to 6 |
| RAM | `0x40000000` | guest RAM |

The board leaves out QEMU's `fw_cfg`, the virtio-mmio transports, the ITS and the PMU. Its
PCI devices are created in a fixed order, so each keeps its slot: bridge 0, disk 1, network
2, entropy 3, xHCI 4 (a USB keyboard and a Magic Trackpad 2), virtio keyboard 5, virtio
mouse 6, GPU 7, sound 8. The memory balloon is added only when `HV_BALLOON` is set. Every
device uses INTx, because Henge's virtio has no MSI-X. Slot *s* uses line *s* mod 4, as in
QEMU, so that the device tree's `interrupt-map` is true (`hv_pci_set_intx`).

Flash has no device behind it. Both regions are read-only RAM: a write is dropped, and
U-Boot reads an erased environment, reports a bad checksum and uses its defaults. That is
the wanted result, because U-Boot then boots from `extlinux.conf`.

The vmapple-only devices are not created: the config region, the boot ROM transport, the
AES device, Apple's paravirtual GPU and the virtio USB device port.

### What Linux sees of the CPU

- Identification registers come from the board (`HvMachine.id`). The virt board reports
  E0PD, and the page walker honours `TCR_EL1.E0PD0` and `E0PD1`. Without E0PD, Debian's
  kernel turns on page-table isolation when KASLR is on, and every exception from EL0 then
  writes TTBR1 and empties the TLB and the branch caches. With E0PD it leaves isolation off
  and keeps KASLR. The macOS board still reads 0.
- Linux keeps the ASID in `TTBR1_EL1` (`TCR_EL1.A1`). The per-process TLB stash keys on that
  ASID, so a context switch does not flush the TLB.
- PSCI 1.0 over `HVC` starts the other CPUs and ends the machine: `SYSTEM_OFF` exits
  `hengevm` with status 0, and `SYSTEM_RESET` builds the machine again in the same process.
- A Debian 16 KB kernel runs with 47-bit virtual addresses and three table levels. Henge
  does not offer LPA2, so the kernel falls back from its 52-bit configuration.
- The debug registers read as zero and ignore writes, so a guest debugger cannot
  single-step. `BRK` works. There are no performance counters, and the guest has only EL0
  and EL1, so KVM cannot run in it.

### The device tree

`devices/virt_fdt.c` writes a flattened tree with the writer in `devices/fdt.c`. It has the
nodes QEMU's tree has, with the same values: `psci` (`hvc`), memory, one `cpu` node per CPU,
the timer, the GICv3, a 24 MHz `apb-pclk`, the PL011, PL031 and PL061, a `gpio-keys` power
key, the PCIe host with its `interrupt-map`, `aliases` and `chosen` (`stdout-path`,
`rng-seed`, `kaslr-seed`). It has no `msi-map`, ITS, flash, `fw-cfg`, virtio-mmio or PMU
node. `make test-linux-dtb` compares the tree with QEMU's node by node.

Through U-Boot, the tree sits at the start of RAM, where U-Boot reads it and then adds the
boot arguments. On a direct kernel boot (`--kernel`), `host/linux_boot.c` loads the kernel
and the initrd, writes the tree near the top of RAM and starts CPU 0 at the kernel. Direct
boot is for tests and bring-up. The app always boots through U-Boot.

### Boot

1. The host maps RAM, copies `u-boot.bin` into flash 0, writes the tree and starts CPU 0 at
   address 0 in EL1.
2. U-Boot prints on the PL011, scans PCIe, starts virtio and finds
   `/boot/extlinux/extlinux.conf` on the disk. Henge's build has no countdown.
3. U-Boot loads the kernel and the initrd and jumps to the kernel with the tree in `x0`.
4. Linux mounts the root from virtio block. `henge-grow.service` then grows the partition
   and the file system when the disk file has grown.

On the Mac tool, one CPU reaches the login prompt in 4.6 to 4.8 s from a warm start and 6
to 7.3 s from a first start. In the iOS simulator the console prompt took about 12 s. No
number from an iPhone exists yet.

### The console

The PL011 is the guest's serial console, and the kernel prints on it (`console=ttyAMA0`).
`hv_vm_console_set_output` takes the bytes. `hengevm` sends them to stdout. In the app,
`henge_vm_console_read` drains a 256 KB ring into a SwiftTerm terminal (`ConsoleView.swift`),
and typed bytes go back through `henge_vm_console_write` and `hv_vm_console_input`. CPU 0's
tick moves them into the UART as its FIFO has room. A Linux machine opens on the console and
stays there until the user switches to the screen.

### The virtio GPU

`devices/virtio_gpu.c` is a virtio GPU with one scanout. In 2D mode the guest draws into its
own RAM, `TRANSFER_TO_HOST_2D` copies a rectangle into a host buffer, and `RESOURCE_FLUSH`
wakes the presenter. `devices/vgpu_metal.m` copies the dirty rectangle and draws it on a
`CAMetalLayer`, at most 60 times a second. `HvDisplayOps` (`host/vm.h`) is how the host layer
reaches any board's display, so macOS and Linux share the layer, the snapshot and the mode
calls. `--screenshot` and `--window` use the same path.

With `--gpu-accel` (the Graphics acceleration switch in the app), the device also takes the
virgl 3D commands. `devices/vgpu_virgl.m` runs virglrenderer on ANGLE's Metal backend, on
one thread that owns every GL call. The guest gets OpenGL ES 3.0 and compatibility GL 2.1.
ES 3.0 is the ceiling, because ANGLE's Metal backend refuses ES 3.1. A 3D scanout is blitted
into an `IOSurface` that the presenter draws. ANGLE's blob cache keeps compiled shaders in the
app's `Library/Caches/Henge` folder, so a program stalls only the first time. The libraries
are static and built by `tools/gfx/build-deps.sh` ([tools/gfx](../tools/gfx/README.md)).

The A8 gate (`make test-linux-accel`) boots virgl and a software renderer back to back in one
run, so both see the same host load. It passes when virgl's median frame time for a
full-window client is at most 4 ms, the 99th percentile is at most 16.7 ms, and glmark2 is at
least 3 times llvmpipe's score. The virgl to pixman ratio is printed only, because the shared
memory path costs virgl one extra upload. The desktop image picks gles2 on virgl and pixman
otherwise, at every session start.

### The display mode

The host sets the screen size with `hv_vm_set_display_mode`, and the device tells the guest
through a display change. The app's `DisplayModePolicy` picks the size (the phone's native
size with rotation, an external display, or a fixed size). The share server answers
`GET /.henge/display` with `W H SCALE`, and `henge-display` in the desktop image follows it
within 0.5 s. With only fbcon as a client (the console image), the guest accepts only modes up
to its boot size.

### Sharing, sound and memory

The shared folder is the same WebDAV server as on macOS, at `10.0.2.4`. The guest mounts it
at `~/Henge` with davfs2, and `henge-clipboard` speaks the clipboard protocol of
`tools/henge-agent.m`. Sound is `snd_virtio` on `host/audio_mac.c`. Virtio block offers
discard on this board, and the host punches holes in the disk file. The balloon device exists,
and Linux's `virtio_balloon` binds to it, but no policy in the app drives it yet.

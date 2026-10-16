# PCIe colorbar protocol

The default `hdmi_fmc_pcie_top.USE_TEST_PATTERN=1` generates 1280x720 eight
vertical bars, 160 pixels per bar: white, yellow, cyan, green, magenta, red,
blue, black. No HDMI card or video input is required. The unused HDMI receiver
is excluded by generate; `USE_TEST_PATTERN=0` retains the inherited HDMI path,
which has not been validated by this work.

## Payload and flow control

Each pixel is a DWORD `00RRGGBB`, packed four pixels per 128-bit word, first
pixel in bits 31:0. The MWR TX controller reverses bytes within each DWORD to
match the reference Pango TLP interface. Expected little-endian host bytes are
`B G R 00`. Frame size is 3,686,400 bytes, not RGB565 or packed 24-bit RGB.

The generator advances only on valid && ready. `FORCE_CAPTURE=1` preloads the
FIFO, then pauses the generator while full, preserving coordinates between
host commands. FIFO reads occur only during DMA. No pixels are discarded in
colorbar mode, so arbitrary host delays do not shift the raster. The FIFO is
not a full frame buffer. The HDMI mode uses a different capture policy and
does not inherit the pause guarantee of the artificial source.

## BAR1 command interface

PCI ID `0755:0755`, memory BAR1, driver node `/dev/pango_pci_driver`.
BAR1 is already enabled in the bundled PCIe wrapper. Real PCIe credit outputs
are connected to the DMA wrapper. This test uses endpoint mode and MWR only.

| Offset | Write value |
|---|---|
| 0x110 | Destination DMA address, low 32 bits |
| 0x120 | High 32 bits; write for a 64-bit command |
| 0x100 | bit24=MWR; bit16=64-bit address; bits9:0=DWORD count minus one |
| 0x130 | bit0=restart colorbar generator and video FIFO while MWR is idle |

Write address first, then command. Use 16-byte-aligned DMA addresses and
lengths divisible by 16 bytes. Maximum length is **4080 bytes (1020 DWORDs)**:
the reference decoded length is only 10 bits, so 1024 DWORDs would wrap to zero.
One command must not cross a 4KiB boundary. MWR splits commands into TLPs no
larger than the negotiated MPS; this implementation supports 128/256/512/1024
byte packets and conservatively uses 1024 for larger MPS codes.

The vendor RX expands each First-DW byte-enable bit into four BAR1 enable
bits. Therefore register acceptance must check all 16 expanded bits, not just
the low four. The RX integration test checks partial-byte writes are ignored.

0x130 holds video reset for 16 PCIe clocks without resetting the link. The
driver waits 10ms before its next command. Reset at the beginning of every
application invocation aligns pixel zero; complete frames can then follow
continuously. It is a write-only strobe with no hardware version readback.

## RK companion

`RK3568/pcie_colorbar` provides a dedicated ABI=1 driver and CLI. Legacy
map/write/read/unmap ioctl numbers and the 8204-byte operation layout match the
reference subset; INFO and RESET ioctls are new. Other old benchmark commands
return ENOTTY. Pair this FPGA image with the bundled driver and application.

The driver allocates a 4KiB coherent DMA page below 4GiB, checks boundaries,
serializes transfers, and waits for the final ordered DWORD to replace an A5
sentinel. This completion scheme is specific to the supplied 00/FF colorbar
values; it is not a general video DMA completion protocol. Userspace compares
every DWORD; data arrival alone never means PASS. Timeout poisons the session
until device/driver recovery. Open descriptors survive device removal with
ENODEV instead of accessing freed MMIO state.

The CLI saves PPM and optional raw output, verifies all pixels and prints
PASS only after every requested frame passes. Static ARM64 executable is
included in the package. The RK kernel module must be compiled against the
actual board's matching kernel build tree.

## Verification boundary

PDS full build and constrained timing pass. RTL tests cover 32/64-bit MWR,
MPS128..1024, stalls, FIFO wrap, two complete frames, repeated software resets,
partial byte enables and invalid commands. Unused BAR0/BAR2 RAMs are behavioral
models in RX simulation; no hard IP, PHY or physical link is simulated.

SCBV is still unset in the inherited PDS configuration; see the build report.
Actual programming, enumeration, DMA coherency and received image remain for
board testing. Source/build success does not establish physical PCIe success.

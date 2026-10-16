# Findings

- Reference protocol: 0755:0755, BAR1 0x100/110/120, legacy map/write/read ioctl layout.
- Generator was white and advanced while stalled; FIFO packed96bits instead of paddedDWORDs.
- New source pauses without losing coordinates; default test mode excludes HDMI PLL/I2C.
- MWR outputs now stable under stalls, counted TLAST and per-packet address increments.
- Actual RX expands each byte enable fourfold. Keep full16-bit check. An intermediate low-four
  change incorrectly accepted partial writes and was reverted based on integration simulation.
- Max1020DWORD/4080B because10-bit decoded1024length wraps to0; no4KiB crossing.
- BAR1 0x130 reset aligns each application invocation. Driver sentinel limited to00/FFcolorbars.
- PDS2022.2-SP4.2 full build succeeds, All Constraints Met. SCBV unset remains; no guessed voltage.
- Icarus direct PASS25680pixels; RX PASS1849616pixels/45094TLPs, two frames/reset/invalidwrites.
- Native program checks and static AArch64 build pass. Driver W=1 x86 Linux5.15 build passes.
- Actual RK kernel tree unavailable; ship driver source, not hostmodule. No physical tests performed.

# Findings: RK-FPGA Communication Protocol

- `RK3568/docs/architecture.md` and `RK3568/include/rk_protocol.hpp` define a
  portable, single-channel frame protocol: little-endian, 32-byte header,
  protocol version 1, observation message type 1, maximum payload 4096 bytes,
  and CRC32 over the payload.
- The observation payload is fixed at 20 bytes and contains frame identity,
  input dimensions, health/safety flags, obstacle distance, lane offset, and
  Q15 confidence values.
- `RK3568/src/pcie_backend.cpp` currently performs only `open/read/close` on a
  configured Linux device node. It does not implement BAR mapping, DMA rings,
  MSI/MSI-X, ioctl contracts, or device-tree integration.
- The existing top-level design document proposes BAR/PIO, DMA, MSI, register
  offsets, descriptor fields, and ownership states, but labels them as design
  recommendations rather than board-validated facts.
- Existing tests cover round-trip framing, partial streams, CRC rejection and
  resynchronization, safety gates, sequence gaps, and the simulator runtime.
  They do not prove live PCIe, FPGA RTL, DMA, interrupt, or board throughput.


# PCIe colorbar implementation

User authorized direct completion. No board upload/programming/testing.

1. [complete] Fix packing, generator backpressure, MWR handshakes, address/control sequencing.
2. [complete] Dedicated bounded DMA driver ABI=1, lifetime protection and standalone CLI.
3. [complete] RTL direct and RX integration simulation, two frames, reset and invalid commands.
4. [complete] Fresh full PDS build and timing pass; native/selftests/static AArch64 build;
   host Linux 5.15 driver W=1 build passes. No RK kernel tree available.
5. [complete] Archive exact matching sources/bitstream/ARM64 binary, docs, logs and hashes;
   verify archive extraction, source references and all hashes.

Final FPGA build: PGL/Design/build_colorbar_20261014_verified.
Residual: SCBV not established, compiler warning retained; board user must verify before programming.
Board .ko requires actual matching kernel. No x86 .ko in archive.


# Progress Log: RK-FPGA Communication Protocol

## 2026-09-25

- Read the applicable skill instructions and the existing project planning files.
- Inspected the current architecture document, protocol header/implementation,
  CRC implementation, PCIe backend, tests, and README.
- Confirmed the protocol document must distinguish portable software evidence
  from unverified board-level PCIe details.
- Added `RK3568/docs/rk_fpga_protocol_v1.md` with normative frame, message,
  control-plane, ownership, safety, compatibility, and acceptance rules.
- Linked the protocol document from `RK3568/README.md` and
  `RK3568/docs/architecture.md`.
- Added a deterministic 52-byte Observation golden vector with expected CRC32.
- Self-review checked protocol headings, TBD markers, current source mappings,
  and cross-document links; `git diff --check` passed.
- Attempted to use `docker_rk:latest` for the existing C++ tests, but the Docker
  Linux engine was not running. No compiled test result is being claimed.

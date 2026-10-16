# Task Plan: RK-FPGA Communication Protocol

## Goal

Create an authoritative RK3568-to-FPGA communication protocol document that
separates the implemented portable wire format from hardware-specific PCIe
items still awaiting board validation.

## Scope

- Document the current frame wire contract and safety semantics.
- Define the PCIe control/data-plane contract and mark unverified fields as TBD.
- Add versioning, ownership, error recovery, and acceptance criteria.
- Do not change RTL, Linux drivers, or application behavior in this task.

## Phases

- [x] Phase 1: Inspect existing architecture, protocol code, tests, and project history.
- [x] Phase 2: Draft the normative protocol document.
- [x] Phase 3: Self-review for contradictions, unsupported claims, and missing acceptance gates.
- [x] Phase 4: Verify the document against the current source and report results.

## Errors Encountered

| Error | Attempt | Resolution |
|---|---:|---|
| `rg.exe` was unavailable with `Access is denied` in the workspace | 1 | Used PowerShell-native file discovery and search instead. |
| Docker Linux engine was not running when attempting the existing container test | 1 | Recorded the environment limitation; completed static/document verification and did not claim a compiled test pass. |

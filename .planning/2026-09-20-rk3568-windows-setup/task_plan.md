# Task Plan: RK3568 Windows Host Setup

## Goal

Prepare the Windows host for the Mac -> GitHub -> Windows -> RK3568 workflow.

## Scope

- Inspect existing Git, WSL2, Docker, SSH/ADB, serial, and RK tooling.
- Install only missing general-purpose tools that are safe and necessary.
- Use the supplied board materials for RKDevTool, USB serial, and Docker SDK.
- Do not flash the board or modify firmware without an explicit hardware action.

## Phases

- [x] Phase 1: Inspect current host and supplied tools.
- [x] Phase 2: Install or enable missing host prerequisites.
- [x] Phase 3: Verify Docker/WSL2, SSH/ADB, and RK tool availability.
- [x] Phase 4: Report remaining manual steps and hardware-dependent checks.

## Errors Encountered

| Error | Attempt | Resolution |
|-------|---------|------------|
| `winget install 7zip.7zip` failed with source/application error `0x80073cfc` | 1 | Left 7-Zip optional; ZIP extraction works with PowerShell and the board setup is otherwise complete. |
| `Get-WindowsOptionalFeature -Online` required elevation | 1 | WSL2 is already operational through Docker Desktop; no feature change was needed. |

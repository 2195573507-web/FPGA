# Task Plan: FPGA IIC Audit

## Goal

Audit the active PGL/Design IIC path for functional, clocking, CDC, pin,
protocol, and verification problems without changing RTL.

## Phases

- [x] Locate the active project, source files, constraints, and existing evidence.
- [x] Inspect the IIC master, MS7200/MS7210 controllers, top-level wiring, and PLL.
- [ ] Check transaction-count/state-machine edge cases and compare reference copies.
- [ ] Check build/timing evidence and classify findings by severity.
- [ ] Publish a concise review with file/line evidence and board checks still required.

## Scope Boundary

- Preserve unrelated dirty-worktree changes.
- Treat generated bitstreams and host logs as build evidence, not board evidence.
- Do not patch RTL unless the user asks for a fix after the audit.

## Errors Encountered

| Error | Attempt | Resolution |
|---|---:|---|
| `rg` over generated/symlink-heavy tree emitted inaccessible-directory errors | 1 | Narrowed searches to `PGL/Design/source`, constraints, and logs. |

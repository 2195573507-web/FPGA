# Progress Log

## 2026-09-18

- Confirmed the team's HDMI-input direction.
- Confirmed the vendor architecture recommendation: an FMC-to-HDMI daughter
  card supplies 1080P input to the FPGA, and PCIe DMA transfers ROI or processed
  frames to RK3568 memory.
- Added `赛题三三人分工与完成顺序.md` with role ownership, frozen interfaces,
  M0-M7 milestones, basic/high-level acceptance gates, and risk handling.
- Expanded the same plan with the full S0-S13 implementation lifecycle,
  including requirements decomposition, hardware feasibility, four-stream
  go/no-go, performance evidence, and system acceptance. Competition defense,
  video production, and submission packaging were intentionally excluded.
- No FPGA, Linux, PDS, PCIe, or RKNN source code was changed or built.
- Reworked `赛题三快速上手开发手册.md` into a comprehensive project knowledge
  map: hardware, FPGA video, HDMI, CDC, DDR3, PCIe/Linux, RKNN, computer vision,
  ADAS decisions, multi-channel scaling, performance, validation, and learning
  order. Team allocation was removed as requested.

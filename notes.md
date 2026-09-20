# Research Notes: RK3568 + PG2L100H ADAS

## Confirmed Local Evidence

- The supplied contest guide identifies the official board as
  `RK3568_MES2L100H`, with a Rockchip RK3568J and a logos2
  `PG2L100H-6IFBG484` FPGA.
- The guide lists two optical-module interfaces, FMC, 40-pin expansion,
  buttons, and LEDs. It does not establish a specific FPGA-to-RK3568 data
  interface, HDMI wiring, Linux BSP revision, or board reference design.

## Research Standard

Only projects with a visible upstream revision and license are candidates.
Compatibility with Pango PDS, the board wiring, and its actual Linux image
remains unverified until the board documentation and hardware are inspected.

## Board Facts Verified From Vendor Material

- The official hardware manual states that RK3568 and PG2L50H/PG2L100H are
  connected by PCIe, FSPI, I2C0, and some GPIO. Its interconnect drawing shows
  two PCIe TX/RX lane pairs; the configured lane width and endpoint/root-complex
  roles must be checked in the delivered PDS project and device tree.
- FPGA-side resources include DDR3, FMC LPC, 40-pin GPIO, two SFP-related
  interfaces, and a DVP-capable OV5640 expansion path. RK-side resources include
  a separate HDMI output and Linux-capable RK3568J subsystem.
- The vendor's eight-video reference uses FPGA GPIO, FMC expansion, and SFP for
  video inputs. It is a hardware topology reference, not an open RTL project.
- The vendor states that the PCIe IP collection for this board is internal and
  must be requested. A generic PCIe core cannot be assumed to target Pango PDS
  or this board's PG2L100H HSST configuration.

## Upstream Findings

- `airockchip/rknn_model_zoo` provides RK3568-supported Linux C examples for
  object detection and semantic segmentation. Its Apache-2.0 code license is
  suitable for a first deployment path, but each imported model and dataset
  still needs its own license check.
- The same model zoo offers `ppyoloe` and `ppseg`; both originate from Apache-2.0
  Paddle projects. This avoids making GPL YOLOv5 the initial baseline.
- MIT-licensed YOLOP, YOLOPv2, HybridNets, and Ultra-Fast-Lane-Detection-v2 are
  useful research/POC sources but have no verified RK3568 RKNN deployment in
  this investigation. They are not the first integration baseline.
- `alexforencich/verilog-axis` offers MIT-licensed stream FIFO, async FIFO,
  register, and arbitration RTL. It may be adapted only after excluding Xilinx
  primitives and proving PDS synthesis; it is not a PG2L100H board project.

## Official Example Audit (2026-09-18)

- The local official examples are for `MES50HP + PGL50H`, not the target
  `RK3568_MES2L100H + PG2L100H`; use them as migration templates until PDS
  projects, constraints, IP versions, and board wiring are checked.
- With the HDMI-input plan, the strongest reusable examples for Topic 3 are
  HDMI RX/TX loopback + DDR3 frame buffering, plus the PCIe enumeration example.
- The contest guide does not confirm an FPGA-side HDMI RX on the target board;
  `56-HDMI` uses the MES50HP MS7200/MS7210 PHY pair and cannot be assumed to
  transfer directly. A board-specific HDMI RX module, pinout, I2C setup and
  PDS IP must be confirmed or supplied.
- The vendor's contest architecture guidance does explicitly recommend an
  FMC-to-HDMI daughter card for 1080P HDMI input and PCIe DMA from FPGA to
  RK3568 memory. This supports the HDMI-input plan while leaving the exact
  daughter-card PHY and PDS package as a handoff item.
- LED/button, I2C, UART, Ethernet, HSST, VGA, and HDMI examples are useful
  peripheral and bring-up building blocks, not ADAS recognition implementations.
- The official examples do not provide pedestrian/obstacle/traffic-light/lane
  recognition, RKNN/NPU deployment, four-source scheduling, or the final ADAS
  decision state machine.
- Detailed mapping is in `官方历程能力与赛题三映射.md`.

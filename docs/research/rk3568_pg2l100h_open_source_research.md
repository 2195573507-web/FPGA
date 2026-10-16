# RK3568 + PG2L100H ADAS Open-Source Research

Status: research complete on 2026-09-15

## 1. Scope and Hardware Baseline

This report concerns the official `RK3568_MES2L100H` board: Rockchip RK3568J
plus logos2 `PG2L100H-6IFBG484`. It is a research/adoption report, not a claim
that any linked repository has been built for Pango PDS or flashed to the board.

The vendor's hardware manual verifies RK-to-FPGA PCIe, FSPI, I2C0, and GPIO
connections. FPGA-side resources include DDR3, FMC LPC, 40-pin GPIO, SFP, and
an OV5640 DVP path. RK-side HDMI is the documented display output. The contest
guide does not confirm an FPGA-side HDMI RX on this board. The manual's
interconnect diagram shows two PCIe TX/RX lane pairs, while other documentation
uses a broader PCIe Gen2*4 label. Verify the actual lane configuration in the
vendor PDS project and RK device tree; do not set a DMA bandwidth target from
the marketing label alone. The vendor's contest architecture guidance explicitly
recommends an FMC-to-HDMI daughter card for a 1080P HDMI input and PCIe DMA
from FPGA to RK3568 memory; this is the preferred input path for this plan.

Vendor sources:

- [Board hardware manual](https://szlogicmatrix.com/368.html)
- [Eight-video input topology](https://szlogicmatrix.com/1147.html)
- [Vendor contest architecture guidance](https://szlogicmatrix.com/forum-post/1484.html)
- [Vendor note that this board's PCIe IP is internal](https://szlogicmatrix.com/forum-post/1429.html)

## 2. Recommended Architecture

```text
FMC-to-HDMI daughter card (HDMI RX) or OV5640 DVP
  -> FPGA: capture, CDC, format conversion, resize/Sobel/ROI and front-end features/candidates
  -> vendor PCIe EP + DMA: front-end results and selected ROI/frame to RK DDR
  -> RK3568: high-level classification/fusion -> RKNN/CPU -> decision state machine -> OSD
  -> RK HDMI output and board LEDs
```

Use PIO only for configuration/status and DMA for image payload. At 1080p60,
one uncompressed RGB888 stream is about 373.2 MB/s and YUV422 is about
248.8 MB/s before descriptor and protocol overhead; 1080p30 is half those
values. That makes FSPI unsuitable
as the final full-frame transport, although it can be a valid early control-path
or narrow-ROI bring-up route.

For the HDMI-input plan, the first competition baseline should use one stream.
It should identify person,
vehicle/obstacle, and traffic-light candidates; classify traffic-light color in
the detected ROI; segment road/lane pixels; classify a lane as solid/dashed;
then apply an explicit safety-priority state machine. Four streams are a later
bandwidth and scheduling expansion, not a starting condition.

## 3. Adoption Shortlist

| Priority | Project and pinned revision | License | Use in this project | Integration status |
|---|---|---|---|---|
| P0 | [RKNN Model Zoo](https://github.com/airockchip/rknn_model_zoo/tree/bad6c7334531becaf90a561988519b7bec34d0ab) | Apache-2.0 | Reuse the Linux C demo structure and the RK3568-supported `ppyoloe` and `ppseg` examples. | Direct starting point after SDK/BSP version match. |
| P0 | [RKNN Toolkit2 mirror](https://github.com/rockchip-linux/rknn-toolkit2/tree/1f4415eafe8f578787822fc836f38df3ef3b5627) and the current [vendor repository](https://github.com/airockchip/rknn-toolkit2) | BSD-3-Clause for the pinned mirror; current vendor repository has no SPDX declaration | Model conversion on host and runtime compatibility reference. | Use the runtime library that matches the target image and NPU driver; do not mix arbitrary releases. |
| P0 | [PaddleDetection](https://github.com/PaddlePaddle/PaddleDetection/tree/b25522a0f4bde8c80603f3ba5e3472059972e3b5) | Apache-2.0 | Train/fine-tune a traffic-light color or obstacle detector when COCO labels are insufficient. | Offline training/export source, not the board runtime. |
| P0 | [PaddleSeg](https://github.com/PaddlePaddle/PaddleSeg/tree/3c4db66de1d9d59d0628ed87590b6308a2f4aa2a) | Apache-2.0 | Custom road/lane segmentation. The Model Zoo already supplies a `pp_liteseg_cityscapes` RK3568 example. | Begin with Model Zoo C demo, fine-tune only after field failure evidence. |
| P0 | [OpenCV](https://github.com/opencv/opencv/tree/67d6fdd4bc1813501570889e045b3a41873a9c3b) | Apache-2.0 | Traffic-light red/green ROI classification, lane-mask geometry, solid/dashed decision, OSD, offline video regression. | Direct ARM application dependency after rootfs/package verification. |
| P0 | Vendor PDS PCIe IP, DMA example, matching Linux driver, DDR3 and HDMI RX/OV5640 reference projects | Vendor/internal, not open source | Board-specific endpoint, DDR3 calibration, HDMI RX/DVP timing, and PCIe DMA. | Required external dependency. Request before writing DMA HDL. |
| P1 | [verilog-axis](https://github.com/alexforencich/verilog-axis/tree/48ff7a7e2ef782cf778d47910cf85835c64b1bce) | MIT | Review/adapt `axis_async_fifo`, FIFO, register, and arbitration patterns for pure RTL video/control streams. | Adapt selectively; do not synthesize unchanged without PDS review. Repository is deprecated upstream. |
| P1 | [cocotb](https://github.com/cocotb/cocotb/tree/079a2d4609fc3486422e3efa4ae5b2c4ae19449d) | BSD-3-Clause | RTL testbenches for pixel timing, CDC/FIFO resets, frame descriptor protocol, and loss/backpressure cases. | Use for vendor-primitive-free RTL; retain PDS/ModelSim verification for vendor IP. |
| P1 | [CVAT](https://github.com/cvat-ai/cvat/tree/608d360ff7788e66947c7ed0ad39fc794665ae9f) | MIT | Annotate a small, task-specific red/yellow/green traffic-light and solid/dashed-lane data set. | Development infrastructure only; run on a workstation, not RK3568. |
| P2 | [Ultra-Fast-Lane-Detection-v2](https://github.com/cfzd/Ultra-Fast-Lane-Detection-v2/tree/c903880678454dfd9b55a63022368db05c00bc6d) | MIT | Dedicated lane model; it includes ONNX export with four outputs. | POC only. RKNN conversion/operator support and performance are unverified. |
| P2 | [YOLOP](https://github.com/hustvl/YOLOP/tree/8d8f68df318c71f01d6f813c024df646c7d1978f) | MIT | Reference for one network covering detection, drivable area, and lane lines. | POC only; no official RK3568 RKNN example was found. |
| P2 | [HybridNets](https://github.com/datvuthanh/HybridNets/tree/8735a6991a23c2d646a514a665193168f8251ebe) | MIT | Multitask architecture/training reference. | Research only until conversion and board benchmark pass. |
| P2 | [YOLOPv2](https://github.com/CAIC-AD/YOLOPv2/tree/9388c6aa55f3bf5a878679a1338bb090cff6a256) | MIT | Higher-capacity multitask comparison source. | Do not use for the first board build; authors report 38.9M parameters and V100-only benchmark data. |
| P2 | [MMDetection](https://github.com/open-mmlab/mmdetection/tree/cfd5d3a985b0249de009b67d04f37263e11cdf3d) and [MMSegmentation](https://github.com/open-mmlab/mmsegmentation/tree/b040e147adfa027bbc071b624bedf0ae84dfc922) | Apache-2.0 | Offline experimentation and model export research. | Too broad for first deployment; no direct RK3568 runtime path is assumed. |
| P2 | [BDD100K toolkit](https://github.com/bdd100k/bdd100k/tree/9ac17c6c7c51d2fc83065fccd707cd5b1882a293) | BSD-3-Clause | Annotation format utilities and driving-scene experiment reference. | Dataset use is separately governed by BDD100K terms; do not bundle data into the project without review. |

## 4. Explicit Exclusions

- `airockchip/yolov5` is GPL-3.0 and Ultralytics is AGPL-3.0. Do not choose
  either as the initial source path when Apache-licensed PP-YOLOE is available.
  The Model Zoo's model files still require a separate provenance/license review.
- LitePCIe and other generic PCIe projects are not a shortcut for this board:
  no PG2L100H/Pango target, HSST wrapper, or RK3568 board driver was verified.
- `mnescola-lichun/plate-recognition-fpga` names PG2L100H but has no visible
  license or sufficient documentation. It is not an adoptable dependency.
- Do not begin from the vendor's eight-video topology. It is a useful later
  expansion reference, but adds FMC/SFP/card dependencies and hides bring-up
  failures that must first be solved on one video channel.

## 5. Required Bring-Up Gates

| Gate | Required proof | Failure response |
|---|---|---|
| G0: vendor handoff | Exact PDS version, `PG2L100H` PCIe IP/example, FMC HDMI RX and DDR3 projects, RK image, matching PCIe driver, RKNN runtime version. | Stop PCIe HDL work; request the matched package. |
| G1: NPU | The shipped image exposes `/dev/rknpu`; an unmodified RKNN Model Zoo RK3568 C demo completes inference. | Repair/reflash the BSP/device tree before any custom model work. |
| G2: PCIe control | Enumerated link plus deterministic PIO register read/write and reset recovery. | Fix role, clocks, reset, BAR and driver before DMA. |
| G3: PCIe DMA | FPGA-to-RK known-pattern frame/ROI DMA with frame sequence, byte count, CRC, and 1,000-cycle error-free loop. | Diagnose cache coherency, buffer ownership, descriptor ordering, and reset sequencing. |
| G4: video | HDMI RX source has correct dimensions, pixel format, CRC/line count and no CDC overrun at target frame rate. | Fix HDMI RX, capture and DDR3 before adding inference. |
| G5: ADAS demo | Timed video regression demonstrates stop/drive/alarm and solid/dashed transitions with a recorded evidence set. | Tune thresholds or fine-tune model; do not claim vehicle acceptance. |

## 6. Data and Ownership Contract

Use one ring descriptor per FPGA-produced frame:

```text
frame_seq, capture_time_us, buffer_dma_addr, byte_count,
width, height, stride, pixel_format, roi[], crc32, producer_state
```

RK must return a release index only after DMA ownership ends. PIO control
registers should cover `start`, `stop`, `reset`, `format`, `frame_drop_count`,
`dma_error`, and a monotonically increasing heartbeat. The decision message
returned from RK should contain `frame_seq`, traffic-light state/confidence,
lane-class/confidence, obstacle state, requested turn, and final action. This
prevents an inference result from being displayed on the wrong frame.

Action priority must be fixed: fault/alarm > red-light stop > collision stop >
solid-line change-lane rejection > permitted navigation action > normal drive.

## 7. First Two Weeks

1. Obtain the vendor package listed in G0 and record every tool/image version.
2. On the unmodified RK image, run the RKNN Model Zoo `ppyoloe` and `ppseg`
   C demos with target `rk3568`; record latency, NPU utilization, RAM, and
   result images.
3. Make an ARM-only reference pipeline using an MP4 file: PP-YOLOE
   candidate detection, HSV traffic-light color, PP-LiteSeg mask, OpenCV
   lane classification, state-machine overlay to RK HDMI.
4. Bring up FPGA clock/reset/LED, then the vendor HDMI RX source and DDR3.
5. Establish PCIe PIO and DMA using synthetic patterns before transporting
   HDMI video.
6. Replace the ARM-only video source with the FPGA HDMI RX plus DMA ring. Keep the same
   descriptor and decision interfaces so application logic does not change.

## 8. Evidence Boundaries

- `source`: vendor manuals and upstream repositories listed above.
- `build`: no PDS, Linux, driver, or RKNN build has been run in this workspace.
- `bench/device`: no board, PCIe enumeration, NPU node, HDMI RX, or HDMI runtime
  capture has been supplied.
- `vehicle`: this competition work remains a simulated driving-assistance
  demonstration, not a real-vehicle safety system.

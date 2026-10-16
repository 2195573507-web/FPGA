#ifndef RK3568_PCIE_VIDEO_REGS_H
#define RK3568_PCIE_VIDEO_REGS_H

/* Endpoint BAR1 register offsets from ips2l_pcie_dma_controller.v. */
#define RK_PCIE_DMA_CMD       0x100u
#define RK_PCIE_DMA_ADDR_LO   0x110u
#define RK_PCIE_DMA_ADDR_HI   0x120u
#define RK_PCIE_TEST_RESET    0x130u

/* DMA command bits. The length field is DWORD count minus one. */
#define RK_PCIE_DMA_CMD_WRITE (1u << 24) /* FPGA memory write to host */
#define RK_PCIE_DMA_CMD_ADDR64 (1u << 16)
#define RK_PCIE_DMA_CMD_LEN_MASK 0x3ffu

#define RK_PCIE_VIDEO_BYTES_PER_BEAT 16u
#define RK_PCIE_VIDEO_PIXELS_PER_BEAT 4u

#endif

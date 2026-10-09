# PS 端接口说明

基准来自队友仓库主工程：

- PL_REG_BASEADDR = 0x44000000
- MODE_REG = 0x00
- CMD_REG = 0x10
- DATA_REG = 0x20
- DBG0 = 0x30
- DBG1 = 0x34
- DBG2 = 0x38
- DBG3/STATUS = 0x3C
- DBG4 = 0x40

网络图片接收后写入 DDR 0x20000000，调用仓库现有 VDMA 接口：

- vdma_mm2s_stop
- vdma_mm2s_reset
- vdma_mm2s_config
- vdma_mm2s_start

随后写：

- MODE_REG = SINGLE_MODE = 1
- DATA_REG = threshold
- CMD_REG = REOPERATE = 1

本代码依赖队友仓库中的 drv/vdma.h、drv_vdma.c 和 app/cfg.h。

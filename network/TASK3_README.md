# 任务3：网络图片到DDR并启动VDMA

## 文件

- network_vdma_server.c
- network_protocol.c/h
- ps_config.h

## 接口对齐

PL控制基地址：

~~~text
0x44000000
~~~

寄存器：

~~~text
0x00 MODE
0x10 CMD
0x20 DATA
0x30 DBG0
0x34 DBG1
0x38 DBG2
0x3C STATUS
0x40 DBG4
~~~

模式：

~~~text
MODE_SINGLE = 1
MODE_STREAM = 2
~~~

命令：

~~~text
CMD_REOPERATE = 1
~~~

## 图片流程

~~~text
TCP 5001接收IMAGE_RAW
  -> 写入DDR_IMAGE_BASE=0x20000000
  -> Xil_DCacheFlushRange
  -> vdma_mm2s_stop
  -> vdma_mm2s_reset
  -> vdma_mm2s_config
  -> vdma_mm2s_start
  -> MODE_REG=1
  -> DATA_REG=threshold
  -> CMD_REG=1
~~~

注意：这段代码调用队友仓库的drv/vdma.h驱动，不直接操作VDMA寄存器。

## 依赖

需要将源码加入包含以下文件的Vitis工程：

- csrc/MID_plt/src/drv/vdma.h
- csrc/MID_plt/src/drv_vdma.c
- csrc/MID_plt/src/app/cfg.h

同时需要在Vivado中启用PS Ethernet0、MDIO和对应中断，在BSP中启用lwIP。

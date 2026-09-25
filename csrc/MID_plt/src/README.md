# src/ 目录结构

Vitis 的模板不会自动扫描源文件，而且它在构建时会**重写 CMakeLists.txt**，
把子目录里的源文件写成 **Windows 反斜杠路径**（`app\app.c`），CMake 解析 `\a` 直接失败：

    Invalid character escape '\a'

**所以 `.c` 必须平铺在 src/ 下**（实测撞过两次，不是猜的）。
这里的折中办法：**`.c` 平铺 + 文件名前缀分组；`.h` 按层放进子文件夹。**

```
src/
|-- main.c                 只做 init + 交给 app 层
|-- app.c                  命令表 + 分发（加功能只改这里）
|-- crc32.c                CRC32
|-- uartln.c               串口链路
|-- drv_emmc.c             eMMC 裸块读写
|-- drv_vdma.c             AXI VDMA MM2S（寄存器级）
|-- img_catalog.c          eMMC 图像目录 TOC
|-- img_ddr.c              DDR 图像缓冲 + cache 维护
|-- feat_emmc_load.c       feature: PC -> eMMC
|-- feat_img2ddr.c         feature: eMMC -> DDR -> VDMA
|-- platform.c / platform.h    Vitis 模板自带
|-- app/      app.h   cfg.h
|-- common/   crc32.h uartln.h
|-- drv/      emmc.h  vdma.h
|-- img/      catalog.h  ddr.h
`-- feat/     emmc_load.h  img2ddr.h
```

## 分层依赖（只允许往下调）

```
main.c --> app.c --> feat/* --> img/* , drv/* --> common/*
```

- `main.c` 不碰任何驱动，只调 `app_init()` / `app_run()`
- 加一个新功能 = 在 `feat/` 加一对文件 + 在 `app.c` 的命令表加一行
- 新增 `.c` **必须**加进 `CMakeLists.txt` 的 `collect(...)` 列表（模板不扫目录）

## 数据通路（PS 侧）

```
eMMC --(drv_emmc)--> PS DDR 0x20000000 --(PS7 S_AXI_HP0)--> AXI SmartConnect
                                                                  |
                                                            AXI VDMA MM2S --> PL
```

`img_ddr.c` 负责 cache 一致性：PS 写完、交给 PL 之前必须 flush，
否则 VDMA 从 DDR 读到的是旧数据（现象是图是花的，且时好时坏）。
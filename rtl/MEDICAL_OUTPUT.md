# 医学分析输出链路

```
top_threshold_demo ─┐
                   ├─ output_frame_xbar → hdl_out → double_buf
medical_accel_top ──┘                                 ├─ out_arr → hdmi_out → HDMI
                                                     └─ back_reader → out_arr → back_stream → S2MM
```

`reg_mode=0` 选择图像处理输出，`reg_mode=1` 选择医学分析输出。xbar 在首个有效像素出现时锁定选择，即使首像素被反压也保持选择，直到帧尾成功握手才允许切换。未选中的源收到 `ready=0`；选中源承受下游的真实反压。切换模式前应结束当前收发任务，不能假定切换寄存器会清空上游仍未输出的帧。

## 像素和缓存

顶层使用 `CHAMBERS=4`，位序为 `[3:0]={RV,LV,RA,LA}`。图像处理支路的单路 mask/contour 放在 bit 0，其余位清零。

双缓存每个像素保存 17 位：

| 位 | 内容 |
|---|---|
| 7:0 | 灰度 |
| 11:8 | 四腔 mask |
| 15:12 | 四腔 contour |
| 16 | 来源：0 图像处理，1 医学分析 |

灰度、标记、来源打包在同一个 BRAM 字中，两个读口均同步读出，延迟仍是一拍。来源随像素保存，避免切换系统模式后按新模式解释旧缓存。原有 HDMI/回传 bank 所有权、跨时钟发布和保护机制保持有效。

## 着色与透明度

医学帧固定显示“灰度 + 彩色半透明掩膜 + 实色轮廓”，不依赖图像处理模式的 `VIDEO_MODE` 下拉框。

| 腔室 | mask/contour 位 | RGB |
|---|---|---|
| LA 左心房 | 0 | 红 `FF0000` |
| RA 右心房 | 1 | 黄 `FFFF00` |
| LV 左心室 | 2 | 绿 `00FF00` |
| RV 右心室 | 3 | 蓝 `0000FF` |

先以掩膜颜色进行 alpha 混合，再由轮廓覆盖。多个腔室标记重叠时，优先级为 LA、RA、LV、RV。无掩膜、无轮廓的像素保留灰度。

GUI 医学模式复用原有透明度滑块、更新按钮及 `MASK_TRANSP` 寄存器（字地址 `0x22`，AXI 字节地址 `0x88`）。数值 0 表示掩膜完全透明，100 表示实色；轮廓始终使用实色。设置在各读端的帧开始时锁存；HDMI 经已有配置 CDC 获取设置。

HDMI 和 PC 回传各实例化相同着色模块，两级 RGB 延迟保持不变。PC 仍是每像素一个 32 位 RGBA 字，不改变 DMA/TCP 帧大小。图像处理帧保留原有五种显示模式。

## 当前接入边界

生产顶层仍把 `medical_accel_top` 的输入置为空闲，等四腔分割结果接入。输出已经接通，但选择医学模式不会凭空生成图像；GUI 后端仍阻止此时启动无法完成的医学图像收发，透明度寄存器控制可用。

## 本地验证

在仓库根目录运行：

```bash
python scripts/tests/run_display_checks.py --out build/tests/medical_output --top tb_output_xbar --top tb_medical_colorizer --top tb_medical_output --top tb_medical_top --top tb_video_colorizer --top tb_independent_return --top tb_system_mode --top tb_hdmi_out --top tb_display_regs
```

- `tb_output_xbar`：双源仲裁、帧中模式变化、首尾像素反压。
- `tb_medical_colorizer`：四种颜色、全部灰度/透明度、轮廓优先、重叠优先级、视频控制对齐。
- `tb_medical_output`：实际医学模块及输出 xbar，图像/医学帧交替写入，两读口、完整 RGBA 包、长停顿、HDMI 开关。
- `tb_medical_top`：仅在仿真中向医学输出寄存器注入激励，验证真实 `top1` 到 HDMI 和 PC 的完整 65,536 像素连线；不改变生产顶层输入。

这些验证不运行综合，也不访问开发板。新增缓存位宽的实际资源占用和时序以 Vivado 实现报告为准。

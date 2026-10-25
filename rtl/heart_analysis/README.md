# 四腔逐帧容积、心动周期与 GUI 曲线

## 实际链路

```text
配准 → U-Net → medical_accel_top → 输出仲裁 → 双帧缓存 → HDMI / S2MM → TCP
                     ↓ 四腔逐帧容积、序号
                 AXI-Lite → PS medical_metrics.c
                             ↓ EDV/ESV、LV/RV EF、周期、心率
                        每帧 TCP 元数据 → Python 50 帧历史 → GUI
```

PL 只计算逐帧四腔容积。ED/ES 检测、EF、心动周期和心率均在 PS 中计算。
`ed_es_tracker.v` 留作独立旧版 RTL 测试参考，生产顶层不再实例化它。
原 `volume_calc.v`、`medical_axi_lite.v` 等旧模块也不在实际实例链路中。

## 几何估算与数据格式

每行从掩膜首个有效像素到末个有效像素取跨度 `w[y]`，空行取 0。
以单位间距圆盘估算：`V_px3 = π/4 × Σ w[y]²`。
RTL 寄存器保存 `round(V_px3 × 100)`，使用常数 `5147185 / 65536` 计算。
这是单视角纵向切片的工程几何估算，未做标准双平面临床容积测量；尺度系数不能修正几何模型误差。
分离区域会按首末点之间的整条跨度计入；轮廓只透传，计算使用填充掩膜。

按用户设定，CAMUS/CardiacUDA 共用假设像素面积 `0.436280886141 mm²`。
假设等距正方形像素，边长约 `0.6605156214 mm`，PS 容积系数为
`PL_VOLUME_ML_COEFF=0.00028817034062347113 mL/px³`，即边长³/1000。
它不是逐视频物理标定结果，GUI 明确显示“按 CAMUS 像素尺度估算”。
PS 结果以 mL×100、百分比×100 传输，GUI 保留两位小数。
`0xffffffff` 表示无有效结果；空掩膜、畸形帧及饱和值不会作为有效体积参与检测。

## PL 接口和只读寄存器

`in_data` 和四个 mask/四个 contour 原样输出，通过一拍弹性寄存器支持反压。
只在 `in_valid && in_ready` 时统计像素。EOF 是帧尾，暂停时数据和标志保持。
计算只做逐行流水运算，不增设整帧存储，无反压时每拍一个像素。
帧尾后的短计算流水排空后，同时发布四个容积、状态和递增序号。

基址 `0x44000000`；WORD 编号需左移两位转换成 AXI 字节偏移：

| WORD | 字节偏移 | 名称 | 内容 |
| --- | --- | --- | --- |
| 0x10 | 0x40 | VOLUME_LA | 本帧左心房 px³×100 |
| 0x11 | 0x44 | VOLUME_RA | 本帧右心房 px³×100 |
| 0x12 | 0x48 | VOLUME_LV | 本帧左心室 px³×100 |
| 0x13 | 0x4C | VOLUME_RV | 本帧右心室 px³×100 |
| 0x14 | 0x50 | VOLUME_SEQ | 完成帧序号，复位为 0 |
| 0x15 | 0x54 | VOLUME_STATUS | bit0 帧长正确，bit1..4 对应四腔有效 |
| 0x16 | 0x58 | MEDICAL_ABI | 固定 `0x564F4C31`，即 VOL1 |

这些地址只读，写入返回 SLVERR。旧 EDV/ESV 硬件寄存器映射已替换；PS 会检查 ABI，
因此本次升级必须同时重新生成位流和 ELF。PS 用 SEQ 前后夹读保证四个容积来自同一帧。
一个完成帧只推进一次分析；模式重绘、重复 UART `R`、重复读取不会增加历史点。

## PS 检测

实现位置：`csrc/MID_plt/src/medical_metrics.c`。

- 用 LV 容积的三点中值判断转向；原始帧容积用于实际 ED/ES 测量。
- 平滑造成相等峰谷平台时，保留平台内原始 LV 最大/最小值及其整帧四腔快照。
- 先观察上升段，再确认峰后的下降和谷后的上升；转向需要连续两点及约 1/32 幅度变化。
- ED/ES 默认至少间隔 5 帧，超时 240 帧重建候选；不使用复位后的全局最大/最小值。
- 四腔使用同一 LV ED/ES 时相。LA/RA 显示“ED/ES 时相容积”，不是心房自身独立极值。
- `EF = (EDV-ESV)/EDV × 100%` 在原始体积上计算，避免 mL 舍入误差；EDV=0 或 ESV>EDV 时无结果。
- 相邻有效 ED 帧的间隔得到周期帧数；识别两个周期后才发布周期/心率。
- `周期秒数 = 周期帧数 × 源帧间隔`，`BPM = 60 / 周期秒数`。
- GUI 源 FPS 滑块为 1–100，默认 30。它描述原视频采样，不使用处理速度或网络等待时间计算心率。
- 新流清空分析；文件夹回到首帧时清空时相候选并递增 epoch，不跨尾帧/首帧拼接周期。
- 无效 LV 中断未完成配对。静态图或只有 ED/ES 两张静态图的目录不会产生可靠心率。

## 传输和曲线

连续流 HELLO 的 extra 携带源帧间隔（微秒），固件 capability=7。
PIPE_UPLOAD extra 的低 3 位是显示模式，bit8 表示源序列从首帧重新开始；其余位必须为零。
UART `F` 加一个 FPS 字节可更新源帧率。运行中 GUI 暂停派发、排空在途帧后更新，再继续。
`R` 只回读缓存的 PS 分析结果，不推进检测。

TCP 元数据 v7 共 160 字节，全部网络字节序，与 RGBA 图像共同计算 CRC：

- 前 104 字节兼容 v6 结构，EDV/ESV 和 EF 现在来自 PS。
- 后 14 个 uint32：PL 序号、状态、分析帧号、源帧间隔、周期帧数、周期微秒、BPM×100、
  ED 帧号、ES 帧号、epoch、四腔当前 mL×100。
- Python 继续接受旧 v4/v5/v6 返回格式，但旧固件没有逐帧曲线字段。

Python 在每个 TCP 结果完成时、预览队列淘汰旧图之前，维护最多 50 个容积点。
每个 GUI 结果都携带完整的最近 50 点，所以浏览器跳过显示帧不会丢掉已经接收的曲线记录。
图像和医学数值/曲线在同一次绘制回调中更新；原流和输出流的数据仍可继续独立传输。
四条 SVG 条带使用 LA 红、RA 黄、LV 绿、RV 蓝，展示当前容积、范围和 ED/ES 标记；
空掩膜处断线，跨 epoch 不连线。超过 50 点从左侧移除最旧点，换流重新开始。
单图模式继续保存结果文件，流模式仍在内存中处理。

## 本地验证

```bash
python scripts/tests/run_firmware_network_checks.py
python -m unittest discover -s network/host -p 'test_*.py'
python scripts/tests/run_display_checks.py --out build/tests/cardiac_curves \
  --top tb_medical_volumes --top tb_medical_stream --top tb_display_regs \
  --top tb_medical_top --top tb_system_mode
```

测试覆盖独立几何参考、畸形/空帧、握手与读回、PS 周期检测和 FPS 换算、重复帧、循环边界、
TCP 元数据及 CRC、预览丢帧后仍完整保留最近 50 点、实际 GUI 绘图与状态处理函数。
本地测试通过不等于完成新位流的综合、时序收敛或上板验证。

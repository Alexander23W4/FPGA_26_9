# Cardiac patient 的离线分割缓存与流分析

## 目的

完整 FP32 U-Net 当前不适合实时视频处理。此流程把耗时分割预先跑完，并在 PC 上保存每帧的注册灰度、四腔掩膜和轮廓。之后可以多次启动流分析，不再运行配准或 U-Net。

这是应用级结果缓存：图像从 GUI/本机 Python 经 TCP 到板卡；结果从板卡经 PS/网口返回 Python，再由专用磁盘线程写入所选 patient 目录。**不是 PS 裸机直接写 PC 的 E 盘。**

## 操作流程

1. GUI 切到“医学分析模式”，通过“选择流文件夹”选 Cardiac 数据集，再选一个 patient 文件夹，例如 `Site_G_29/patient-2-4`。
2. 文件夹内的原始 256×256×8-bit `.bin` 按文件名排序。缓存子目录 `.heartcare_unet/` 会从原始帧列表排除。
3. 点击“U-Net 模型分割”。每个原始帧执行两次板端处理：
   - 第一遍：注册 → 完整 U-Net → 医学指标 → HDMI/回传；PC 保存返回的注册灰度和掩膜。
   - 第二遍：把注册灰度和掩膜送回 PL，跳过配准、U-Net 和指标计算，只运行 PL 四邻域 `mask_to_contour`；PC 保存掩膜和轮廓。
4. 每帧保存采用临时文件替换，`record.json` 最后提交。GUI 只有在 patient 的所有原图都通过文件长度、源图 SHA-256、缓存平面 SHA-256、预览 PNG SHA-256 和当前模型版本检查后，才显示绿色“已完成模型分割”。缺帧或校验失败显示红色“未完成模型分割”。
5. 绿色完成后，点击“开始流分析”。GUI 仍逐帧显示 patient 原图；发往 PL 的数据改为本地注册灰度 + 掩膜 + 轮廓。PL 直接运行医学指标、输出选择、双缓冲、HDMI 和 PC 回传，不再运行配准或 U-Net。轮廓/掩膜显示模式继续生效。

分割过程中若中断，重新选择同一 patient 后会校验磁盘上的已提交结果，只发送缺失、损坏或尚未完成的帧，进度从已完成数量继续；所有帧完成后不会重复跑。模型缓存键依据内容，不会仅因文件时间戳变化而失效，并兼容原有时间戳版本的有效记录。更改第一张参考原图、类别映射、权重、配准/U-Net/轮廓 RTL 或缓存 ABI 后，需要重新分割。

续跑时 PC 对未完成帧执行与 `registration_ddr.cpp` 相同的整数 SAD 搜索（首帧中心 48×48 ROI、±8 像素、相同平局规则），仍使用患者原来的第一帧作为参考。每张已对齐帧标记为新的 PL 配准 epoch，使 PL 配准原样通过，然后继续原有 U-Net、指标、显示和两遍回传链路；不会为了恢复 PL 易失的参考缓存而重跑已经完成的 U-Net。

“清除分割结果”需要先在确认弹窗中确认患者名称。后端只删除当前 patient 的 `.heartcare_unet`，拒绝正在运行的流任务和链接到患者目录外的缓存；原始 BIN 保留。删除后灯变红，“开始流分析”禁用，需重新分割。

本机 HTTP 短暂断开会有限重试。输入入队按 session/sequence 幂等，响应丢失后的重试不会重复发送到板卡；即使最后一张预览响应丢失，后台完成计数仍能结束任务并刷新磁盘进度。Python 服务持续不可达时会显示具体失败接口，需恢复 GUI 服务后续跑。

## 缓存格式

数据放在所选 patient 目录下：

```text
patient-2-4/
  frame001.bin                         原始数据，不修改
  .heartcare_unet/
    frames/frame001.bin.gray.bin       注册后的 65,536 字节灰度帧
    frames/frame001.bin.mask.bin       四腔室 4-bit flags，65,536 字节
    frames/frame001.bin.contour.bin    四腔室 4-bit flags，65,536 字节
    frames/frame001.bin.mask_preview.png
    frames/frame001.bin.contour_preview.png
    frames/frame001.bin.record.json    完成提交及 SHA-256
```

mask/contour 的四个位依次代表 LA、RA、LV、RV，合法值为 `0,1,2,4,8`。轮廓必须是对应掩膜的子集。回传语义包每像素 4 字节 `[registered_gray, mask_flags, contour_flags, 255]`；复用缓存输入包每像素 3 字节 `[registered_gray, mask_flags, contour_flags]`。PNG 是本地浏览/完整性校验预览，流传输使用二进制平面，不依赖 PNG 编码。

模型缓存键涵盖原模型包、当前部署权重（若存在）、U-Net/CDC 顶层、HLS 源码指纹、配准核心和 wrapper、顶层连接、类别映射、缓存输入解码器、掩膜转轮廓实现；另对每个原始 `.bin` 校验 SHA-256。提交记录只有最后写入才算完成，旧文件存在本身不代表帧已分割。

## 通路控制与缓冲

- 医学寄存器 `MEDICAL_JOB` 为只读 ABI 配套的写控制字：0 完整医学链路；1 掩膜转轮廓专用；2 缓存图像直接进入医学指标链路。bit 8 请求返回语义数据。
- PL 输入解码 `medical_cache_input` 将三个输入字节还原成灰度、四腔掩膜、四腔轮廓，帧长按 65,536 像素管理，所有级间遵守 `valid/ready/eof`。
- 普通输入环不变；复用缓存图的 192 KiB 输入使用 DDR `0x21200000` 开始的独立 4 槽环，避免覆盖原图/回传环。
- PC 写缓存由单线程 executor 与收发通路并行。最多允许 4 帧未提交写任务；若磁盘错误或持续跟不上，会报告错误并停止，不静默丢帧或无限占内存。
- 流分析仍使用 GUI/Python 现有有界在途帧数和“最新待绘制结果替换旧结果”策略；这影响预览显示帧数，不修改 patient 的缓存内容。

## 构建和现场限制

新的 PL/PS 协议需要同时重建。医学分割还需将与 32 路程序 ID 对应的权重加载进 DDR：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f
UNET_WEIGHTS="$(cygpath -w build/unet/model/weights.bin)" bash scripts/flash_current.sh init
```

此流程的本机 GUI/TCP、PS 协议、缓存完整性、PL 输入解析/反压、掩膜轮廓和双帧显示连接已做本地验证。新版本尚未完成整工程 implementation 或上板验证；第一次分割耗时尚未测量。当前 U-Net 理论 MAC 下限约 0.659 秒/帧，实际会更慢；离线缓存只让后续分析不重复跑模型，不会让首次分割变快。

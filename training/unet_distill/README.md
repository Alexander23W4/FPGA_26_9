# 四腔 U-Net 蒸馏与小模型实验

## 本轮结论

已实际训练并验证多档学生。当前保留末端 16 通道的学生，完整灰度图测试的四腔平均 Dice 约 **0.806**，1 像素容差轮廓 F1 约 **0.546**（均相对原教师）。紧凑 FP32 权重约 **10.53 MB**，逐通道 INT8 权重约 **2.75 MB**。这个结果尚未满足“优先保住掩膜和轮廓质量”，**不建议替换上板**。

完整原网络的逐通道 INT8 权重对照为 **6,737,272 B**，相比原打包 FP32 的 26,457,792 B 缩小 **3.93 倍**。64 张测试帧相对原 FP32 的平均四腔 Dice = **0.982096**，1 像素容差轮廓 F1 = **0.984805**。这更符合本轮质量优先的要求，但它属于**权重量化，不是蒸馏或完整整数推理**：没有减少 MAC，激活仍为 FP32 反量化验证，没有测得板端加速，也不能直接用当前烧录脚本加载紧凑 INT8 文件。

结果在 `build/unet_distill/RESULTS.md` / `comparison.json`；各候选检查点、导出权重和预览保存在对应实验目录。当前 RTL、原模型权重和原 `ip` 保持不变。

重跑完整网络的权重 INT8 对照：

```bash
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/quantize_teacher.py
```

## 当前优先路线：质量优先

用户已选择“优先保住四腔掩膜和轮廓质量，再选最小模型”。极小网络的实测验证前景 Dice 只有约 0.14（4 通道）和 0.27（8 通道），并缺失部分腔室，**已停止，不能替换当前模型**。

因此新增 `decoder_student.py` / `train_decoder.py`：原训练编码器全部保持不变，只压缩解码器并进行蒸馏。原编码器为 381,739,008 MAC，原解码器和输出头为 2,991,587,328 MAC，主要压缩收益来自后者。教师权重用于初始化学生保留的解码器滤波器，编码器特征缓存一次即可反复训练。

| 解码器通道 | 总 MAC/帧 | 相对原模型计算量减少 | FP32 参数/冻结值本体估算 |
|---|---:|---:|---:|
| 16,8,8,8,8 | 585,818,112 | 5.76 倍 | 9,670,452 B |
| 32,16,8,8,8 | 648,339,456 | 5.20 倍 | 10,523,316 B |
| 32,16,8,8,16（保留末端通道） | 822,927,360 | 4.10 倍 | 10,534,100 B |

这两档需要根据验证集掩膜 Dice、测试集四个腔室的 Dice 和轮廓 F1 决定是否足够接近教师。保存模型也不等于质量已达标。

质量优先的训练/导出命令（Git Bash，仓库根目录）：

```bash
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/train_decoder.py --base 32 --epochs 40 --out build/unet_distill/my_decoder32
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/export_decoder.py --checkpoint build/unet_distill/my_decoder32/best.pt --out build/unet_distill/my_decoder32/export
```

先运行下方的数据准备命令；训练脚本自动缓存编码器特征（FP16 保存，FP32 训练）。验证检查点在缓存特征上选择；导出会从真实灰度图重新运行整个编码器和解码器，验证完整图像推理。

有 CUDA 的训练机可以给 `train_decoder.py` 加 `--device cuda`。原始训练数据没有上传到外部服务。

为了保留原轮廓，还加入了 **16 通道末级特征蒸馏** 和边界附近的额外交叉熵权重。该分支保持原分割头不变，以教师末端特征作为额外目标，训练代码可用：

```bash
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/train_decoder.py --base 32 --detail-width 16 --hint-weight 1 --boundary-weight 2 --epochs 40 --out build/unet_distill/my_quality_student
```

`--initialize 另一个学生的best.pt` 可以继承形状一致的参数，形状不同的层保留教师初始化。“冻结原分割头”适用于末端仍为 16 通道的特征蒸馏分支。

导出还包含：

- 完整编码器和学生解码器的紧凑 FP32/INT8 权重，而不是只导出解码器。
- `fp32_hls/model.json`、`weights.bin`、`model_ops.h`：与已有通用 HLS 算子匹配的学生图，已重新计算跳跃连接、DDR 存活期与模型 ID。由独立 NumPy 解释器与训练模型核对。
- `verification.json`：完整输入下的逐腔掩膜 Dice，以及 **1 像素容差的轮廓 F1**；同时报告 INT8 权重反量化推理结果。

**没有自动把学生程序写入现有 `rtl/unet/hls/model_ops.h`，没有重跑板端 HLS，也没有烧录。** 真正部署学生需要切换模型程序、重新生成 HLS RTL、综合，并使用对应的权重文件；当前已验证的位流保持原模型。

## 做了什么

使用原始 MobileNetV2 U-Net 作为固定教师，训练更小的深度可分离 U-Net。输入仍是 **256×256×8-bit 灰度**，输出仍为原编号的五类分数：背景和四个腔室。掩膜由 argmax 生成，轮廓仍可由已有四邻域模块生成。

这里的模型和产物独立保存，**不会替换 `rtl/unet` 的当前完整模型或修改 `ip`**。小模型的拓扑、权重格式与当前 HLS 程序不同，不能把小模型 BIN 直接传给 `UNET_WEIGHTS` 烧录。

## 学生网络

四级编码器、跳跃连接、最近邻上采样、深度卷积加 1×1 卷积、BatchNorm/ReLU6，以及全分辨率细化输出。网络不依赖 GPU 特有算子，便于后续实现 INT8 RTL。

| 基础通道数 | 训练参数数 | FP32 参数本体 | 每帧 MAC | 相对原模型计算量减少 |
|---|---:|---:|---:|---:|
| 2 | 2,196 | 8,784 B | 7,006,208 | 约 481 倍 |
| 4 | 6,072 | 24,288 B | 16,240,640 | 约 208 倍 |
| 8 | 18,912 | 75,648 B | 43,163,648 | 约 78 倍 |
| 原模型 | 约 660 万 | 当前打包文件 26,457,792 B | 3,373,326,336 | — |

参数本体不包含 checkpoint 的描述信息；最终导出大小以 `export/model.json` 为准。减少通道不会自动保留分割能力，必须结合 `report.json` 选择。

**这些不是板端 FPS。** 当前 16 路 FP32、80 MHz 的纯算术下限，4 通道约 12.69 ms，8 通道约 33.72 ms；DDR、低通道数时的并行利用率、配准、网络、GUI 等开销都还没计入。INT8 需要新的整数引擎、量化误差验证和上板测量，不能据此保证最终 30 FPS。

## 数据和类别

- 输入源为 `E:/cardiarc_extract/cardiacUDC_dataset`，读取 NIfTI 原始序列；不修改数据集。
- 与现有 GUI 转换一致：`x,y,frame → 转置、y 翻转 → Lanczos 等比例缩放与补边 → /255`。
- 同一数字病人 ID 的不同站点、视图和 `patient1`/`patient-1` 拼写均归入同一分区；跨站点同名文件保留为不同采集。
- 教师输出缓存为 FP16 logits，训练时转回 FP32。源权重 SHA256 和预处理参数记入缓存配置。
- 默认使用教师软标签 KL、平衡类别交叉熵、前景 Dice 进行蒸馏；训练时 80% 概率采样含前景的 128×128 patch。**验证、测试始终使用完整 256×256 帧**。
- 类别暂沿用教师：`0 背景，1 LA，2 RA，3 LV，4 RV`，解剖对应尚待确认。
- 原数据集标注编号与教师不一定一致。`label_audit.json` 只给出训练集上的对应关系线索，**不会自动拿这个推测去训练**。全零的稀疏标注帧作为“没有标注”处理。
- `--label-map` 只有在核实原始标注对应关系后才启用，可额外加入真实标注 CE/Dice。例如 `--label-map 0,3,1,2,4` 表示原始 1→教师3、2→教师1、3→教师2、4→教师4；示例不代表当前数据的已确认映射。

## 指标怎么读

`report.json` 的 `teacher.mean_foreground_dice` 是四个前景类别分别计算后取平均，表示**学生与教师的一致性**。不会用背景占比很高的像素准确率冒充分割效果。检查点由验证病人的 Dice 选取，测试病人不参与训练或选检查点。

这不代表相对于医生标注的准确性。没有原教师训练清单，也不能声称测试患者对教师训练完全独立。真实分割质量还需确认标签编号、使用更多患者和标注评估。

## 本机环境

已发现 `E:/PythonVersionEnv/Python3.14.0/python.exe` 自带 `torch 2.9.1+cpu`，以及 NumPy、Pillow。本轮使用 CPU，没有安装其他全局依赖。其他机器需要 PyTorch、NumPy、Pillow，安装可参考 [PyTorch 官方说明](https://pytorch.org/get-started/locally/)。蒸馏软标签思想见 [Hinton 等人的论文](https://arxiv.org/abs/1503.02531)。

## Git Bash 操作

在仓库根目录执行。这里是本轮的小规模实验配置：24 个训练病人组、6 个验证组、6 个测试组，每个序列均匀抽 4 帧（实际多采集累计 260/60/64 帧）。

### 1. 缓存教师结果

```bash
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/prepare.py --train-patients 24 --val-patients 6 --test-patients 6 --frames 4
```

已有相同配置时直接复用缓存。改变配置要指定不同的 `--out`，不会默默混用已有缓存。患者分组在 `build/unet_distill/cache_patient/patients.json`，样本清单在同目录 `samples.json`。

### 2. 训练

```bash
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/train.py --width 4 --epochs 60 --threads 2 --out build/unet_distill/my_w4
```

`--width 2/4/8/12/16` 决定大小。CPU 推荐先用 2～4 个线程；有 CUDA 时可用 `--device cuda`。`best.pt` 为验证最优模型，`last.pt` 含优化器状态。增加 `--resume` 从 last 继续训练，`--epochs` 表示本次额外轮数。要结束训练并导出本次最佳结果，可在输出目录创建名为 `STOP` 的空文件，程序会在本轮结束后保存报告并退出；恢复前移除 STOP。

### 3. 导出并检查权重量化

```bash
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/export.py --checkpoint build/unet_distill/my_w4/best.pt --out build/unet_distill/my_w4/export
```

产物：

- `student.pt`：去掉优化器的 PyTorch 模型。
- `weights_fp32.bin`：BatchNorm 折叠后的 FP32 卷积权重和偏置。
- `weights_int8.bin`：每输出通道对称 INT8 权重，附 FP32 scale/bias。
- `model.json`：每层形状、偏移、文件 SHA256，以及完整 FX 运算图。
- `verification.json`：折叠误差、FP32/权重 INT8 的测试分割指标。
- `preview.png`：固定前四张测试图的输入、教师、学生、权重 INT8 对比，没有挑最好的样本。

当前 INT8 验证是**权重反量化后使用 FP32 激活推理**。尚未进行激活 INT8/QAT，也没有验证完整整数推理；后续接 RTL 时必须继续完成这部分。

### 4. 全量训练

使用新缓存目录，`--train-patients 0 --val-patients 0 --test-patients 0` 会使用全部分区，`--frames 8` 增加时相覆盖。随后训练命令通过 `--cache` 指向新目录。训练时间和磁盘占用会随样本增加。

## 局部正确性检查

```bash
/e/PythonVersionEnv/Python3.14.0/python.exe training/unet_distill/test_distillation.py
```

覆盖：完整教师与已有独立 NumPy 参考一致、跨站点患者分区无交叉、背景准确率不能掩盖缺失前景、梯度有效、BN 折叠以及 INT8 二进制权重读回正确。

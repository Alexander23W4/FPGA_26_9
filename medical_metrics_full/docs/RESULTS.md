# 已跑出的可复现结果

运行环境：Windows，NumPy bundled Python，当前工作目录 `work/medical_metrics`。

## 1. 单元测试

命令：

```powershell
C:\Users\13995\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe -m unittest -v test_golden_metrics.py test_rtl_model.py
```

结果：

```text
Ran 11 tests in about 0.18s
OK
```

覆盖：平移搜索、负向大位移、双线性插值、面积/容积、ED/ES 选择、GLS 方向、NIfTI 读写、真实 CAMUS 病例。

## 2. patient0001（4CH）

```text
frames: 20
spacing: 0.308 mm x 0.308 mm
ED frame: 0
ES frame: 19
EDV: 146.84 mL
ESV: 67.79 mL
EF: 53.83%
GLS surrogate: -24.95%
long-axis shortening: -35.11%
```

配准前几对（整数最优 dx_int/dy_int）：

```text
0->1: dx=0, dy=0, SAD=156178
1->2: dx=-1, dy=0, SAD=140461
2->3: dx=0, dy=0, SAD=125933
3->4: dx=-1, dy=0, SAD=127692
4->5: dx=-3, dy=1, SAD=130064
5->6: dx=-3, dy=2, SAD=129943
```

完整输出：`python/patient0001_metrics.json`。

## 3. official testing split 前 8 例

命令：

```powershell
python run_camus.py --split testing --limit 8 --registration-frames 2 `
  --out-csv testing_8.csv --summary-json testing_8_summary.json
```

结果：

```text
patients_requested: 8
patients_ok: 8
patients_failed: 0
EF mean: 37.44%  std: 19.01%
GLS surrogate mean: -12.41%  std: 6.79%
EDV mean: 150.87 mL  std: 67.76 mL
ESV mean: 98.66 mL  std: 56.78 mL
```

逐例：

```text
patient0027: EF=51.95% GLS=-21.95%
patient0047: EF=28.23% GLS=-11.38%
patient0051: EF=33.83% GLS=-12.44%
patient0052: EF=7.20%  GLS=-0.20%
patient0187: EF=41.79% GLS=-14.29%
patient0189: EF=68.31% GLS=-21.68%
patient0191: EF=15.71% GLS=-6.39%
patient0194: EF=52.47% GLS=-10.95%
```

这些数值只证明流程可执行，不代表临床精度。EF 分布偏低的可能原因：单平面 4CH area-length 近似、长轴用 bbox 高度、GT 掩膜包含乳头肌/边界定义差异、半序列帧选择。

## 4. 尚未跑出的结果

- RTL 综合资源、时序、功耗：当前机器没有 Vivado。
- xsim/iverilog 仿真：当前机器没有对应仿真器。
- ACZ7015 上板帧率/延迟：需要队友硬件环境。
- U-Net 自动掩膜精度：当前使用 CAMUS GT 掩膜。

## 5. official validation split 前 8 例

```text
patients_ok: 8 / 8
EF mean: 44.34%  std: 11.88%
GLS surrogate mean: -18.34%  std: 5.47%
EDV mean: 133.44 mL  std: 30.45 mL
ESV mean: 76.17 mL  std: 28.72 mL
```

完整输出：`python/validation_8.csv`、`python/validation_8_summary.json`。





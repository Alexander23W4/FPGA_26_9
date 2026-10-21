# 算法公式、定点化和边界说明

## 1. 连续帧配准

对上一帧 `P` 和当前帧 `C`，在中心 ROI 上做平移搜索：

```text
SAD(dx,dy) = sum_{(x,y) in ROI} |P(x,y) - C(x+dx, y+dy)|
(dx*,dy*) = argmin SAD(dx,dy)
```

搜索范围：`dx,dy ∈ [-8, +8]`，ROI 默认 48x48。整数最优后，用 3 点抛物线拟合：

```text
delta = 0.5 * (S(-1) - S(+1)) / (S(-1) - 2*S(0) + S(+1))
```

得到亚像素位移；双线性插值：

```text
I(x+u, y+v) =
  (1-u)(1-v) I(x,y)     + u(1-v) I(x+1,y)
+ (1-u)v     I(x,y+1)   + u v     I(x+1,y+1)
```

RTL 目前 `registration_top` 实现整数搜索；`rtl/bilinear_interp.v` 已提供 Q8 双线性插值核心，后续把亚像素偏移接到该模块即可作为 P1 扩展。

## 2. 面积和长轴

CAMUS GT 中 LV 腔标签为 `1`：

```text
A_px = count(mask == 1)
A_mm2 = A_px * sx * sy
L_px = last_row(mask) - first_row(mask) + 1
L_mm = L_px * sy
```

`L_px` 是 4CH 切面的纵向包围高度，属于工程近似，不是临床标准长轴测量。

## 3. EDV / ESV / LVEF

```text
V_mL = 8 * A_mm2^2 / (3*pi*L_mm) / 1000
EDV = max_t V(t)
ESV = min_t V(t)
LVEF = (EDV - ESV) / EDV * 100%
```

当前实现用最大/最小面积选 ED/ES，再计算对应容积。对于帧数较少的半序列，这等价于最大/最小容积（长轴同向变化时）。

## 4. 简化 GLS

Python 黄金模型使用心内膜左右边界路径长度：

```text
L_ED_side, L_ES_side = 每行 mask 最小/最大 x 连成的路径长度
epsilon_side = (L_ES_side - L_ED_side) / L_ED_side * 100%
GLS_surrogate = mean(epsilon_left, epsilon_right)
```

RTL 使用更省资源的纵向长轴应变：

```text
epsilon_L = (L_ES - L_ED) / L_ED * 100%
```

两者都写成 `strain surrogate`，不能和临床 speckle-tracking GLS 等同。

## 5. Q16.16 定点

`volume_q16` 和 `strain_q16` 都是 signed/unsigned Q16.16：

```text
float_value = q16 / 65536.0
```

容积 RTL 使用 Q8 面积/长度：

```text
A_q8 = A_px * pixel_area_q8
L_q8 = L_px * spacing_y_q8
V_q16 = (A_q8^2 << 16) / (96000 * pi * L_q8)
```

CAMUS 默认参数：

```text
sx = sy = 0.308 mm
pixel_area_q8 = round(0.308^2 * 256) = 24
spacing_y_q8  = round(0.308 * 256) = 79
```

`96000*pi` 取 `301593`。定点误差主要来自 Q8 的间距量化，约 1% 量级；临床级测量需要更高精度或 PS 端浮点后处理。

## 6. 结果解释

- `patient0001` 的 EF 约 53.8%、简化 GLS 约 -24.95%，与“正常/接近正常 LVEF”量级相符，但这只是一个病例。
- 8 例 testing 子集的平均 EF 约 37.4%，说明该简化面积-长度公式和 4CH 单平面假设偏差较大，不能当临床 EF 使用。
- 竞赛里应把“算法链路可复现”和“临床精度”分开表述。


# `scripts/` —— 构建与自动化

> 入口只有一个：`./scripts/build.sh`
> 环境：**Git Bash**（不要用 CMD / PowerShell 跑这些脚本）

---

## 目录

```
scripts/
├── build.sh              ← 唯一入口
├── env_check.sh          环境自检
├── lib/common.sh         公共函数库（被上面两个 source）
├── tcl/                  执行层：在 Vivado 内跑
│   ├── create_pl_project.tcl     只建纯 PL 工程（不开综合，给 GUI 用）
│   ├── create_zynq_project.tcl   只建 Zynq 工程 + BD
│   ├── build_pl.tcl              建/开工程 → 综合 → 实现 → 位流
│   ├── build_zynq.tcl            建/开工程 → 位流 → 导出 .xsa
│   ├── run_sim.tcl               xsim 仿真
│   ├── export_project.tcl        把 GUI 改动导回 Tcl
│   └── register_board.tcl        注册 ACZ7015 板卡库
└── xsct/                 执行层：在 xsct 内跑（PS 端）
    └── build_app.tcl             .xsa → platform → application → .elf
```

---

## 为什么是 bash + Tcl，不是 Makefile

分两层看：

| 层 | 用什么 | 能不能换 |
|---|---|---|
| **执行层**<br>综合/实现/位流/write_xsa | **Tcl** | ❌ 唯一接口 |
| **编排层**<br>启动、传参、校验、归档 | **bash** | ✅ 可换 make，但没必要 |

不用 make 的三个理由：

1. **你机器上没有 make**（Git for Windows 不带），装它只为做一层薄编排，性价比低
2. **Vivado 工程自己已经做了增量**（`.runs/`、`.dcp`）。外层再维护依赖图是重复劳动，还会和 Vivado 缓存状态打架 —— 你手工在 GUI 改了 IP 配置，make 的依赖图并不知道
3. Vivado 是**分钟级**构建，增量判断省的时间抵不过依赖图出错的麻烦

bash 还能做 make 做不了的事：版本戳、产物按 `时间_githash` 归档、写 `MANIFEST.txt`、失败自动收日志、PL+PS 一条链串起来。

> 真到了多目标 CI 矩阵那天，再加个 Makefile 包一层即可 —— 直接调 `build.sh`，不会返工。

---

## 目录约定

```
build/                      ← 全部 gitignore
├── vivado/<工程名>/            Vivado 工程
├── vitis/                      Vitis 工作区
└── out/<日期>_<时间>_<githash>/
    ├── *.bit  *.xsa  *.elf      产物
    ├── build.log                完整日志
    └── MANIFEST.txt             器件/工具版本/git hash/参数，可追溯
```

`MANIFEST.txt` 是关键 —— 以后板子上跑的东西对不上代码，一查就知道是哪次构建的。

---

## 用法

```bash
./scripts/build.sh check                          # 环境自检

./scripts/build.sh pl   -n led_demo -t led_flash  # 纯 PL 全流程
./scripts/build.sh zynq -n zynq_led -a            # Zynq 全流程（带 AXI）
./scripts/build.sh app  -n zynq_app               # PS 端应用
./scripts/build.sh all  -n zynq_led -a            # PL + PS 全流程

./scripts/build.sh sim  -n led_demo -b tb_video   # 仿真
./scripts/build.sh export -n zynq_led             # GUI 改动导回 Tcl
./scripts/build.sh clean                          # 清理 build/
```

### 选项

| 选项 | 说明 |
|---|---|
| `-n, --name NAME` | 工程名（必需） |
| `-a, --axi` | Zynq 工程带 AXI 基础设施 + LED GPIO |
| `-t, --top TOP` | 纯 PL 顶层模块名 |
| `-b, --tb TB` | 仿真测试平台顶层名 |
| `-j, --jobs N` | 综合/实现并行数（默认 4） |

### 工具装在别处

```bash
XILINX_ROOT=/d/Xilinx VIVADO_VER=2023.2 ./scripts/build.sh check
```

---

## 工程是不入库的 —— 工作流长什么样

`.gitignore` 挡掉了 `build/**`。所以：

**纯命令行开发（推荐）**
```bash
# 改 rtl/ 下的源码
vim rtl/video/tmds_encoder.sv
./scripts/build.sh pl -n led_demo -t led_flash
# 产物自动归档到 build/out/<时间戳>_<hash>/
```

**需要 GUI 时**
```bash
# 1. 先把工程建出来
./scripts/build.sh pl -n led_demo -t led_flash     # 或 create_pl_project.tcl

# 2. 用 GUI 打开改
vivado build/vivado/led_demo/led_demo.xpr

# 3. 改完把状态导回 Tcl 并提交
./scripts/build.sh export -n led_demo
git add scripts/exported/ && git commit -m "..."
```

这样 `build/` 里是随手可删的生成物，`scripts/exported/` 里是能完整重建工程的 Tcl。

---

## ⚠️ 注意事项

1. **必须 LF 换行**，CRLF 会让 Git Bash 报 `$'\r': command not found`。
   `.gitattributes` 已强制，`env_check.sh` 也会自检并提示。

2. **不要用 PowerShell 跑 build.sh**。`env_check.sh` 内部只在查询
   Windows 设备/驱动/磁盘时才调用 `powershell.exe`。

3. **`source` 而不是 `sh`**：`lib/common.sh` 用了 bash 数组和 `$BASH_SOURCE`，
   `sh`(dash) 不兼容。用 `./scripts/build.sh` 或 `bash scripts/build.sh`。

4. **Vivado 的 `-tclargs` 只传字符串**，路径里的反斜杠交给 `cygpath -w` 转换，
   `lib/common.sh` 里的 `winpath()` 已处理。

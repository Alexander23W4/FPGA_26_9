#!/usr/bin/env python3
# =============================================================================
#  build_ps.py —— Vitis Unified IDE：建 platform + application 并编译
# =============================================================================
#  调用方式（由 scripts/build.sh app 自动调用）：
#      vitis -s scripts/vitis/build_ps.py <应用名> <xsa路径> <工作区路径>
#
#  Git Bash 里手工调用：
#      /e/Xilinx/Vitis/2023.2/bin/vitis.bat -s "$(cygpath -w scripts/vitis/build_ps.py)" \
#          my_app "$(cygpath -w build/out/xxx/my.xsa)" "$(cygpath -w build/vitis)"
#
#  说明：
#    · 本脚本运行在 Vitis 自带的 Python 3.8.3 下（由 vitis.bat 设置）
#    · 所有【输出到终端】的文字为英文；【注释】可中文
#    · Unified IDE 的脚本接口是 `vitis -s <python>`，不是 xsct
# =============================================================================

import os
import sys

# ------------------------------- 参数 ----------------------------------------
if len(sys.argv) < 4:
    print("!!!ARGS!!! build_ps.py requires: <appname> <xsa> <workspace>")
    sys.exit(1)

app_name = sys.argv[1]
xsa = sys.argv[2]
workspace = sys.argv[3]

if not os.path.isfile(xsa):
    print("!!!NOXSA!!! hardware platform not found: " + xsa)
    sys.exit(1)

# ------------------------------ 导入 vitis -----------------------------------
try:
    import vitis
except ImportError:
    print("!!!NOVITIS!!! cannot import 'vitis'.")
    print("              This script must be run via: vitis -s <script.py>")
    sys.exit(1)

# --------------------------- 板级常量（Zynq-7000）----------------------------
CPU = "ps7_cortexa9_0"
OS_TYPE = "standalone"
DOMAIN = "standalone_" + CPU

platform_name = app_name + "_platform"

print("=" * 62)
print(" [build_ps] application : " + app_name)
print(" [build_ps] platform    : " + platform_name)
print(" [build_ps] xsa         : " + xsa)
print(" [build_ps] workspace   : " + workspace)
print(" [build_ps] cpu / os    : " + CPU + " / " + OS_TYPE)
print("=" * 62)

# ------------------------------ 创建 client ----------------------------------
try:
    client = vitis.create_client()
    client.set_workspace(workspace)
except Exception as exc:
    print("!!!CLIENT_FAILED!!! " + str(exc))
    sys.exit(1)

# ------------------------------ Platform -------------------------------------
platform = None
try:
    platform = client.get_platform(platform_name)
except Exception:
    platform = None

if platform is not None:
    print("[build_ps] Reusing existing platform: " + platform_name)
else:
    print("[build_ps] Creating platform: " + platform_name)
    try:
        platform = client.create_platform_component(
            name=platform_name,
            hw=xsa,
            cpu=CPU,
            os=OS_TYPE,
            domain_name=DOMAIN,
        )
    except Exception as exc:
        print("!!!PLATFORM_FAILED!!! " + str(exc))
        sys.exit(1)

print("[build_ps] Building platform ...")
try:
    platform.build()
except Exception as exc:
    print("!!!PLATFORM_BUILD_FAILED!!! " + str(exc))
    sys.exit(1)
print("[build_ps] Platform build done")

# ---------------------------- Application ------------------------------------
try:
    platform_xpfm = client.get_platform(platform_name)
except Exception as exc:
    print("!!!NOXPFM!!! " + str(exc))
    sys.exit(1)

app = None
try:
    app = client.get_component(app_name)
except Exception:
    app = None

if app is not None:
    print("[build_ps] Reusing existing application: " + app_name)
else:
    print("[build_ps] Creating application: " + app_name)
    try:
        app = client.create_app_component(
            name=app_name,
            platform=platform_xpfm,
            domain=DOMAIN,
            template="empty",
        )
    except Exception as exc:
        print("!!!APP_FAILED!!! " + str(exc))
        sys.exit(1)

print("[build_ps] Building application ...")
try:
    app.build()
except Exception as exc:
    print("!!!APP_BUILD_FAILED!!! " + str(exc))
    sys.exit(1)
print("[build_ps] Application build done")

# ------------------------------- 找 .elf -------------------------------------
elvs = []
for root, _dirs, files in os.walk(workspace):
    for fn in files:
        if fn.endswith(".elf"):
            elvs.append(os.path.join(root, fn))

for p in elvs:
    print("ELF=" + p)
if not elvs:
    print("WARNING: no .elf produced")

# ------------------------------- 收尾 ----------------------------------------
try:
    vitis.dispose()
except Exception:
    pass

print("BUILD_PS_OK")

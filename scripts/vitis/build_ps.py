#!/usr/bin/env python3
# =============================================================================
#  build_ps.py —— Vitis Unified IDE：建/复用 platform，然后建 application
# =============================================================================
#  调用方式（由 scripts/build.sh app 自动调用）：
#      vitis -s scripts/vitis/build_ps.py <应用名> <xsa> <工作区> [平台名] [--force-platform]
#
#  工作区布局（<工作区> = 仓库里的 csrc/）：
#      csrc/<平台名>/                平台 + BSP + FSBL，纯生成物
#      csrc/<应用名>/src/            ★ 你的 C 源码，会被 git 跟踪
#      两个组件目录都由本脚本自动创建
#
#  参数：
#      <应用名>            必填，应用组件名
#      <xsa>               必填，硬件平台路径
#      <工作区>            必填，Vitis 工作区
#      [平台名]            选填，默认是 build.sh 传进来的硬件工程名
#                          ★ 想让多个应用共用同一个平台，就显式指定它
#                          ★ 平台名和应用名是工作区里的同一层目录，
#                            所以两者同名时本脚本直接报错退出，绝不偷偷改名
#      [--force-platform]  选填，强制重新编译平台（默认平台已建好就跳过）
#
#  行为：
#      · 平台不存在        -> 建 + 编译
#      · 平台已存在且已编译 -> 【跳过平台编译】，只建应用
#      · 平台已存在但没编译 -> 编译
#      · 加 --force-platform -> 无论如何都重新编译平台
#
#  ★ 组件目录是否存在的判断，一律以 vitis-comp.json 为准，不用 client 缓存：
#      - client.get_platform() 查的是已安装的平台仓库，看不到刚建好的平台
#      - csrc/<应用名>/ 可能因为 git 跟踪了 src/ 而提前存在，那时还没有组件描述文件
#        这种情况下会先把目录挪到 .userbak，建完组件再把内容合并回来，避免覆盖源码
#
#  说明：本脚本运行在 Vitis 自带的 Python 3.8.3 下。
#        所有【输出到终端】的文字为英文；【注释】可中文。
# =============================================================================

import os
import shutil
import sys

# ------------------------------- 参数 ----------------------------------------
if len(sys.argv) < 4:
    print("!!!ARGS!!! build_ps.py requires: <appname> <xsa> <workspace> [platform] [--force-platform]")
    sys.exit(1)

app_name = sys.argv[1]
xsa = sys.argv[2]
workspace = sys.argv[3]

platform_name = None
force_platform = False
for a in sys.argv[4:]:
    if a in ("-f", "--force-platform"):
        force_platform = True
    elif a.strip():
        platform_name = a

if not platform_name:
    platform_name = app_name

# 平台组件和应用组件在 Vitis 工作区里是同一层的目录，同名会互相覆盖，
# 所以这里直接报错，而不是自作主张给谁加后缀。
if platform_name == app_name:
    print("!!!NAMECLASH!!! platform name and application name are identical: " + app_name)
    print("               They would occupy the same directory in the Vitis workspace.")
    print("               Fix: pass a different platform name, e.g.")
    print("                    ./scripts/build.sh app -n " + app_name + " -p <platform_name>")
    sys.exit(1)

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

# 有效模板名（本机 Vitis 2023.2 实测）
#   empty_application  hello_world  dhrystone  memory_tests  peripheral_tests
#   lwip_*  rsa_auth_app  zynq_dram_test  zynq_fsbl
# 注意：官方示例里写的 "empty" 在这个版本里无效
TEMPLATE = "empty_application"

print("=" * 62)
print(" [build_ps] application : " + app_name)
print(" [build_ps] platform    : " + platform_name)
print(" [build_ps] xsa         : " + xsa)
print(" [build_ps] workspace   : " + workspace)
print(" [build_ps] cpu / os    : " + CPU + " / " + OS_TYPE)
print(" [build_ps] force build : " + ("yes" if force_platform else "no"))
print("=" * 62)

# ------------------------------ 创建 client ----------------------------------
try:
    client = vitis.create_client()
    client.set_workspace(workspace)
except Exception as exc:
    print("!!!CLIENT_FAILED!!! " + str(exc))
    sys.exit(1)


def find_xpfm(name):
    """在工作区里找平台的 xpfm。

    ★ 不用 client.get_platform()：client 的组件表是在建平台【之前】建立的，
       build() 完之后它并没有刷新，查不到刚编好的平台，会误报 NOXPFM。
       直接读磁盘最稳。
    """
    # 1) 标准导出路径
    direct = os.path.join(workspace, name, "export", name, name + ".xpfm")
    if os.path.isfile(direct):
        return direct

    # 2) 该组件的 export/ 下随便找一个
    base = os.path.join(workspace, name, "export")
    if os.path.isdir(base):
        for root, _dirs, files in os.walk(base):
            for fn in sorted(files):
                if fn.endswith(".xpfm"):
                    return os.path.join(root, fn)

    # 3) 兜底：整个工作区
    for root, _dirs, files in os.walk(workspace):
        for fn in sorted(files):
            if fn.endswith(".xpfm"):
                return os.path.join(root, fn)

    return None


def has_component(comp_dir):
    """这个目录里是不是一个真正的 Vitis 组件？
    ★ 只看目录存不存在是不够的：csrc/<应用名>/ 可能因为 git 跟踪了源码而
      提前存在（刚 clone 下来的情况），那种目录里没有 vitis-comp.json。
    """
    return os.path.isfile(os.path.join(comp_dir, "vitis-comp.json"))


def stash_dir(comp_dir):
    """建组件前先把同名目录挪开（否则 create 可能失败，或者覆盖你的 main.c）"""
    if not os.path.isdir(comp_dir):
        return None
    stash = comp_dir + ".userbak"
    if os.path.isdir(stash):
        shutil.rmtree(stash, ignore_errors=True)
    shutil.move(comp_dir, stash)
    print("[build_ps] moved existing dir aside: " + comp_dir)
    return stash


def restore_dir(stash, comp_dir):
    """组件建好之后，把备份里的内容合并回来（用户文件优先），再删掉备份"""
    if not stash or not os.path.isdir(stash):
        return
    for root, _dirs, files in os.walk(stash):
        rel = os.path.relpath(root, stash)
        dst_dir = comp_dir if rel == "." else os.path.join(comp_dir, rel)
        if not os.path.isdir(dst_dir):
            os.makedirs(dst_dir)
        for fn in files:
            dst = os.path.join(dst_dir, fn)
            if not os.path.isfile(dst):     # 不覆盖 Vitis 生成的文件
                shutil.copy2(os.path.join(root, fn), dst)
                print("[build_ps] restored: " + os.path.relpath(dst, workspace))
    shutil.rmtree(stash, ignore_errors=True)


# ------------------------------ Platform -------------------------------------
# 组件是否存在，以 vitis-comp.json 为准，不依赖 client 的缓存
platform_dir = os.path.join(workspace, platform_name)
platform_exists = has_component(platform_dir)

if platform_exists:
    print("[build_ps] Platform exists: " + platform_name)
    if find_xpfm(platform_name) and not force_platform:
        print("[build_ps] Platform already built -- SKIPPING platform build")
    else:
        print("[build_ps] Building platform ...")
        platform_obj = client.get_platform_component(platform_name)
        if platform_obj is None:
            print("!!!PLATFORM_FAILED!!! directory exists but Vitis does not see a platform there:")
            print("                    " + platform_dir)
            print("                    delete that directory and re-run")
            sys.exit(1)
        try:
            platform_obj.build()
        except Exception as exc:
            print("!!!PLATFORM_BUILD_FAILED!!! " + str(exc))
            sys.exit(1)
        print("[build_ps] Platform build done")
else:
    print("[build_ps] Creating platform: " + platform_name)
    stash = stash_dir(platform_dir)
    try:
        platform_obj = client.create_platform_component(
            name=platform_name,
            hw=xsa,
            cpu=CPU,
            os=OS_TYPE,
            domain_name=DOMAIN,
        )
    except Exception as exc:
        restore_dir(stash, platform_dir)
        print("!!!PLATFORM_FAILED!!! " + str(exc))
        sys.exit(1)
    restore_dir(stash, platform_dir)

    print("[build_ps] Building platform ...")
    try:
        platform_obj.build()
    except Exception as exc:
        print("!!!PLATFORM_BUILD_FAILED!!! " + str(exc))
        sys.exit(1)
    print("[build_ps] Platform build done")

# ---------------------------- Application ------------------------------------
# create_app_component 的 platform 参数要【字符串】(xpfm 路径)
platform_xpfm = find_xpfm(platform_name)
if not platform_xpfm:
    print("!!!NOXPFM!!! no .xpfm found under: " + os.path.join(workspace, platform_name))
    print("              platform build may have failed -- check the log above")
    sys.exit(1)
print("[build_ps] xpfm: " + str(platform_xpfm))

# 应用组件是否存在，同样以 vitis-comp.json 为准
app_dir = os.path.join(workspace, app_name)
app = None
if has_component(app_dir):
    print("[build_ps] Reusing existing application: " + app_name)
    try:
        app = client.get_component(app_name)
    except Exception as exc:
        print("!!!APP_FAILED!!! cannot open existing application component: " + str(exc))
        sys.exit(1)
else:
    print("[build_ps] Creating application: " + app_name)
    # 目录可能已经因为 git 跟踪了 src/ 而存在，先挪开，建完再合并回来
    stash = stash_dir(app_dir)
    try:
        app = client.create_app_component(
            name=app_name,
            platform=platform_xpfm,
            domain=DOMAIN,
            template=TEMPLATE,
        )
    except Exception as exc:
        restore_dir(stash, app_dir)
        print("!!!APP_FAILED!!! " + str(exc))
        sys.exit(1)
    restore_dir(stash, app_dir)

print("[build_ps] Building application: " + app_name)
print("[build_ps] source dir: " + os.path.join(app_dir, "src"))
try:
    status = app.build()
except Exception as exc:
    print("!!!APP_BUILD_FAILED!!! " + str(exc))
    sys.exit(1)
print("[build_ps] build status: " + str(status))

# ------------------------------- 找 .elf -------------------------------------
# 只在应用组件目录里找，避免误抓 platform 的 fsbl.elf
elvs = []
for root, _dirs, files in os.walk(app_dir if os.path.isdir(app_dir) else workspace):
    for fn in files:
        if fn.endswith(".elf") and fn != "fsbl.elf":
            elvs.append(os.path.join(root, fn))

for p in elvs:
    print("ELF=" + p)

# ★ app.build() 失败时【不一定抛异常】——Vitis 只会软失败打一行字，
#   所以必须以磁盘上有没有 .elf 为准，否则会误报成功。
if not elvs:
    src_dir = os.path.join(app_dir, "src")
    has_src = False
    if os.path.isdir(src_dir):
        for _root, _dirs, files in os.walk(src_dir):
            for fn in files:
                if fn.endswith((".c", ".cpp", ".cc", ".S", ".s", ".asm")):
                    has_src = True
                    break
            if has_src:
                break

    if not has_src:
        print("!!!NO_SOURCES!!! application '" + app_name + "' has no source files.")
        print("                Put your C sources here:")
        print("                    " + src_dir)
        print("                Any .c/.cpp file is picked up automatically")
        print("                (src/CMakeLists.txt uses aux_source_directory),")
        print("                you do NOT need to edit CMakeLists.txt.")
    else:
        print("!!!APP_BUILD_FAILED!!! no .elf produced, but sources are present.")
        print("                     real compile/link error -- read the log above")
    sys.exit(1)

# ------------------------------- 收尾 ----------------------------------------
try:
    vitis.dispose()
except Exception:
    pass

print("BUILD_PS_OK")

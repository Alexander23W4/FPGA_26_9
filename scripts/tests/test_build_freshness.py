"""Offline regression checks; no synthesis, Vitis workspace, or board access."""
import contextlib
import io
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
BASH = Path('D:/Git/bin/bash.exe')


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ('scripts/lib', 'scripts/tcl', 'rtl', 'constrs', 'board', 'ip',
                     'csrc/MID_plt/src', 'tools/Vivado/2023.2/bin', 'tools/Vitis/2023.2/bin'):
            (self.root / path).mkdir(parents=True)
        for name in ('scripts/build.sh', 'scripts/flash_current.sh', 'scripts/lib/common.sh'):
            shutil.copyfile(REPO / name, self.root / name)
        (self.root / 'rtl/design.v').write_text('current RTL')
        (self.root / 'csrc/MID_plt/src/main.c').write_text('current C')
        self.tool('Vivado', 'vivado.bat', '''
mkdir -p build/vivado/fpga_26/fpga_26.runs/impl_1
printf bit > build/vivado/fpga_26/fpga_26.runs/impl_1/system_wrapper.bit
printf xsa > build/vivado/fpga_26/fpga_26.xsa
printf registers > build/vivado/fpga_26/register_audit.txt
if [[ ${FAIL_HW:-0} == 1 ]]; then printf '!!!SYNTH_FAILED!!!\r\n'; exit 0; fi
printf 'BD_REFRESH_OK\r\nPL_REGISTERS_OK video_bits=32 area_bits=17\r\nBUILD_ZYNQ_OK\r\n'
''')
        self.tool('Vitis', 'vitis.bat', '''
if [[ ${FAIL_PS:-0} == 1 ]]; then printf '!!!APP_BUILD_FAILED!!!\r\n'; exit 0; fi
if [[ ${REWRITE_CMAKE:-0} == 1 ]]; then printf 'generated build configuration' > csrc/MID_plt/src/CMakeLists.txt; fi
if [[ ${CHANGE_USER_SOURCE:-0} == 1 ]]; then printf 'changed while compiling' > csrc/MID_plt/src/main.c; fi
mkdir -p csrc/MID_plt/build csrc/fpga_26/hw/sdt
printf elf > csrc/MID_plt/build/MID_plt.elf
printf init > csrc/fpga_26/hw/sdt/ps7_init.tcl
printf 'BUILD_PS_OK\r\n'
''')
        self.tool('Vitis', 'xsct.bat', '''
printf '%s\n' "$@" > downloaded_args.txt
printf 'FLASH_ALL_OK\n'
''')

    def tool(self, suite, name, body):
        path = self.root / 'tools' / suite / '2023.2/bin' / name
        script = path.with_suffix('.sh')
        script.write_text('#!/usr/bin/env bash\nset -e\n' + body, newline='\n')
        path.write_text('@echo off\n"D:\\Git\\bin\\bash.exe" "%~dpn0.sh" %*\n'
                        'exit /b %ERRORLEVEL%\n', newline='\r\n')

    def run_bash(self, command, **env):
        return subprocess.run([str(BASH), '-c',
            'export XILINX_ROOT="$PWD/tools"; ' + command],
            cwd=self.root, env={**os.environ, **env}, capture_output=True, text=True, timeout=30)

    def build(self):
        result = self.run_bash('bash scripts/build.sh zynq -n fpga_26 -H && '
                              'bash scripts/build.sh app -n MID_plt -p fpga_26 -f')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_success_publishes_paired_archives_and_downloads_them(self):
        self.build()
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = (self.root / 'downloaded_args.txt').read_text()
        self.assertIn('build\\out\\', args)
        self.assertNotIn('fpga_26.runs', args)
        self.assertIn('MID_plt.elf', args)

    def test_vitis_tools_at_front_of_path_do_not_capture_shell_tools(self):
        polluted = self.root / 'old_gnuwin'
        polluted.mkdir()
        for name in ('tee', 'tr', 'find', 'sort', 'sha256sum'):
            script = polluted / name
            script.write_text('#!/usr/bin/env bash\nprintf "WRONG_GNUWIN_TOOL\\n" >&2\nexit 99\n')
            script.chmod(0o755)
        result = self.run_bash(
            'export PATH="$PWD/old_gnuwin:$PATH"; '
            'bash scripts/build.sh zynq -n fpga_26 -H && '
            'bash scripts/build.sh app -n MID_plt -p fpga_26 -f && '
            'bash scripts/flash_current.sh init')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('WRONG_GNUWIN_TOOL', result.stdout + result.stderr)

    def test_vivado_launch_line_is_visible_before_tool_exits(self):
        # Keep the fake tool alive until its launch line reaches the reader.
        # A buffered tr filter would keep that line until the tool exits.
        tool = self.root / 'tools/Vivado/2023.2/bin/vivado.sh'
        original = tool.read_text()
        tool.write_text('''#!/usr/bin/env bash
for i in {1..50}; do
  [[ -f launch_seen ]] && break
  sleep 0.1
done
[[ -f launch_seen ]] || { printf 'STREAM_BUFFERED\\n'; exit 9; }
''' + original.split('set -e\n', 1)[1], newline='\n')
        process = subprocess.Popen([str(BASH), '-c',
            'export XILINX_ROOT="$PWD/tools"; bash scripts/build.sh zynq -n fpga_26 -H'],
            cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        lines = []
        for line in process.stdout:
            lines.append(line)
            if 'vivado <-' in line:
                (self.root / 'launch_seen').touch()
        process.wait(timeout=10)
        process.stdout.close()
        self.assertEqual(process.returncode, 0, ''.join(lines))
        self.assertTrue((self.root / 'launch_seen').exists())

    def test_failed_hardware_invalidates_previous_success(self):
        self.build()
        result = self.run_bash('bash scripts/build.sh zynq -n fpga_26 -H', FAIL_HW='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'build/out/latest-fpga_26-zynq.path').exists())
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'downloaded_args.txt').exists())

    def test_failed_ps_invalidates_previous_success(self):
        self.build()
        result = self.run_bash('bash scripts/build.sh app -n MID_plt -p fpga_26 -f', FAIL_PS='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'build/out/latest-MID_plt-app.path').exists())

    def test_changed_rtl_blocks_download(self):
        self.build()
        (self.root / 'rtl/design.v').write_text('changed RTL')
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PL inputs changed', result.stdout + result.stderr)

    def test_changed_c_blocks_download(self):
        self.build()
        (self.root / 'csrc/MID_plt/src/main.c').write_text('changed C')
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PS sources changed', result.stdout + result.stderr)

    def test_vitis_cmake_rewrite_is_accepted_and_final_config_is_protected(self):
        config = self.root / 'csrc/MID_plt/src/CMakeLists.txt'
        config.write_text('previous generated configuration')
        result = self.run_bash('bash scripts/build.sh zynq -n fpga_26 -H && '
                              'bash scripts/build.sh app -n MID_plt -p fpga_26 -f', REWRITE_CMAKE='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        config.write_text('changed after compilation')
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PS sources changed', result.stdout + result.stderr)

    def test_real_c_change_during_build_is_still_rejected(self):
        self.build()
        result = self.run_bash('bash scripts/build.sh app -n MID_plt -p fpga_26 -f',
                              CHANGE_USER_SOURCE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PS user sources changed during the build', result.stdout + result.stderr)
        self.assertFalse((self.root / 'build/out/latest-MID_plt-app.path').exists())

    def test_changed_archive_and_xsa_pair_are_rejected(self):
        self.build()
        # Convert the MSYS path back to a native path with Git's cygpath.
        native = self.run_bash('cygpath -w "$(cat build/out/latest-MID_plt-app.path)"').stdout.strip()
        psout = Path(native)
        (psout / 'XSA.sha256').write_text('wrong digest\n')
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ELF platform differs', result.stdout + result.stderr)
        (psout / 'MID_plt.elf').write_text('corrupted')
        result = self.run_bash('bash scripts/flash_current.sh init')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PS output changed', result.stdout + result.stderr)


class RtlSourceTests(unittest.TestCase):
    def tcl(self):
        import tkinter
        interpreter = tkinter.Tcl()
        interpreter.eval((REPO / 'scripts/tcl/build_freshness.tcl').read_text(encoding='utf-8-sig'))
        return interpreter

    def test_existing_project_adds_new_rtl_once(self):
        interpreter = self.tcl()
        interpreter.eval('''
            set known {}
            proc get_files {args} {
                global known
                set path [lindex $args end]
                if {[lsearch -exact $known $path] >= 0} {return [list $path]}
                return {}
            }
            proc add_files {args} {global known; lappend known [lindex $args end]}
        ''')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'nested').mkdir()
            for name in ('existing.v', 'nested/display_cfg_cdc.v', 'nested/video_colorizer.v'):
                (root/name).write_text('module stub; endmodule')
            interpreter.call('lappend', 'known', (root/'existing.v').as_posix())
            interpreter.call('sync_repo_rtl', root.as_posix())
            interpreter.call('sync_repo_rtl', root.as_posix())
            self.assertEqual(int(interpreter.eval('llength $known')), 3)

    def test_register_audit_requires_new_opacity_register(self):
        interpreter = self.tcl()
        interpreter.eval('''
            set opacity_bits 7
            proc get_cells {args} {
                global opacity_bits
                set filter [lindex $args end]
                if {[string match *reg_video_mode* $filter]} {set n 32} elseif {[string match *lesion_pixels_save* $filter]} {set n 17} else {set n $opacity_bits}
                set cells {}
                for {set i 0} {$i < $n} {incr i} {lappend cells cell$i}
                return $cells
            }
        ''')
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'audit.txt'
            interpreter.call('verify_pl_registers', path.as_posix())
            self.assertIn('mask_transparency_register_bits=7', path.read_text())
            interpreter.eval('set opacity_bits 0')
            with self.assertRaisesRegex(Exception, 'STALE_PL'):
                interpreter.call('verify_pl_registers', path.as_posix())


class VitisTests(unittest.TestCase):
    def exercise(self, platform_status=0, app_status=0, create_elf=True):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            plat, app = root / 'fpga_26', root / 'MID_plt'
            for path in (plat / 'hw', plat / 'export/fpga_26', app / 'build', app / 'src'):
                path.mkdir(parents=True)
            for path in (plat / 'vitis-comp.json', app / 'vitis-comp.json'):
                path.write_text('{}')
            (plat / 'hw/fpga_26.xsa').write_text('old hardware')
            xsa = root / 'current.xsa'
            xsa.write_text('new hardware')
            (plat / 'export/fpga_26/fpga_26.xpfm').write_text('platform')
            elf = app / 'build/MID_plt.elf'
            elf.write_text('stale ELF')
            src = app / 'src/main.c'
            src.write_text('code')
            calls = []

            def update_hw(hw):
                calls.append(('update_hw', Path(hw).read_text()))
                return True

            def build_app():
                calls.append(('build_app', elf.exists()))
                if create_elf:
                    elf.write_text('fresh ELF')
                return app_status

            platform = types.SimpleNamespace(update_hw=update_hw, build=lambda: platform_status)
            client = types.SimpleNamespace(set_workspace=lambda path: None,
                get_platform_component=lambda name: platform,
                get_component=lambda name: types.SimpleNamespace(build=build_app))
            vitis = types.SimpleNamespace(create_client=lambda: client, dispose=lambda: None)
            output = io.StringIO()
            code = 0
            with patch.dict(sys.modules, {'vitis': vitis}), \
                 patch.object(sys, 'argv', ['build_ps.py', 'MID_plt', str(xsa), str(root),
                                           'fpga_26', '--force-platform', '--no-fs']), \
                 contextlib.redirect_stdout(output):
                try:
                    runpy.run_path(str(REPO / 'scripts/vitis/build_ps.py'), run_name='__main__')
                except SystemExit as exc:
                    code = exc.code
            return code, output.getvalue(), calls

    def test_force_imports_new_hardware_and_removes_old_elf(self):
        code, output, calls = self.exercise()
        self.assertEqual(code, 0, output)
        self.assertEqual(calls, [('update_hw', 'new hardware'), ('build_app', False)])
        self.assertIn('BUILD_PS_OK', output)

    def test_platform_soft_failure_stops_before_application(self):
        code, output, calls = self.exercise(platform_status=1)
        self.assertEqual(code, 1)
        self.assertNotIn('BUILD_PS_OK', output)
        self.assertEqual(len(calls), 1)

    def test_application_soft_failure_is_not_success(self):
        code, output, _ = self.exercise(app_status=1)
        self.assertEqual(code, 1)
        self.assertNotIn('BUILD_PS_OK', output)

    def test_success_status_with_no_elf_is_rejected(self):
        code, output, _ = self.exercise(create_elf=False)
        self.assertEqual(code, 1)
        self.assertNotIn('BUILD_PS_OK', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)

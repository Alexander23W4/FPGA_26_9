"""Profile persistence/audit tests, no Vitis server or hardware required."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts/vitis'))
from network_bsp import load_profile, patch_inputs, verify_profile, verify_optimization


class NetworkBspTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.bsp = Path(self.temp.name)/'bsp'; self.exported = Path(self.temp.name)/'export'
        self.profile = load_profile(ROOT/'csrc/MID_plt/src/config/network_bsp.json')
        for name in ('libsrc/lwip213/src', 'libsrc/lwip213/src/contrib/ports/xilinx/include'):
            (self.bsp/name).mkdir(parents=True, exist_ok=True)
        self.cmake = self.bsp/'libsrc/lwip213/src/lwip213.cmake'
        self.cmake.write_text('cmake_minimum_required(VERSION 3.3)\n')
        self.template = self.bsp/'libsrc/lwip213/src/contrib/ports/xilinx/include/lwipopts.h.in'
        self.template.write_text(''.join('#cmakedefine %s @%s@\n' % (s['macro'], s['macro']) for s in self.profile.values()))

    def test_patch_is_idempotent_and_overrides_cached_defaults(self):
        self.assertTrue(patch_inputs(self.bsp, self.profile))
        self.assertFalse(patch_inputs(self.bsp, self.profile))
        self.assertEqual(self.cmake.read_text().count('HEARTCARE_NETWORK_BEGIN'), 1)
        self.assertIn('set(lwip213_tcp_wnd 65535 CACHE STRING', self.cmake.read_text())
        self.assertIn('#define TCP_SND_BUF 65535', self.template.read_text())

    def generate_outputs(self):
        for root in (self.bsp, self.bsp/'libsrc/build_configs/gen_bsp', self.exported):
            (root/'include').mkdir(parents=True, exist_ok=True)
            (root/'include/lwipopts.h').write_text(''.join('#define %s %d\n' % (s['macro'],s['value']) for s in self.profile.values()))
        (self.bsp/'libsrc/build_configs/gen_bsp/CMakeCache.txt').write_text(
            ''.join('%s:STRING=%d\n' % (n,s['value']) for n,s in self.profile.items()))

    def test_audit_rejects_stale_export_and_stale_library_cache(self):
        self.generate_outputs()
        self.assertIn('TCP_WND=65535', verify_profile(self.bsp,self.exported,self.profile))
        path=self.exported/'include/lwipopts.h'
        path.write_text(path.read_text().replace('TCP_WND 65535','TCP_WND 2048'))
        with self.assertRaisesRegex(RuntimeError,'profile mismatch'):
            verify_profile(self.bsp,self.exported,self.profile)
        self.generate_outputs()
        path=self.bsp/'libsrc/build_configs/gen_bsp/CMakeCache.txt'
        path.write_text(path.read_text().replace('tcp_snd_buf:STRING=65535','tcp_snd_buf:STRING=8192'))
        with self.assertRaisesRegex(RuntimeError,'CMake profile mismatch'):
            verify_profile(self.bsp,self.exported,self.profile)

    def test_optimization_uses_the_last_flag(self):
        path=Path(self.temp.name)/'compile_commands.json'
        path.write_text(json.dumps([{'command':'gcc -O2 -O0 -c main.c','file':'main.c'}]))
        with self.assertRaisesRegex(RuntimeError,'not -O2'):verify_optimization(path)
        path.write_text(json.dumps([{'command':'gcc -O0 -O2 -c main.c','file':'main.c'}]))
        verify_optimization(path)


if __name__ == '__main__': unittest.main()

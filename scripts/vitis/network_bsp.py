"""Apply and audit a source-controlled lwIP profile (Python 3.8 / Vitis 2023.2)."""
import json
from pathlib import Path
import re

# GEM TX-complete interrupts release PBUF_RAM while the raw-API main loop
# allocates TCP buffers. NO_SYS mutexes are empty: enable lwIP's IRQ-safe heap.
REQUIRED_MACROS = {'LWIP_ALLOW_MEM_FREE_FROM_OTHER_CONTEXT': 1,
                   'SYS_LIGHTWEIGHT_PROT': 1}


def load_profile(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    for name, setting in data.items():
        if not re.fullmatch(r'lwip213_[a-z_]+', name):
            raise ValueError('invalid BSP parameter: ' + name)
        if not re.fullmatch(r'[A-Z_]+', setting['macro']) or not isinstance(setting['value'], int):
            raise ValueError('invalid BSP setting: ' + name)
        if setting['value'] <= 0:
            raise ValueError('nonpositive BSP setting: ' + name)
    return data


def patch_inputs(bsp, profile):
    """Guard against 2023.2 regenerating integer settings with their defaults.

    Patch only workspace copies, before compilation. The post-build audit checks
    library and application headers as well as the CMake configuration actually used.
    """
    bsp = Path(bsp)
    cmake = bsp/'libsrc/lwip213/src/lwip213.cmake'
    template = bsp/'libsrc/lwip213/src/contrib/ports/xilinx/include/lwipopts.h.in'
    changed = False
    if not cmake.is_file() or not template.is_file():
        raise RuntimeError('lwIP generated sources are missing; regenerate the BSP first')
    text = cmake.read_text(encoding='utf-8')
    text = re.sub(r'# HEARTCARE_NETWORK_BEGIN.*?# HEARTCARE_NETWORK_END\n?', '', text, flags=re.S)
    block = '# HEARTCARE_NETWORK_BEGIN\n' + ''.join(
        'set(%s %d CACHE STRING "Heartcare network profile" FORCE)\n' % (name, value['value'])
        for name, value in sorted(profile.items())) + ''.join(
        'set(%s %d CACHE STRING "Heartcare interrupt-safe heap" FORCE)\n' % pair
        for pair in sorted(REQUIRED_MACROS.items())) + '# HEARTCARE_NETWORK_END\n'
    new = block + text
    if new != cmake.read_text(encoding='utf-8'):
        cmake.write_text(new, encoding='utf-8'); changed = True
    text = template.read_text(encoding='utf-8')
    for value in profile.values():
        pattern = r'^#(?:cmakedefine|define)\s+' + value['macro'] + r'\s+[^\r\n]*'
        text, count = re.subn(pattern, '#define %s %d' % (value['macro'], value['value']), text, flags=re.M)
        if count != 1:
            raise RuntimeError('expected one lwIP template entry: ' + value['macro'])
    for macro, value in REQUIRED_MACROS.items():
        pattern = r'^#(?:cmakedefine(?:01)?|define)\s+' + macro + r'\b[^\r\n]*'
        replacement = '#define %s %d' % (macro, value)
        text, count = re.subn(pattern, replacement, text, flags=re.M)
        if count == 0:
            # SYS_LIGHTWEIGHT_PROT is absent from the vendor template.
            text = replacement + '\n' + text
        elif count != 1:
            raise RuntimeError('duplicate lwIP template entry: ' + macro)
    if text != template.read_text(encoding='utf-8'):
        template.write_text(text, encoding='utf-8'); changed = True
    return changed


def verify_profile(bsp, exported, profile):
    bsp = Path(bsp)
    paths = [bsp/'include/lwipopts.h', bsp/'libsrc/build_configs/gen_bsp/include/lwipopts.h',
             Path(exported)/'include/lwipopts.h']
    for path in paths:
        text = path.read_text(encoding='utf-8')
        for setting in list(profile.values()) + [
                {'macro': macro, 'value': value} for macro, value in REQUIRED_MACROS.items()]:
            match = re.search(r'^#define\s+' + setting['macro'] + r'\s+(\d+)\s*$', text, re.M)
            if not match or int(match.group(1)) != setting['value']:
                raise RuntimeError('BSP profile mismatch: %s in %s' % (setting['macro'], path))
    cache = (bsp/'libsrc/build_configs/gen_bsp/CMakeCache.txt').read_text(encoding='utf-8')
    for name, setting in profile.items():
        if not re.search(r'^' + name + r':\w+=' + str(setting['value']) + r'\s*$', cache, re.M):
            raise RuntimeError('BSP CMake profile mismatch: ' + name)
    return ' '.join('%s=%d' % (s['macro'], s['value']) for _, s in sorted(profile.items()))


def verify_optimization(path):
    commands = json.loads(Path(path).read_text(encoding='utf-8'))
    if not commands:
        raise RuntimeError('empty compiler command database')
    for entry in commands:
        levels = re.findall(r'(?:^|\s)(-O(?:[0-3sgz]|fast))(?=\s|$)', entry['command'])
        if not levels or levels[-1] != '-O2':
            raise RuntimeError('effective compiler optimization is not -O2: ' + entry['file'])

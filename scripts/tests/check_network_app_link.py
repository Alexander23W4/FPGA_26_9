"""Compile/link current PS sources against the installed BSP into a test ELF.

Uses the existing Vitis compilation database; never publishes or flashes this ELF.
"""
import json
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'csrc/MID_plt/src'
OUT = ROOT / 'build/tests/network_app'


def main():
    entry = json.loads((SOURCE / 'compile_commands.json').read_text())[0]
    argv = shlex.split(entry['command'])
    compiler, flags = argv[0], []
    index = 1
    while index < len(argv):
        item = argv[index]
        if item in ('-o', '-c', '-MF', '-MT', '-MQ'):
            index += 2
            continue
        if item not in ('-MMD', '-MP', '-MD'):
            flags.append(item)
        index += 1
    OUT.mkdir(parents=True, exist_ok=True)
    objects = []
    # The real build refreshes CMake's flat source list from this directory too.
    for path in sorted(SOURCE.glob('*.c')):
        obj = OUT / (path.stem + '.o')
        result = subprocess.run([compiler, *flags, '-c', str(path), '-o', str(obj)],
                                capture_output=True, text=True, errors='replace')
        (OUT / (path.stem + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(path.name + ':\n' + result.stdout + result.stderr)
        objects.append(str(obj))
    spec = next(flag[len('-specs='):] for flag in flags if flag.startswith('-specs='))
    bsp = Path(spec).parent
    elf = OUT / 'network_check.elf'
    command = [compiler, *flags, *objects, '-o', str(elf),
               '-Wl,-T,' + str(SOURCE / 'lscript.ld'), '-L' + str(bsp / 'lib'),
               '-Wl,-Map,' + str(OUT / 'network_check.map'),
               '-Wl,--start-group', '-lxilstandalone', '-lxil', '-lxiltimer',
               '-lxilffs', '-llwip213', '-lgcc', '-lc', '-Wl,--end-group']
    result = subprocess.run(command, capture_output=True, text=True, errors='replace')
    (OUT / 'link.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    symbols = subprocess.check_output([str(Path(compiler).with_name('arm-none-eabi-nm.exe')),
                                       str(elf)], text=True)
    # Ensure the expanded lwIP heap plus stack still stays below the DDR images.
    end = re.search(r'^([0-9a-fA-F]+)\s+\w\s+_end$', symbols, re.M)
    if end and int(end.group(1), 16) >= 0x20000000:
        raise RuntimeError('application overlaps reserved DDR image buffers')
    print('NETWORK_ARM_LINK_OK:', len(objects), 'C sources, real BSP and lwIP; test ELF:', elf)


if __name__ == '__main__':
    main()

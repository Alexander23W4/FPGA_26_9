"""Verify build inputs; conservatively accept proven HDL annotation-only edits.

Artifacts and non-HDL inputs always retain byte-exact SHA256 checks. An HDL
fallback requires historical source matching the receipt hash, unchanged code
lines and unchanged synthesis/tool directives. It never rewrites a receipt.
"""
import argparse
from functools import lru_cache
import hashlib
from pathlib import Path
import re
import subprocess


_DIRECTIVE = re.compile(
    r'synthesis|synopsys|pragma|translate_|verilator|cadence|altera|xilinx|'
    r'full_case|parallel_case|coverage|lint_|\b(?:sdc|sdc_statement)\b', re.I)


def hdl_code(data):
    """Return exact nonblank code lines plus potentially executable comments.

    Inner whitespace, strings, operators and attributes remain byte-sensitive.
    Reject macros/includes/line-sensitive preprocessing rather than claiming a
    general Verilog equivalence proof. This is for reading-note edits only.
    """
    text = data.decode('utf-8-sig').replace('\r\n', '\n')
    output, directives = [], []
    i = 0
    while i < len(text):
        if text[i] == '"':
            start = i
            i += 1
            while i < len(text):
                if text[i] == '\\':
                    i += 2
                elif text[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
            else:
                raise ValueError('Unterminated HDL string')
            output.append(text[start:i])
        elif text[i] == '\\':
            start = i
            while i < len(text) and not text[i].isspace():
                i += 1
            output.append(text[start:i])
        elif text.startswith('//', i) or text.startswith('/*', i):
            start = i
            if text.startswith('//', i):
                end = text.find('\n', i)
                i = len(text) if end < 0 else end
            else:
                end = text.find('*/', i + 2)
                if end < 0:
                    raise ValueError('Unterminated HDL comment')
                i = end + 2
            comment = text[start:i]
            if _DIRECTIVE.search(comment):
                directives.append(comment)
            output.append(' ' + '\n' * comment.count('\n'))
        else:
            output.append(text[i])
            i += 1
    code = ''.join(output)
    for line in code.splitlines():
        if '`' in line:
            if not re.fullmatch(r'\s*`(?:timescale|default_nettype)\s+[^`]+', line):
                raise ValueError('Line-sensitive or unsupported HDL preprocessor')
    return tuple(line.strip() for line in code.splitlines() if line.strip()), tuple(directives)


def _git(root, *args):
    return subprocess.check_output(
        ['git', '-c', 'safe.directory=' + str(root), *args], cwd=root,
        stderr=subprocess.DEVNULL, timeout=15,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))


@lru_cache(maxsize=256)
def _historical_input(root, name, expected):
    """Find actual bytes used by the build, not merely the previous commit."""
    try:
        revisions = ['HEAD'] + _git(root, 'log', '-80', '--format=%H', '--', name).decode().splitlines()
        for revision in dict.fromkeys(revisions):
            original = _git(root, 'show', revision + ':' + name)
            # Git commonly stores LF while the build hashed a CRLF worktree.
            for variant in (original, original.replace(b'\r\n', b'\n'),
                            original.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')):
                if hashlib.sha256(variant).hexdigest() == expected:
                    return variant
    except (OSError, subprocess.SubprocessError, UnicodeError):
        pass
    return None


def stale_inputs(root, manifest):
    root = Path(root).resolve()
    try:
        lines = Path(manifest).read_text(encoding='utf-8').splitlines()
    except OSError:
        return ['校验清单缺失']
    stale = []
    entries = 0
    for row in lines:
        if not row.strip():
            continue
        pieces = row.split(maxsplit=1)
        if len(pieces) != 2 or not re.fullmatch('[0-9a-fA-F]{64}', pieces[0]):
            stale.append('校验清单格式错误')
            continue
        expected, name = pieces[0].lower(), pieces[1].lstrip('* ')
        entries += 1
        source = (root / name).resolve()
        try:
            if not source.is_relative_to(root):
                raise ValueError('Input is outside repository')
            current = source.read_bytes()
            if hashlib.sha256(current).hexdigest() == expected:
                continue
            if source.suffix.lower() not in ('.v', '.sv', '.vh', '.svh'):
                raise ValueError('Non-HDL input changed')
            original = _historical_input(str(root), name, expected)
            if original is None or hdl_code(original) != hdl_code(current):
                raise ValueError('HDL code or synthesis directives changed')
        except (OSError, ValueError, UnicodeError):
            stale.append(name)
    if not entries and not stale:
        stale.append('校验清单为空')
    return stale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('manifest', type=Path)
    args = parser.parse_args()
    changed = stale_inputs(args.root, args.manifest)
    if changed:
        parser.exit(1, 'Build inputs changed; rebuild required:\n' + '\n'.join(changed) + '\n')
    print('BUILD_INPUTS_OK exact hashes or verified HDL annotation-only changes')


if __name__ == '__main__':
    main()

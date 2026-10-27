"""Resolve and validate the DDR weight image for the configured PL backend."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct


def expected_model_header(root):
    root=Path(root)
    config=json.loads((root/'rtl/unet/model_config.json').read_text(encoding='utf-8'))
    backend=config['backend']
    if backend=='full-fp32':
        text=(root/'rtl/unet/hls/model_ops.h').read_text(encoding='utf-8')
        def macro(name):
            match=re.search(r'^#define\s+'+name+r'\s+(0[xX][0-9a-fA-F]+|\d+)',text,re.M)
            if not match:raise ValueError('Missing compiled model definition: '+name)
            return int(match.group(1),0)
        expected=(0,1,macro('UNET_OPS'),macro('UNET_WORK_WORDS'),macro('UNET_LANES'),
                  macro('UNET_SIZE'),macro('UNET_PROGRAM_ID'))
        candidates=('build/unet/full_model/weights.bin','build/unet/model/weights.bin')
    elif backend=='small-int8':
        text=(root/'rtl/unet/small_hls/model_load.tcl').read_text(encoding='utf-8')
        match=re.search(r'unet_expected_header\s+\{([^}]+)\}',text)
        if not match:raise ValueError('Missing small-model header definition')
        expected=tuple(int(word,0) for word in match.group(1).split())
        candidates=('build/unet/model/weights.bin',)
    else:raise ValueError('Unknown PL U-Net backend: '+backend)
    return backend,expected,candidates


def resolve_model_image(root,override=None):
    root=Path(root).resolve()
    backend,expected,candidates=expected_model_header(root)
    paths=[Path(override)] if override else [root/name for name in candidates]
    failures=[]
    for path in paths:
        if not path.is_absolute():path=root/path
        try:
            size=path.stat().st_size
            if not 64<=size<=0x4000000 or size%4:raise ValueError('invalid weight image size')
            with path.open('rb') as stream:actual=struct.unpack('<7I',stream.read(28))
            if actual!=expected:
                raise ValueError('model header mismatch: expected %s, got %s'%(expected,actual))
            digest=hashlib.sha256(path.read_bytes()).hexdigest()
            metadata=path.with_name('model.json')
            if metadata.is_file():
                recorded=json.loads(metadata.read_text(encoding='utf-8')).get('weights_sha256')
                if recorded and recorded!=digest:raise ValueError('weight SHA256 does not match model.json')
            return {'path':path.resolve(),'backend':backend,'size':size,'sha256':digest,'header':actual}
        except (OSError,ValueError,struct.error) as error:
            failures.append('%s: %s'%(path,error))
    raise ValueError('No matching %s U-Net weights. %s'%(backend,'; '.join(failures)))


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--override',default=os.environ.get('UNET_WEIGHTS'))
    args=parser.parse_args()
    try:print(resolve_model_image(args.root,args.override)['path'])
    except (OSError,ValueError) as error:parser.exit(1,str(error)+'\n')


if __name__=='__main__':main()

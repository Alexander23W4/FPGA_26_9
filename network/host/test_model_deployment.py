import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from model_deployment import resolve_model_image


class ModelDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        (self.root/'rtl/unet/hls').mkdir(parents=True)
        (self.root/'rtl/unet/model_config.json').write_text('{"backend":"full-fp32"}')
        macros={'UNET_OPS':78,'UNET_WORK_WORDS':4849664,'UNET_LANES':16,
                'UNET_SIZE':256,'UNET_PROGRAM_ID':552009709}
        (self.root/'rtl/unet/hls/model_ops.h').write_text(''.join('#define %s %su\n'%pair for pair in macros.items()))
        self.full=(0,1,78,4849664,16,256,552009709)

    def image(self,directory,header):
        path=self.root/directory/'weights.bin';path.parent.mkdir(parents=True,exist_ok=True)
        data=struct.pack('<16I',*header,*([0]*9));path.write_bytes(data)
        path.with_name('model.json').write_text(json.dumps({'weights_sha256':hashlib.sha256(data).hexdigest()}))
        return path

    def test_full_backend_uses_full_export_when_legacy_folder_contains_small_model(self):
        self.image('build/unet/model',(0,2,15,6258688,8,256,1562305944))
        full=self.image('build/unet/full_model',self.full)
        selected=resolve_model_image(self.root)
        self.assertEqual(selected['path'],full)
        self.assertEqual(selected['backend'],'full-fp32')

    def test_explicit_small_override_cannot_be_silently_loaded_into_full_pl(self):
        small=self.image('build/unet/model',(0,2,15,6258688,8,256,1562305944))
        self.image('build/unet/full_model',self.full)
        with self.assertRaisesRegex(ValueError,'model header mismatch'):
            resolve_model_image(self.root,small)

    def test_program_id_and_integrity_must_match(self):
        full=self.image('build/unet/full_model',(*self.full[:6],123))
        with self.assertRaisesRegex(ValueError,'model header mismatch'):resolve_model_image(self.root)
        full=self.image('build/unet/full_model',self.full)
        full.write_bytes(full.read_bytes()[:-1]+b'\x01')
        with self.assertRaisesRegex(ValueError,'SHA256'):resolve_model_image(self.root)

    def test_legacy_full_export_remains_supported(self):
        full=self.image('build/unet/model',self.full)
        self.assertEqual(resolve_model_image(self.root)['path'],full)

    def test_small_backend_uses_its_own_expected_header(self):
        (self.root/'rtl/unet/model_config.json').write_text('{"backend":"small-int8"}')
        directory=self.root/'rtl/unet/small_hls';directory.mkdir()
        header=(0,2,15,6258688,8,256,1562305944)
        (directory/'model_load.tcl').write_text('set ::unet_expected_header {'+' '.join(map(str,header))+'}\n')
        small=self.image('build/unet/model',header)
        self.assertEqual(resolve_model_image(self.root)['path'],small)


if __name__=='__main__':unittest.main(verbosity=2)

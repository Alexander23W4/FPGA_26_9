import tempfile
import threading
import unittest
from pathlib import Path
import numpy as np
from medical_cache import PatientCache,PIXELS,packed_input,semantic_planes,preview_rgba

class CacheTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.folder=Path(self.temp.name)
  self.sources=[]
  for n in (1,2):
   p=self.folder/f'frame{n}.bin';p.write_bytes(bytes([n])*PIXELS);self.sources.append(p)
  self.cache=PatientCache(self.folder,self.sources,'original-model')
  a=np.zeros((PIXELS,4),dtype=np.uint8);a[:,0]=73;a[:,3]=255
  a[100:500,1]=4;a[[100,499],2]=4;self.raw=a.tobytes()
 def tearDown(self):
  try:self.cache.close()
  finally:self.temp.cleanup()
 def test_all_frames_and_model_required(self):
  self.assertFalse(self.cache.status()['complete'])
  self.cache.save_async('frame1.bin',self.sources[0].read_bytes(),self.raw).result()
  self.assertEqual(self.cache.status()['completed'],1)
  self.cache.save_async('frame2.bin',self.sources[1].read_bytes(),self.raw).result()
  self.assertTrue(self.cache.status()['complete'])
  other=PatientCache(self.folder,self.sources,'other-model')
  try:self.assertFalse(other.status()['complete'])
  finally:other.close()
 def test_corruption_and_source_changes_invalidate(self):
  self.cache.save_async('frame1.bin',self.sources[0].read_bytes(),self.raw).result()
  p=self.cache._paths('frame1.bin')['mask'];p.write_bytes(bytes(PIXELS))
  self.assertEqual(self.cache.status()['completed'],0)
  self.cache.save_async('frame1.bin',self.sources[0].read_bytes(),self.raw).result()
  self.sources[0].write_bytes(bytes([9])*PIXELS)
  self.assertEqual(self.cache.status()['completed'],0)
 def test_save_does_not_wait_for_disk(self):
  entered=threading.Event();release=threading.Event();write=self.cache._write
  def slow(*args):entered.set();release.wait(3);write(*args)
  self.cache._write=slow
  future=self.cache.save_async('frame1.bin',self.sources[0].read_bytes(),self.raw)
  self.assertTrue(entered.wait(1));self.assertFalse(future.done())
  self.assertFalse(self.cache.status()['complete']);release.set();future.result()
 def test_semantics_and_rgb_are_separate(self):
  g,m,c=semantic_planes(self.raw);packet=packed_input(g,m,c)
  self.assertEqual(len(packet),196608);self.assertEqual(packet[300:303],bytes([73,4,4]))
  rgb=preview_rgba(self.raw,1)
  self.assertEqual(rgb[400:404],bytes([0,210,96,255]));self.assertEqual(rgb[404:408],bytes([73,73,73,255]))
 def test_invalid_flags_and_names(self):
  raw=bytearray(self.raw);raw[1]=3
  with self.assertRaises(ValueError):semantic_planes(raw)
  with self.assertRaises(ValueError):self.cache.save_async('../bad.bin',bytes(PIXELS),self.raw)

if __name__=='__main__':unittest.main()

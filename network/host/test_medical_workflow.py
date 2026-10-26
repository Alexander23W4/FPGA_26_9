"""Exercise both patient workflows through the real full-duplex TCP transport."""
from pathlib import Path
import tempfile
import unittest
import shutil
import subprocess
import os
import json
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from unittest.mock import patch
import numpy as np
from frame_pipeline import FramePipeline
from medical_cache import PatientCache, PIXELS, preview_rgba
from medical_workflow import SegmentationPipeline, AnalysisPipeline, model_key, register_to_reference
from test_frame_transfer import running_board
from test_fast_stream import fast_server
import monitor_network as gui


def result_bytes(gray, mask, contour):
    data=np.empty((PIXELS,4),dtype=np.uint8)
    data[:,0]=gray;data[:,1]=mask;data[:,2]=contour;data[:,3]=255
    return data.tobytes()


def edges(mask):
    m=mask.reshape(256,256);p=np.pad(m,1)
    interior=p[:-2,1:-1]&p[2:,1:-1]&p[1:-1,:-2]&p[1:-1,2:]
    return (m&~interior).reshape(-1)


class MedicalWorkflowTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node.js is required')
    def test_gui_resumes_partial_patient_and_confirms_clear(self):
        with tempfile.TemporaryDirectory() as temp,fast_server() as (board,client,server,state,base):
            root=Path(temp);patient=root/'Site_G_29'/'patient-2-4';patient.mkdir(parents=True)
            for index in range(3):(patient/('frame%d.bin'%index)).write_bytes(bytes([index+1])*PIXELS)
            state.system_mode='medical';mask=np.zeros(PIXELS,dtype=np.uint8);mask[200:500]=4
            def semantic(image,kind,raw,mode):
                if kind==0:return result_bytes(np.frombuffer(image,dtype=np.uint8),mask,edges(mask))
                planes=np.frombuffer(image,dtype=np.uint8).reshape(PIXELS,3)
                result=result_bytes(planes[:,0],planes[:,1],edges(planes[:,1]) if kind==1 else planes[:,2])
                return result if raw else preview_rgba(result,mode)
            board.semantic_factory=semantic
            with patch.dict(gui.STREAM_DATASETS,{'cardiac':('Cardiac',root)}), \
                 patch.object(gui,'_choose_dataset_folder',return_value=('Cardiac',root,patient)):
                cache,_=gui._patient_cache('cardiac','Site_G_29/patient-2-4')
                cache.save_async('frame0.bin',(patient/'frame0.bin').read_bytes(),semantic(bytes([1])*PIXELS,0,True,1)).result();cache.close()
                script=Path(gui.__file__).parents[2]/'scripts/tests/gui_fast_stream.js'
                run=subprocess.run([shutil.which('node'),str(script),gui.__file__,base,'medical-resume'],
                                   capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('MEDICAL_GUI_RESUME_CLEAR_OK',run.stdout)
            self.assertEqual([entry[0] for entry in board.medical_packets[:4]],[0,1]*2)
            self.assertEqual(len(list(patient.glob('*.bin'))),3)
            self.assertFalse((patient/'.heartcare_unet').exists())
    def test_model_cache_key_tracks_inference_and_postprocess_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            paths=['ip/ai4chamberseger/model.zip',
                   'rtl/unet/hls/unet_ddr_core.cpp','rtl/unet/hls/unet_ddr_core.h',
                   'rtl/unet/hls/unet_conv.h','rtl/unet/hls/model_ops.h',
                   'rtl/unet/unet.v','rtl/unet/unet_stream_cdc.v',
                   'rtl/unet/unet_status_cdc.v',
                   'rtl/unet/generated/source_fingerprint.json',
                   'rtl/inter_fr/ddr/registration_ddr.cpp',
                   'rtl/inter_fr/ddr/registration_ddr_top.v',
                   'rtl/inter_fr/ddr/generated/source_fingerprint.json',
                   'rtl/heart_analysis/mask_to_contour.v','rtl/medical_cache_input.v',
                   'rtl/top1.v']
            for name in paths:
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(name.encode())
            top=root/'rtl/top1.v';top.write_text("UNET_CLASS_MAP=16'h4321;",encoding='utf-8')
            initial=model_key(root)
            stamp=(root/'rtl/unet/hls/unet_conv.h').stat()
            os.utime(root/'rtl/unet/hls/unet_conv.h',ns=(stamp.st_atime_ns,stamp.st_mtime_ns+1000000))
            self.assertEqual(model_key(root),initial,'metadata-only changes must not discard completed segmentation')
            changed=root/'rtl/unet/hls/unet_conv.h';changed.write_bytes(b'updated kernel')
            self.assertNotEqual(model_key(root),initial)
            contour=root/'rtl/heart_analysis/mask_to_contour.v';contour.write_bytes(b'updated contour')
            self.assertNotEqual(model_key(root),initial)
            top.write_text("UNET_CLASS_MAP=16'h4132;",encoding='utf-8')
            self.assertNotEqual(model_key(root),initial)

    @unittest.skipUnless(shutil.which('node'), 'Node.js is required')
    def test_gui_finite_segmentation_then_cached_stream(self):
        self._gui_finite_workflow('medical')

    @unittest.skipUnless(shutil.which('node'), 'Node.js is required')
    def test_lost_final_http_preview_still_finishes_patient(self):
        self._gui_finite_workflow('medical-loss')

    def _gui_finite_workflow(self, scenario):
        with tempfile.TemporaryDirectory() as temp,fast_server() as (board,client,server,state,base):
            root=Path(temp);patient=root/'Site_G_29'/'patient-2-4';patient.mkdir(parents=True)
            for index in range(3):(patient/('frame%d.bin'%index)).write_bytes(bytes([index+1])*PIXELS)
            state.system_mode='medical'
            mask=np.zeros((256,256),dtype=np.uint8);mask[20:200,30:190]=4;mask=mask.reshape(-1)
            def semantic(image,kind,raw,mode):
                if kind==0:return result_bytes(np.frombuffer(image,dtype=np.uint8),mask,edges(mask))
                planes=np.frombuffer(image,dtype=np.uint8).reshape(PIXELS,3)
                result=result_bytes(planes[:,0],planes[:,1],edges(planes[:,1]) if kind==1 else planes[:,2])
                return result if raw else preview_rgba(result,mode)
            board.semantic_factory=semantic
            with patch.dict(gui.STREAM_DATASETS,{'cardiac':('Cardiac',root)}), \
                 patch.object(gui,'_choose_dataset_folder',return_value=('Cardiac',root,patient)):
                script=Path(gui.__file__).parents[2]/'scripts/tests/gui_fast_stream.js'
                run=subprocess.run([shutil.which('node'),str(script),gui.__file__,base,scenario],
                                   capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('MEDICAL_GUI_CACHE_OK',run.stdout)
            self.assertEqual([entry[0] for entry in board.medical_packets[:6]],[0,1]*3)
            self.assertTrue(all(entry[0]==2 for entry in board.medical_packets[6:]))
            self.assertGreaterEqual(len(board.medical_packets),9)
            self.assertEqual(len(list((patient/'.heartcare_unet').rglob('*.record.json'))),3)

    def test_two_pass_cache_then_analysis_bypasses_model(self):
        with tempfile.TemporaryDirectory() as temp,running_board() as board:
            patient=Path(temp);sources=[];originals=[]
            mask=np.zeros((256,256),dtype=np.uint8)
            mask[30:80,20:90]=1;mask[30:90,130:220]=2
            mask[140:210,20:100]=4;mask[140:220,140:230]=8
            mask=mask.reshape(-1)
            for number in range(2):
                image=bytes([(number+1)*51])*PIXELS
                path=patient/('frame%d.bin'%number);path.write_bytes(image)
                sources.append(path);originals.append(image)
            def semantic(image,kind,raw,mode):
                if kind==0:
                    self.assertTrue(raw)
                    # Deliberately different from original gray: registration's
                    # image must be cached with its masks, never mixed later.
                    gray=(np.frombuffer(image,dtype=np.uint8)+7).astype(np.uint8)
                    return result_bytes(gray,mask,np.zeros(PIXELS,dtype=np.uint8))
                planes=np.frombuffer(image,dtype=np.uint8).reshape(PIXELS,3)
                np.testing.assert_array_equal(planes[:,1],mask)
                if kind==1:
                    self.assertTrue(raw);self.assertFalse(planes[:,2].any())
                    return result_bytes(planes[:,0],mask,edges(mask))
                self.assertEqual(kind,2);self.assertFalse(raw)
                np.testing.assert_array_equal(planes[:,2],edges(mask))
                return preview_rgba(result_bytes(*planes.T),mode,45)
            board.semantic_factory=semantic
            cache=PatientCache(patient,sources,'same-complete-model')
            transport=FramePipeline('127.0.0.1',board.server_address[1],3,
                                    capacity=1,medical_workflow='segmentation')
            segment=SegmentationPipeline(transport,cache,'Site/patient')
            try:
                for index,image in enumerate(originals):
                    source={'data':image,'name':sources[index].name,
                            'path':'Site/patient/'+sources[index].name,'index':index}
                    response=segment.submit(source,1).result(5)
                    self.assertEqual(response['raw'][4*(30*256+20):4*(30*256+20)+4],bytes([255,0,0,255]))
            finally:segment.close()
            self.assertEqual(board.medical_packets,[(0,True,65536),(1,True,196608)]*2)
            cache=PatientCache(patient,sources,'same-complete-model')
            self.assertTrue(cache.status()['complete'])
            np.testing.assert_array_equal(np.frombuffer(cache.read('frame0.bin')['gray'],dtype=np.uint8),58)
            transport=FramePipeline('127.0.0.1',board.server_address[1],3,
                                    capacity=4,medical_workflow='analysis')
            analysis=AnalysisPipeline(transport,cache,'Site/patient')
            try:
                future=analysis.submit({'data':originals[0],'path':'Site/patient/frame0.bin','index':0},3)
                self.assertEqual(len(future.result(5)['raw']),PIXELS*4)
            finally:analysis.close()
            self.assertTrue(board.medical_cached_only)
            self.assertEqual(board.medical_packets[-1],(2,False,196608))
            self.assertEqual(board.uploads,5)

    def test_invalid_cache_fails_before_board_upload(self):
        with tempfile.TemporaryDirectory() as temp,running_board() as board:
            patient=Path(temp);source=patient/'frame.bin';source.write_bytes(bytes(PIXELS))
            cache=PatientCache(patient,[source],'model')
            transport=FramePipeline('127.0.0.1',board.server_address[1],1,medical_workflow='analysis')
            analysis=AnalysisPipeline(transport,cache,'patient')
            try:
                with self.assertRaises(OSError):analysis.submit({'data':bytes(PIXELS),'path':'patient/frame.bin'},1)
                self.assertEqual(board.uploads,0)
            finally:analysis.close()

    def test_resume_skips_committed_frame_without_connecting_board(self):
        with tempfile.TemporaryDirectory() as temp:
            patient=Path(temp);source=patient/'frame.bin';source.write_bytes(bytes(PIXELS))
            raw=result_bytes(np.zeros(PIXELS,dtype=np.uint8),np.zeros(PIXELS,dtype=np.uint8),np.zeros(PIXELS,dtype=np.uint8))
            cache=PatientCache(patient,[source],'model');cache.save_async('frame.bin',source.read_bytes(),raw).result();cache.close()
            cache=PatientCache(patient,[source],'model')
            class NoBoard:
                def submit(self,*args):raise AssertionError('completed frame must not be sent to the FPGA')
                def close(self):pass
            segment=SegmentationPipeline(NoBoard(),cache,'patient')
            try:
                result=segment.submit({'data':source.read_bytes(),'path':'patient/frame.bin'},1).result(3)
                self.assertTrue(result['cached']);self.assertEqual(result['frames'],0)
            finally:segment.close()

    def test_resume_registration_keeps_original_reference(self):
        rng=np.random.default_rng(26);reference=rng.integers(0,256,(256,256),dtype=np.uint8)
        shifted=np.zeros_like(reference);shifted[:-1,2:]=reference[1:,:-2]
        aligned=np.frombuffer(register_to_reference(reference.tobytes(),shifted.tobytes()),dtype=np.uint8).reshape(256,256)
        np.testing.assert_array_equal(aligned[1:,:-2],reference[1:,:-2])
        self.assertFalse(aligned[0].any());self.assertFalse(aligned[:,-2:].any())

    def test_clear_endpoint_requires_confirmation_and_idle_session(self):
        with tempfile.TemporaryDirectory() as temp,fast_server() as (_,_,_,state,base):
            root=Path(temp);patient=root/'patient';patient.mkdir();source=patient/'frame.bin';source.write_bytes(bytes(PIXELS))
            a=np.zeros((PIXELS,4),dtype=np.uint8);a[:,3]=255
            cache=PatientCache(patient,[source],'model');cache.save_async('frame.bin',source.read_bytes(),a.tobytes()).result();cache.close()
            def cache_for(*args):return PatientCache(patient,[source],'model'),[]
            def request(confirm):
                body=json.dumps({'dataset':'cardiac','patient':'patient','confirm':confirm}).encode()
                return urlopen(Request(base+'/api/network/medical/clear',body,{'Content-Type':'application/json'}),timeout=3)
            with patch.object(gui,'_patient_cache',side_effect=cache_for):
                with self.assertRaises(HTTPError) as rejected:request(False)
                rejected.exception.close()
                self.assertTrue((patient/'.heartcare_unet').exists())
                with gui._TRANSFER_LOCK:
                    with self.assertRaises(HTTPError) as rejected:request(True)
                    rejected.exception.close()
                with request(True) as response:self.assertEqual(json.load(response)['completed'],0)
            self.assertTrue(source.exists());self.assertFalse((patient/'.heartcare_unet').exists())


if __name__=='__main__':unittest.main()

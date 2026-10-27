"""Exercise the real HTTP startup gate without programming a board."""
import contextlib
import http.client
import io
import json
from pathlib import Path
import subprocess
import threading
import time
import unittest
from unittest.mock import patch

import monitor_network as gui


@contextlib.contextmanager
def startup_server():
    class Handler(gui.NetworkHandler):
        def log_message(self,*args):pass
    server=gui.NetworkServer(('127.0.0.1',0),Handler)
    server.startup_config={'repo':str(Path(gui.__file__).parents[2]),
        'board_ip':'192.168.1.10','transfer_port':5002,'serial_port':'COM7'}
    thread=threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    try:yield server
    finally:
        server.shutdown();server.server_close();thread.join(2)


def request(server,path,method='GET'):
    connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
    try:
        connection.request(method,path)
        response=connection.getresponse()
        return response.status,dict(response.getheaders()),response.read().decode('utf-8')
    finally:connection.close()


class StartupTests(unittest.TestCase):
    def test_home_is_independent_and_console_is_locked(self):
        with startup_server() as server:
            status,headers,body=request(server,'/')
            self.assertEqual(status,200)
            self.assertIn('准备启动影像工作台',body)
            self.assertIn('/assets/startup.js',body)
            self.assertNotIn('id="medicalSegment"',body)
            self.assertIn('no-store',headers['Cache-Control'])
            status,headers,_=request(server,'/console')
            self.assertEqual((status,headers['Location']),(302,'/'))
            status,_,body=request(server,'/api/serial/readback')
            self.assertEqual(status,423)
            self.assertTrue(json.loads(body)['startup_required'])
            status,_,_=request(server,'/api/network/frame','POST')
            self.assertEqual(status,423)
            status,_,body=request(server,'/assets/startup.js')
            self.assertEqual(status,200)
            self.assertIn('async function initialize()',body)

    def test_device_check_route_is_not_overridden(self):
        result={'ok':True,'ready':False,'checked_at':time.time(),
            'components':{'uart':{'ok':False,'detail':'COM7 未连接'}},'missing':['USB-UART 串口']}
        with startup_server() as server,patch.object(gui,'_probe_startup',return_value=result) as probe:
            status,_,body=request(server,'/api/startup/check')
            self.assertEqual((status,json.loads(body)),(200,result))
            probe.assert_called_once_with(server.startup_config)
            self.assertEqual(server.startup_last_check,result)
            status,_,_=request(server,'/api/startup/flash','POST')
            self.assertEqual(status,409)

    def test_flash_is_single_task_and_requires_a_fresh_check(self):
        entered=threading.Event();release=threading.Event()
        def burn(server):
            entered.set();release.wait(3)
        with startup_server() as server,patch.object(gui,'_flash_current_worker',side_effect=burn) as worker:
            server.startup_last_check={'ready':True,'checked_at':time.time()-181}
            self.assertEqual(request(server,'/api/startup/flash','POST')[0],409)
            worker.assert_not_called()
            server.startup_last_check={'ready':True,'checked_at':time.time()}
            try:
                self.assertEqual(request(server,'/api/startup/flash','POST')[0],200)
                self.assertTrue(entered.wait(1))
                self.assertEqual(request(server,'/api/startup/flash','POST')[0],200)
                self.assertEqual(worker.call_count,1)
                self.assertEqual(request(server,'/api/startup/check')[0],409)
                status,_,body=request(server,'/api/startup/status')
                self.assertEqual((status,json.loads(body)['state']),(200,'running'))
                self.assertFalse(json.loads(body)['ready'])
            finally:release.set()

    def test_worker_unlocks_only_after_success_and_real_frame_port(self):
        class Process:
            stdout=io.StringIO('PL programmed\nUNET_WEIGHTS_LOADING\nUNET_WEIGHTS_READY\nFLASH_ALL_OK\n'+'tail\n'*20)
            def wait(self):return 0
        with startup_server() as server,patch.object(gui,'_git_bash',return_value='bash'), \
             patch.object(gui._sp,'Popen',return_value=Process()) as popen, \
             patch.object(gui,'_tcp_probe',return_value=True) as tcp:
            gui._flash_current_worker(server)
            self.assertTrue(server.flash_ready)
            self.assertEqual((server.flash_state['state'],server.flash_state['progress']),('complete',100))
            tcp.assert_called_once_with('192.168.1.10',5002,.4)
            self.assertEqual(popen.call_args.args[0][-1],'init')
            status,headers,_=request(server,'/')
            self.assertEqual((status,headers['Location']),(302,'/console'))
            status,_,body=request(server,'/console')
            self.assertEqual(status,200)
            self.assertIn('id="medicalSegment"',body)
        with startup_server() as fresh:
            self.assertFalse(fresh.flash_ready)
            self.assertIn('准备启动影像工作台',request(fresh,'/')[2])

    def test_zero_exit_without_flash_marker_does_not_unlock(self):
        class Process:
            stdout=io.StringIO('PL programmed\n')
            def wait(self):return 0
        with startup_server() as server,patch.object(gui,'_git_bash',return_value='bash'), \
             patch.object(gui._sp,'Popen',return_value=Process()),patch.object(gui,'_tcp_probe') as tcp:
            gui._flash_current_worker(server)
            self.assertFalse(server.flash_ready)
            self.assertEqual(server.flash_state['state'],'error')
            tcp.assert_not_called()
            self.assertEqual(request(server,'/console')[0],302)

    def test_cold_board_accepts_a_connected_nic_then_validates_tcp_after_flash(self):
        ok={'ok':True,'detail':'ready'}
        config={'repo':'.','board_ip':'192.168.1.10','transfer_port':5002,'serial_port':'COM7'}
        with patch.object(gui,'_tcp_probe',return_value=False), \
             patch.object(gui._sp,'run',return_value=subprocess.CompletedProcess([],1,'','')), \
             patch.object(gui,'_probe_jtag',return_value=ok),patch.object(gui,'_probe_uart',return_value=ok), \
             patch.object(gui,'_probe_build',return_value=ok), \
             patch.object(gui,'_ethernet_link',return_value='Ethernet · 192.168.1.100/24') as link:
            self.assertTrue(gui._probe_startup(config)['ready'])
            link.return_value=None
            result=gui._probe_startup(config)
            self.assertFalse(result['ready'])
            self.assertIn('板卡以太网',result['missing'][0])


if __name__=='__main__':unittest.main(verbosity=2)

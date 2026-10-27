"""Exercise the real HTTP startup gate without programming a board."""
import contextlib
import http.client
import io
import json
from pathlib import Path
import socket
import threading
import time
import unittest
from unittest.mock import patch

import monitor_network as gui
import frame_transfer as transfer


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
             patch.object(gui,'_ethernet_link',return_value={'ok':True,'source_ip':'192.168.1.100','detail':'wired'}), \
             patch.object(gui,'_frame_service_probe',return_value=True) as tcp:
            gui._flash_current_worker(server)
            self.assertTrue(server.flash_ready)
            self.assertEqual((server.flash_state['state'],server.flash_state['progress']),('complete',100))
            tcp.assert_called_once_with('192.168.1.10',5002,'192.168.1.100')
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
             patch.object(gui._sp,'Popen',return_value=Process()),patch.object(gui,'_frame_service_probe') as tcp:
            gui._flash_current_worker(server)
            self.assertFalse(server.flash_ready)
            self.assertEqual(server.flash_state['state'],'error')
            tcp.assert_not_called()
            self.assertEqual(request(server,'/console')[0],302)

    def test_failed_programming_keeps_diagnostic_and_allows_another_attempt(self):
        entered=threading.Event()
        def fail(server):
            gui._flash_progress(server,state='error',error='Unexpected U-Net model header',message='full XSCT diagnostic')
            entered.set()
        with startup_server() as server,patch.object(gui,'_flash_current_worker',side_effect=fail) as worker:
            server.startup_last_check={'ready':True,'checked_at':time.time()}
            self.assertEqual(request(server,'/api/startup/flash','POST')[0],200)
            self.assertTrue(entered.wait(1));entered.clear()
            status=json.loads(request(server,'/api/startup/status')[2])
            self.assertIn('model header',status['error'])
            self.assertEqual(status['message'],'full XSCT diagnostic')
            self.assertEqual(request(server,'/api/startup/flash','POST')[0],200)
            self.assertTrue(entered.wait(1))
            self.assertEqual(worker.call_count,2)

    def test_cold_board_accepts_a_connected_nic_then_validates_tcp_after_flash(self):
        ok={'ok':True,'detail':'ready'}
        config={'repo':'.','board_ip':'192.168.1.10','transfer_port':5002,'serial_port':'COM7'}
        with patch.object(gui,'_probe_jtag',return_value=ok),patch.object(gui,'_probe_uart',return_value=ok), \
             patch.object(gui,'_probe_build',return_value=ok), \
             patch.object(gui,'_ethernet_link',return_value={'ok':True,'source_ip':'192.168.1.100','detail':'wired'}) as link, \
             patch.object(gui.socket,'create_connection') as tcp,patch.object(gui._sp,'run') as ping:
            self.assertTrue(gui._probe_startup(config)['ready'])
            link.return_value={'ok':False,'detail':'网线未连接'}
            result=gui._probe_startup(config)
            self.assertFalse(result['ready'])
            self.assertIn('板卡以太网',result['missing'][0])
            tcp.assert_not_called()
            ping.assert_not_called()

    def test_wifi_virtual_adapters_and_unplugged_cable_never_count_as_wired(self):
        wifi={'name':'WLAN','index':13,'physical':True,'virtual':False,'medium':9,
            'interface_type':71,'status':'Up','media':1,'addresses':[{'ip':'192.168.1.100','prefix':24}]}
        virtual={**wifi,'name':'VMware','physical':False,'virtual':True,'medium':14,'interface_type':6}
        wired={**wifi,'name':'Ethernet','index':2,'medium':14,'interface_type':6,
            'status':'Disconnected','media':2}
        for rows in ([],[wifi],[virtual],[wifi,virtual,wired]):
            with self.subTest(rows=rows):self.assertFalse(gui._wired_adapter(rows,'192.168.1.10')['ok'])
        wired.update(status='Up',media=1)
        found=gui._wired_adapter([wifi,virtual,wired],'192.168.1.10')
        self.assertTrue(found['ok'])
        self.assertEqual((found['source_ip'],found['interface_index']),('192.168.1.100',2))
        for ip in ('192.168.2.100','192.168.1.10'):
            wired['addresses']=[{'ip':ip,'prefix':24}]
            self.assertFalse(gui._wired_adapter([wired],'192.168.1.10')['ok'])

    def test_plain_tcp_accept_is_not_a_valid_board_protocol(self):
        for valid in (False,True):
            with self.subTest(valid=valid),socket.socket() as listener:
                listener.bind(('127.0.0.1',0));listener.listen(1);listener.settimeout(2)
                received=[]
                def board():
                    with listener.accept()[0] as connection:
                        header=transfer.recv_exact(connection,transfer.HEADER.size)
                        words=transfer.HEADER.unpack(header);received.append(words)
                        connection.sendall(transfer.packet(transfer.FAST_READY,words[2],extra=4)
                                           if valid else b'x'*transfer.HEADER.size)
                thread=threading.Thread(target=board,daemon=True);thread.start()
                result=gui._frame_service_probe('127.0.0.1',listener.getsockname()[1],'127.0.0.1',.5)
                thread.join(2)
                self.assertEqual(result,valid)
                self.assertEqual(received[0][:2],(transfer.MAGIC,transfer.HELLO_FAST))


if __name__=='__main__':unittest.main(verbosity=2)

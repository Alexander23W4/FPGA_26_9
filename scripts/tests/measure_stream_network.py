"""Board-only stream benchmark; records Windows TCP_INFO and frame timings.

Requires an idle GUI stream. Sends synthetic 256x256 BINs to the current PL mode;
does not flash, save images, change PL or change UART configuration.
"""
import argparse
from collections import deque
import ctypes
import json
from pathlib import Path
import statistics
import sys
import threading
import time

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'network/host'))
from frame_pipeline import FramePipeline


class TcpInfo(ctypes.Structure):
    _fields_=[('state',ctypes.c_uint32),('mss',ctypes.c_uint32),('connection_ms',ctypes.c_uint64),
        ('timestamps',ctypes.c_ubyte),('rtt_us',ctypes.c_uint32),('min_rtt_us',ctypes.c_uint32),
        ('inflight_bytes',ctypes.c_uint32),('cwnd',ctypes.c_uint32),('send_window',ctypes.c_uint32),
        ('receive_window',ctypes.c_uint32),('receive_buffer',ctypes.c_uint32),
        ('bytes_out',ctypes.c_uint64),('bytes_in',ctypes.c_uint64),
        ('reordered',ctypes.c_uint32),('retrans_bytes',ctypes.c_uint32),('fast_retrans',ctypes.c_uint32),
        ('dup_acks',ctypes.c_uint32),('timeout_episodes',ctypes.c_uint32),('syn_retrans',ctypes.c_ubyte)]


def tcp_info(sock):
    api=ctypes.windll.ws2_32
    api.WSAIoctl.argtypes=[ctypes.c_size_t,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,
                          ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p]
    version=ctypes.c_uint32(0);info=TcpInfo();returned=ctypes.c_uint32()
    if api.WSAIoctl(sock.fileno(),0xD8000027,ctypes.byref(version),ctypes.sizeof(version),
                   ctypes.byref(info),ctypes.sizeof(info),ctypes.byref(returned),None,None):
        raise OSError(api.WSAGetLastError(),'SIO_TCP_INFO failed')
    return {key:int(getattr(info,key)) for key,_ in info._fields_}


def run(args,capacity):
    pipeline=FramePipeline(args.host,args.port,15,capacity=capacity,send_buffer=args.send_buffer,
                           send_chunk=args.send_chunk,send_pause=args.send_pause)
    samples=[];frames=[];pending=deque();stop=threading.Event();submitted=0
    epoch=time.perf_counter()
    def sample():
        while not stop.is_set():
            if pipeline._socket is not None:
                try:samples.append({'ms':(time.perf_counter()-epoch)*1000,**tcp_info(pipeline._socket)})
                except OSError as error:
                    samples.append({'error':str(error)});return
            stop.wait(.003)
    worker=threading.Thread(target=sample,daemon=True);worker.start()
    image=bytes(range(256))*256
    try:
        while len(frames)<args.frames:
            while submitted<args.frames and len(pending)<capacity:
                pending.append((submitted,pipeline.submit({'data':image},args.mode)));submitted+=1
            sequence,future=pending.popleft();result=future.result(15)
            frames.append({'sequence':sequence,'ms':(time.perf_counter()-epoch)*1000,
                           'timings_ms':result['timings_ms'],'readback':result['readback']})
        final=tcp_info(pipeline._socket)
    finally:
        stop.set();worker.join(2);pipeline.close()
    gaps=[b['ms']-a['ms'] for a,b in zip(frames,frames[1:])]
    summary={'capacity':capacity,'frames':len(frames),'fps':(len(frames)-1)*1000/(frames[-1]['ms']-frames[0]['ms']),
        'gap_median_ms':statistics.median(gaps),'gap_max_ms':max(gaps),'gaps_over_100ms':sum(x>100 for x in gaps),
        'receive_max_ms':max(f['readback']['ps_timings_ms']['receive'] for f in frames),
        'write_max_ms':max(f['timings_ms']['upload_send_ms'] for f in frames),'tcp_final':final}
    path=Path(args.out)/('capacity_%d.json'%capacity);path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps({'summary':summary,'frames':frames,'tcp_samples':samples},indent=2),encoding='utf-8')
    print(json.dumps(summary),flush=True)
    time.sleep(.2)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--host',default='192.168.1.10')
    parser.add_argument('--port',type=int,default=5002);parser.add_argument('--mode',type=int,default=4)
    parser.add_argument('--frames',type=int,default=40);parser.add_argument('--capacities',type=int,nargs='+',default=[1,4,8])
    parser.add_argument('--out',default=str(ROOT/'build/tests/stream_network_baseline'))
    parser.add_argument('--send-buffer',type=int)
    parser.add_argument('--send-chunk',type=int)
    parser.add_argument('--send-pause',type=float,default=0)
    args=parser.parse_args()
    for capacity in args.capacities:run(args,capacity)

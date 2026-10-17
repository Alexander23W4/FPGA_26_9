/* Network/file reads run off the UI thread. Only bounded latest-frame previews cross to it. */
let running=false, active=false, paused=false, wake=null, requestedMode=0;
const channels={source:{busy:false,latest:null},result:{busy:false,latest:null}};
function publish(kind,message){
  const channel=channels[kind];
  if(channel.busy){channel.latest=message;return;}
  channel.busy=true;
  self.postMessage({type:kind,...message},[message.raw]);
}
function previewConsumed(kind){
  const channel=channels[kind];channel.busy=false;
  if(channel.latest){const latest=channel.latest;channel.latest=null;publish(kind,latest);}
}
async function loop(options){
  if(active)return;
  active=true;running=true;paused=false;requestedMode=Number(options.mode);
  let index=options.index,completed=0;
  let times=options.times||[];
  const files=options.files;
  let nextRead=null,last=null;
  try{
    while(running){
      if(paused){
        self.postMessage({type:'paused'});
        await new Promise(resolve=>{wake=resolve;});wake=null;
        if(!running)break;
      }
      const entry=files[index],start=performance.now();
      const data=await (nextRead||entry.file.arrayBuffer());nextRead=null;
      if(!running)break;
      if(data.byteLength!==65536)throw new Error('BIN 必须恰好为 65536 字节');
      const source=data.slice(0);
      publish('source',{raw:source,folder:options.folder,index});
      const mode=requestedMode;
      const query=new URLSearchParams({name:entry.file.name,folder:options.folder,path:entry.path,mode:String(mode)});
      const responsePromise=fetch('/api/network/frame?'+query,{method:'POST',
        headers:{'Content-Type':'application/octet-stream'},body:data});
      const nextIndex=(index+1)%files.length;
      // A single prefetched source bounds memory and overlaps local reading with FPGA work.
      nextRead=files[nextIndex].file.arrayBuffer();nextRead.catch(()=>{});
      const response=await responsePromise;
      if(!response.ok){const error=await response.json();throw new Error(error.log||error.error);}
      const body=await response.arrayBuffer();
      if(body.byteLength<4)throw new Error('回传响应不完整');
      const size=new DataView(body).getUint32(0);
      if(size>65536||body.byteLength!==4+size+262144)throw new Error('回传 BIN 长度错误');
      const metadata=JSON.parse(new TextDecoder().decode(new Uint8Array(body,4,size)));
      if(!metadata.ok||metadata.mode!==mode)throw new Error('回传模式错误');
      const raw=body.slice(4+size),now=Date.now();
      completed++;index=nextIndex;times.push(now);times=times.filter(t=>t>=now-10000);
      last={metadata,index,completed,times,frameMs:performance.now()-start};
      publish('result',{raw,...last});
      // No wait for UI repaint, PNG encoding, disk flush, or a main-thread message.
    }
  }catch(error){self.postMessage({type:'error',message:error.message});}
  finally{
    active=running=false;
    for(const [type,channel] of Object.entries(channels)){
      if(channel.latest){const latest=channel.latest;channel.latest=null;self.postMessage({type,...latest},[latest.raw]);}
    }
    self.postMessage({type:'stopped',last});
  }
}
self.onmessage=event=>{
  const message=event.data;
  if(message.type==='start')void loop(message);
  else if(message.type==='stop'){running=false;if(wake)wake();}
  else if(message.type==='mode')requestedMode=Number(message.mode);
  else if(message.type==='pause')paused=true;
  else if(message.type==='resume'){paused=false;if(wake)wake();}
  else if(message.type==='preview_consumed')previewConsumed(message.kind);
};

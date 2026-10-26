/* Python owns board pacing; this worker fills its bounded queue independently of previews. */
let activeRun=null;
const channels={source:{busy:false,latest:null},result:{busy:false,latest:null}};
function publish(kind,message){
  const channel=channels[kind];
  if(channel.busy){channel.latest=message;return;}
  channel.busy=true;
  self.postMessage({type:kind,...message},[message.raw]);
}
function previewConsumed(kind){
  const channel=channels[kind];
  if(!channel)return;
  channel.busy=false;
  if(channel.latest){const latest=channel.latest;channel.latest=null;publish(kind,latest);}
}
function gate(){
  let resolve;
  const promise=new Promise(done=>{resolve=done;});
  return {promise,resolve};
}
function wakeProducer(run){
  if(run.wake){const wake=run.wake;run.wake=null;wake();}
}
function waitForSpace(run){
  return new Promise(resolve=>{
    const finish=()=>{clearTimeout(timer);if(run.wake===finish)run.wake=null;resolve();};
    const timer=setTimeout(finish,10);
    run.wake=finish;
    if(!run.running)finish();
  });
}
async function jsonResponse(response){
  const body=await response.json();
  if(!response.ok||!body.ok)throw new Error(body.log||body.error||'流传输请求失败');
  return body;
}
function postJson(url,body){
  return fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify(body)}).then(jsonResponse);
}
function reportError(run,error){
  if(run.error)return;
  run.error=error instanceof Error?error:new Error(String(error));
  self.postMessage({type:'error',message:run.error.message});
}
function fail(run,error){
  reportError(run,error);
  // An in-flight board transaction still completes before Python releases the session.
  void control(run,'stop').catch(cause=>{reportError(run,cause);});
}
function control(run,action,mode){
  if(action==='stop'){
    run.running=false;run.stopRequested=true;wakeProducer(run);
    if(run.stopTask)return run.stopTask;
  }else if(action==='pause')run.desiredPaused=true;
  else if(action==='resume')run.desiredPaused=false;
  const operation=async()=>{
    await run.sessionReady.promise;
    if(!run.session||run.serverStopped)return;
    if(action!=='stop'&&run.stopRequested)return;
    // Even an early UI resume waits until the initial Python queue is filled.
    if(action==='resume'){
      await run.prefilled.promise;
      if(run.stopRequested)return;
    }
    const reply=await postJson('/api/network/stream/control',
      {session:run.session,action,...(action==='mode'?{mode:Number(mode)}:{})});
    if(action==='pause'&&!run.stopRequested)self.postMessage({type:'paused'});
    wakeProducer(run);
    return reply;
  };
  // A pending pause can take an entire inference; stop must not queue behind it.
  const task=action==='stop'?operation():run.controlTail.then(operation);
  // Keep later controls ordered even if an earlier HTTP request fails.
  run.controlTail=task.catch(()=>{});
  if(action==='stop'){
    run.stopTask=task;
    task.catch(()=>{run.stopFailed=true;wakeProducer(run);});
  }
  return task;
}
async function produce(run){
  const files=run.options.files;
  let index=run.options.index,sequence=0,accepted=0;
  let data=null,sourceMs=0;
  try{
    while(run.running&&(!run.once||accepted<files.length)){
      const entry=files[index];
      if(!data){
        const start=performance.now();
        if(entry.file)data=await entry.file.arrayBuffer();
        else{
          const source=await fetch(entry.sourceUrl,{cache:'no-store'});
          if(!source.ok)throw new Error('读取预设流帧失败: '+(entry.name||'未知文件'));
          data=await source.arrayBuffer();
        }
        sourceMs=performance.now()-start;
        if(!run.running)break;
        if(data.byteLength!==65536)throw new Error('BIN 必须恰好为 65536 字节');
      }
      const query=new URLSearchParams({session:run.session,name:entry.name||entry.file.name,
        path:entry.path,index:String(index),sequence:String(sequence)});
      const response=await fetch('/api/network/stream/enqueue?'+query,{method:'POST',
        headers:{'Content-Type':'application/octet-stream'},body:data});
      const reply=await response.json();
      if(!run.running)break;
      if(response.status===409&&reply.full){await waitForSpace(run);continue;}
      if(!response.ok||!reply.ok)throw new Error(reply.log||reply.error||'缓存输入帧失败');
      run.sourceTimes.set(sequence,sourceMs);
      // Results may be discarded by the bounded Python preview queue.
      if(run.sourceTimes.size>32)run.sourceTimes.delete(run.sourceTimes.keys().next().value);
      accepted++;
      if(accepted===run.capacity)run.prefilled.resolve();
      index=run.once?index+1:(index+1)%files.length;sequence++;data=null;
    }
    run.producerDone=true;
  }finally{run.prefilled.resolve();}
}
function serverTimings(response){
  const result={},text=response.headers?response.headers.get('Server-Timing')||'':'';
  for(const part of text.split(',')){
    const match=part.trim().match(/^([a-z_]+);dur=([\d.]+)$/);
    if(match)result[match[1]]=Number(match[2]);
  }
  return result;
}
async function consume(run){
  while(!run.serverStopped){
    if(run.stopFailed)return;
    const started=performance.now();
    const response=await fetch('/api/network/stream/result?'+new URLSearchParams({session:run.session}));
    const headersReceived=performance.now();
    if(response.status===204)continue;
    const contentType=response.headers?response.headers.get('Content-Type')||'':'';
    if(!response.ok||contentType.includes('application/json')){
      const reply=await response.json();
      if(reply.stopped){
        run.serverStopped=true;run.running=false;wakeProducer(run);
        if(reply.error)throw new Error(reply.error);
        if(!response.ok||!reply.ok)throw new Error(reply.log||'流传输失败');
        break;
      }
      throw new Error(reply.log||reply.error||'流状态响应错误');
    }
    const body=await response.arrayBuffer(),bodyReceived=performance.now();
    if(body.byteLength<4)throw new Error('回传响应不完整');
    const size=new DataView(body).getUint32(0);
    if(size>65536||body.byteLength!==4+size+65536+262144)throw new Error('回传 BIN 长度错误');
    const metadata=JSON.parse(new TextDecoder().decode(new Uint8Array(body,4,size)));
    const stream=metadata.stream;
    if(!metadata.ok||!stream||!Number.isInteger(stream.index)||
       stream.index<0||stream.index>=run.options.files.length)throw new Error('回传帧信息错误');
    // The server chooses mode when dispatching; queued frames may predate a mode change.
    const source=body.slice(4+size,4+size+65536),raw=body.slice(4+size+65536);
    const now=Date.now(),decoded=performance.now(),server=serverTimings(response);
    metadata.timings_ms=metadata.timings_ms||{};
    metadata.timings_ms.browser={source_ms:run.sourceTimes.get(stream.sequence)||0,
      http_ms:bodyReceived-started,headers_ms:headersReceived-started,
      body_ms:bodyReceived-headersReceived,decode_ms:decoded-bodyReceived,
      http_overhead_ms:Math.max(0,bodyReceived-started-(server.handler||0)),server};
    run.sourceTimes.delete(stream.sequence);
    if(Array.isArray(stream.completed_times_ms))run.times=stream.completed_times_ms.slice();
    else run.times.push(Number.isFinite(stream.completed_at)?stream.completed_at*1000:now);
    run.times=run.times.filter(time=>time>=now-10000);
    run.last={metadata,index:(stream.index+1)%run.options.files.length,
      completed:stream.completed,times:run.times.slice(),frameMs:stream.frame_ms};
    // Source bytes accompany the completed result, never a future prefetched input.
    publish('source',{raw:source,folder:run.options.folder,index:stream.index});
    publish('result',{raw,...run.last});
    wakeProducer(run);
    if(run.once&&stream.completed>=run.options.files.length){
      run.running=false;
      await control(run,'stop');
    }
  }
}
async function drainAfterError(run){
  // A decoding error must still let the active board frame finish before the UI
  // can start another session. Discard its preview while waiting for shutdown.
  await run.stopTask;
  while(!run.serverStopped){
    const response=await fetch('/api/network/stream/result?'+new URLSearchParams({session:run.session}));
    if(response.status===204)continue;
    const contentType=response.headers?response.headers.get('Content-Type')||'':'';
    if(contentType.includes('application/json')||!response.ok){
      const reply=await response.json();
      if(!reply.stopped)throw new Error(reply.log||reply.error||'流停止失败');
      run.serverStopped=true;
    }else await response.arrayBuffer();
  }
}
async function loop(options){
  if(activeRun)return;
  const run={options,running:true,session:null,serverStopped:false,stopRequested:false,
    desiredPaused:false,sessionReady:gate(),prefilled:gate(),controlTail:Promise.resolve(),
    sourceTimes:new Map(),times:(options.times||[]).slice(),last:null,error:null,
    once:options.workflow==='segmentation',producerDone:false};
  activeRun=run;
  try{
    if(!options.files||!options.files.length)throw new Error('流文件夹中没有 BIN 图像');
    const session=await postJson('/api/network/stream/start',{folder:options.folder,mode:Number(options.mode),
      source_fps:options.sourceFps||30,workflow:options.workflow||null,dataset:options.dataset,
      patient:options.patient,mask_transparency:options.maskTransparency});
    run.session=session.session;run.capacity=session.capacity;
    if(!run.session||!Number.isInteger(run.capacity)||run.capacity<1)throw new Error('流缓存配置错误');
    run.sessionReady.resolve();
    const producer=produce(run).catch(error=>{fail(run,error);});
    const consumer=consume(run).catch(async error=>{
      fail(run,error);
      try{await drainAfterError(run);}catch(cause){reportError(run,cause);}
    });
    await run.prefilled.promise;
    if(run.running&&!run.desiredPaused)void control(run,'resume').catch(error=>{fail(run,error);});
    await Promise.all([producer,consumer]);
  }catch(error){reportError(run,error);}
  finally{
    run.running=false;run.sessionReady.resolve();run.prefilled.resolve();wakeProducer(run);
    if(run.session&&!run.serverStopped){
      try{await control(run,'stop');}catch(error){reportError(run,error);}
    }
    await run.controlTail;
    for(const [type,channel] of Object.entries(channels)){
      if(channel.latest){const latest=channel.latest;channel.latest=null;self.postMessage({type,...latest},[latest.raw]);}
    }
    activeRun=null;
    self.postMessage({type:'stopped',last:run.last});
  }
}
self.onmessage=event=>{
  const message=event.data;
  if(message.type==='start')void loop(message);
  else if(message.type==='preview_consumed')previewConsumed(message.kind);
  else if(activeRun&&['stop','pause','resume','mode'].includes(message.type)){
    const run=activeRun;
    void control(run,message.type,message.mode).catch(error=>{fail(run,error);});
  }
};

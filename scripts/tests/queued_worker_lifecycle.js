// Exercise worker lifecycle races with a bounded, autonomous mock Python session.
const assert=require('assert'),fs=require('fs'),path=require('path'),vm=require('vm');
const script=fs.readFileSync(path.join(__dirname,'../../network/host/assets/stream_worker.js'),'utf8');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check){
  const expires=Date.now()+3000;
  while(!check()){if(Date.now()>expires)throw new Error('worker lifecycle timed out');await sleep(2);}
}
function createHarness({delayStart=false,corrupt=false,stopAfter=3}={}){
  const sent=[],accepted=[],controls=[],pending=[],results=[];
  let startResolve,started=false,paused=true,stopped=false,busy=false,completed=0,mode=0;
  const startGate=delayStart?new Promise(resolve=>{startResolve=resolve;}):Promise.resolve();
  const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json'}});
  const send=data=>context.self.onmessage({data});
  function pack(frame){
    const metadata={ok:true,mode,job:completed,timings_ms:{},readback:{},stream:{
      index:frame.index,sequence:frame.sequence,completed,frame_ms:5,completed_at:Date.now()/1000}};
    const text=new TextEncoder().encode(JSON.stringify(metadata)),body=new Uint8Array(4+text.length+65536+262144);
    new DataView(body.buffer).setUint32(0,text.length);body.set(text,4);
    body.fill(frame.value,4+text.length,4+text.length+65536);
    body.fill(frame.value+10,4+text.length+65536);
    return body;
  }
  function pump(){
    if(paused||stopped||busy||!pending.length)return;
    const frame=pending.shift();busy=true;
    setTimeout(()=>{
      completed++;
      results.push(corrupt?new Uint8Array(4):pack(frame));busy=false;
      if(stopAfter&&completed===stopAfter)send({type:'stop'});
      setTimeout(pump,0);
    },5);
  }
  const context=vm.createContext({URLSearchParams,TextDecoder,DataView,Uint8Array,performance,
    setTimeout,clearTimeout,self:{postMessage(message,transfer){sent.push(structuredClone(message,{transfer}));}},
    fetch:async(url,options={})=>{
      const parsed=new URL(url,'http://local');
      if(parsed.pathname.endsWith('/start')){
        await startGate;started=true;return json({ok:true,session:'token',capacity:4});
      }
      if(parsed.pathname.endsWith('/enqueue')){
        if(stopped)return json({ok:false,stopped:true,error:'stopped'},409);
        if(pending.length===4)return json({ok:false,full:true},409);
        const frame={index:Number(parsed.searchParams.get('index')),
          sequence:Number(parsed.searchParams.get('sequence')),value:new Uint8Array(options.body)[0]};
        pending.push(frame);accepted.push(frame);pump();return json({ok:true});
      }
      if(parsed.pathname.endsWith('/control')){
        const request=JSON.parse(options.body);controls.push({action:request.action,pending:pending.length});
        if(request.action==='pause'||request.action==='stop'){
          paused=true;
          if(request.action==='stop'){stopped=true;pending.length=0;}
          while(busy)await sleep(1);
        }else if(request.action==='resume'){paused=false;pump();}
        else if(request.action==='mode')mode=request.mode;
        return json({ok:true,stopped});
      }
      if(parsed.pathname.endsWith('/result')){
        while(!results.length&&(!stopped||busy))await sleep(1);
        if(results.length)return new Response(results.shift(),{headers:{'Content-Type':'application/octet-stream'}});
        return json({ok:true,stopped:true});
      }
      throw new Error('unexpected '+url);
    }});
  vm.runInContext(script,context);
  const files=[1,2].map(value=>({path:value+'.bin',file:{name:value+'.bin',
    arrayBuffer:async()=>new Uint8Array(65536).fill(value).buffer}}));
  return {sent,accepted,controls,send,files,startResolve:()=>startResolve(),
    get busy(){return busy;},get completed(){return completed;},get started(){return started;},
    start(){send({type:'start',files,index:0,folder:'CaseA',mode:0});},
    done:()=>until(()=>sent.some(message=>message.type==='stopped'))};
}
(async()=>{
  const flow=createHarness();flow.start();flow.send({type:'mode',mode:3});await flow.done();
  assert.deepStrictEqual(flow.sent.filter(message=>message.type==='error'),[]);
  assert.strictEqual(flow.controls.find(request=>request.action==='resume').pending,4,
    'initial dispatch starts only after four Python input frames are cached');
  assert.deepStrictEqual(flow.accepted.slice(0,4).map(frame=>frame.value),[1,2,1,2]);
  const result=flow.sent.filter(message=>message.type==='result').at(-1);
  const source=flow.sent.filter(message=>message.type==='source').at(-1);
  assert.strictEqual(result.completed,3);
  assert.strictEqual(result.metadata.mode,3,'dispatch-time mode may differ from initial worker mode');
  assert.strictEqual(new Uint8Array(result.raw)[0],new Uint8Array(source.raw)[0]+10);
  assert(flow.sent.filter(message=>message.type==='result').length<=2,
    'withheld preview acknowledgements cannot create an unbounded message queue');

  const startup=createHarness({delayStart:true});startup.start();startup.send({type:'stop'});
  startup.startResolve();await startup.done();
  assert.strictEqual(startup.accepted.length,0);
  assert.deepStrictEqual(startup.controls.map(request=>request.action),['stop']);
  assert(!startup.sent.some(message=>message.type==='error'));

  const paused=createHarness({stopAfter:0});paused.start();await until(()=>paused.busy);
  paused.send({type:'pause'});await until(()=>paused.sent.some(message=>message.type==='paused'));
  assert.strictEqual(paused.busy,false,'pause notification follows the in-flight frame boundary');
  const boundary=paused.completed;await sleep(15);assert.strictEqual(paused.completed,boundary);
  paused.send({type:'stop'});await paused.done();
  assert(!paused.sent.some(message=>message.type==='error'));

  const broken=createHarness({corrupt:true,stopAfter:0});broken.start();await broken.done();
  assert.strictEqual(broken.sent.filter(message=>message.type==='error').length,1);
  assert(broken.controls.some(request=>request.action==='stop'));
  assert(!broken.sent.some(message=>message.type==='result'));
  console.log('QUEUED_WORKER_LIFECYCLE_OK: prefill, paired previews, startup stop, boundary pause, corrupt result cleanup');
})().catch(error=>{console.error(error);process.exitCode=1;});

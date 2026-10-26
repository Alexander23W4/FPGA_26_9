// Run the real UI and dedicated-worker script against HTTP/TCP with repaint deliberately withheld.
const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(process.argv[2],'utf8');
const script=source.match(/TAIL_SCRIPT = r"""<script>([\s\S]*?)<\/script>"""/)[1];
const assets=path.join(path.dirname(process.argv[2]),'assets');
const elements={},alerts=[],calls=[],paints=[],parameters=[],returned=[],accepted=[],delivered=[];
let uploads=0,ctx,controlsStarted=false,controlsDone=false,stopSent=false;
const expectFailure=process.argv[4]==='failure';
const medical=(process.argv[4]||'').startsWith('medical');let medicalAnalysisStarted=false;
const resume=process.argv[4]==='medical-resume';let confirmAnswer=false;const confirmations=[];
const transient=process.argv[4]==='transient';let transientInjected=false;
const loseFinal=process.argv[4]==='medical-loss';let finalLost=false;
function element(){
  const context={createImageData:()=>({data:new Uint8ClampedArray(256*256*4)}),
    clearRect(){},putImageData(image){this.last=image.data.slice();this.writes=(this.writes||0)+1;}};
  return {value:'0',textContent:'',hidden:false,disabled:false,src:'',attributes:{},listeners:{},files:[],
    get selectedOptions(){return [{textContent:'去噪处理'}];},getContext:()=>context,
    addEventListener(type,fn){(this.listeners[type]||=[]).push(fn);},
    setAttribute(k,v){this.attributes[k]=v;},getAttribute(k){return this.attributes[k];},
    removeAttribute(k){delete this.attributes[k];},replaceChildren(){},append(){},appendChild(){},
    querySelectorAll:()=>[],click(){}};
}
const document={getElementById:id=>elements[id]||=element(),querySelector:element,querySelectorAll:()=>[],
  createElement:element,createDocumentFragment:element,createTextNode:text=>({textContent:text}),addEventListener(){},
  body:{classList:{toggle(){},contains:()=>false,remove(){}}}};
for(const [id,value] of Object.entries({systemMode:medical?'medical':'processing',medicalOutputMode:'1',maskOpacity:'45',sourceFps:'30',width:'255',center:'128'}))document.getElementById(id).value=value;
async function emit(id,event){for(const fn of elements[id].listeners[event]||[])await fn({target:elements[id],currentTarget:elements[id]});}
class ScriptWorker{
  constructor(url){
    assert.strictEqual(url,'/assets/stream_worker.js');this.terminated=false;
    const self={postMessage:(message,transfer)=>{
      const copy=structuredClone(message,{transfer:transfer||[]});
      if(copy.type==='result')delivered.push(copy.metadata);
      queueMicrotask(()=>{if(!this.terminated)this.onmessage({data:copy});});
    }};
    this.env=vm.createContext({self,URLSearchParams,TextDecoder,DataView,Uint8Array,performance,Date,setTimeout,clearTimeout,
      fetch:async(url,options)=>{
        calls.push(url);
        if(transient&&!transientInjected&&url.startsWith('/api/network/stream/result')){
          transientInjected=true;throw new TypeError('Failed to fetch');
        }
        const response=await fetch(process.argv[3]+url,options);
        if(url.startsWith('/api/network/stream/enqueue')&&response.ok){
          uploads++;accepted.push(new URL('http://x'+url));
        }
        if(!url.startsWith('/api/network/stream/result')||response.status!==200||
           !response.headers.get('Content-Type').startsWith('application/octet-stream'))return response;
        const bytes=await response.clone().arrayBuffer();
        const size=new DataView(bytes).getUint32(0);
        const metadata=JSON.parse(new TextDecoder().decode(new Uint8Array(bytes,4,size)));
        returned.push(metadata);
        if(loseFinal&&!medicalAnalysisStarted&&!finalLost&&metadata.stream.completed===3){
          finalLost=true;
          response.arrayBuffer=async()=>{throw new TypeError('Failed to fetch final result body');};
        }
        if(!controlsStarted&&!expectFailure&&!medical){
          controlsStarted=true;
          elements.thresholdMode.setAttribute('aria-checked','true');elements.threshold.value='77';
          parameters.push(ctx.dshThrUpdate());
          elements.maskOpacity.value='35';parameters.push(emit('maskOpacityUpdate','click'));
          elements.fpgaOutputMode.value='3';parameters.push(emit('fpgaOutputMode','change'));
          elements.hdmiOutputToggle.setAttribute('aria-checked','true');
          const hdmiOff=emit('hdmiOutputToggle','click');
          parameters.push(hdmiOff);
          parameters.push(hdmiOff.then(()=>emit('hdmiOutputToggle','click')));
          Promise.all(parameters).then(()=>{controlsDone=true;});
        }
        if(!stopSent&&controlsDone&&metadata.stream.completed>=3&&metadata.mode===3&&
           metadata.readback.actual_threshold===77&&metadata.readback.mask_transparency===35){
          stopSent=true;ctx.dshStopStream();
        }
        if(medical&&medicalAnalysisStarted&&!stopSent&&metadata.stream.completed>=3){stopSent=true;ctx.dshStopStream();}
        return response;
      }});
    vm.runInContext(fs.readFileSync(path.join(assets,'stream_worker.js'),'utf8'),this.env);
  }
  postMessage(message){queueMicrotask(()=>{if(!this.terminated)this.env.self.onmessage({data:message});});}
  terminate(){this.terminated=true;}
}
ctx=vm.createContext({document,URLSearchParams,performance,Worker:ScriptWorker,Uint8Array,Uint8ClampedArray,Date,
  ImageData:class{constructor(data,width,height){this.data=data;this.width=width;this.height=height;}},
  setInterval(){},setTimeout,requestAnimationFrame:fn=>paints.push(fn),
  window:{matchMedia:()=>({matches:false,addEventListener(){}})},
  alert:text=>alerts.push(text),confirm:text=>{confirmations.push(text);return confirmAnswer;},
  fetch:(url,options)=>{calls.push(url);return fetch(process.argv[3]+url,options);}});
vm.runInContext(fs.readFileSync(path.join(assets,'heartcare.js'),'utf8'),ctx);
vm.runInContext(script,ctx);
function frame(name,value){return {name,size:65536,webkitRelativePath:'CaseA/'+name,
  arrayBuffer:async()=>new Uint8Array(65536).fill(value).buffer};}
(async()=>{
  if(medical){
    await ctx.dshSelectMedicalPatient('cardiac');
    assert.strictEqual(vm.runInContext('dshMedicalEntries.length',ctx),3);
    assert.strictEqual(vm.runInContext('dshMedicalStatus.complete',ctx),false);
    if(resume)assert.strictEqual(vm.runInContext('dshMedicalStatus.completed',ctx),1);
    assert.strictEqual(elements.medicalAnalyze.disabled,true);
    await ctx.dshStartStream(null,null,'segmentation');
    assert.deepStrictEqual(alerts,[]);
    assert.strictEqual(uploads,resume?2:3,'finite segmentation must upload each missing source exactly once');
    assert.strictEqual(vm.runInContext('dshMedicalStatus.complete',ctx),true);
    assert.strictEqual(elements.medicalAnalyze.disabled,false);
    assert.match(elements.medicalCacheLamp.className,/cache-complete/);
    if(loseFinal)assert(finalLost,'the last preview response must actually be interrupted');
    if(resume){
      assert.strictEqual(uploads,2,'only missing frames may be uploaded for segmentation');
      assert.deepStrictEqual(accepted.map(url=>url.searchParams.get('name')),['frame1.bin','frame2.bin']);
      assert.match(elements.medicalCacheLamp.textContent,/已完成/);
    }
    medicalAnalysisStarted=true;
    await ctx.dshStartStream(null,null,'analysis');
    assert.deepStrictEqual(alerts,[]);
    assert(returned.at(-1).stream.completed>=3);
    assert(calls.some(url=>url.startsWith('/api/network/medical/cache?')));
    if(resume){
      await ctx.dshClearMedicalCache();
      assert(!calls.some(url=>url==='/api/network/medical/clear'),'cancelled confirmation must not send a deletion');
      confirmAnswer=true;await ctx.dshClearMedicalCache();
      assert.strictEqual(confirmations.length,2);
      assert.strictEqual(vm.runInContext('dshMedicalStatus.completed',ctx),0);
      assert.strictEqual(elements.medicalAnalyze.disabled,true);
      console.log('MEDICAL_GUI_RESUME_CLEAR_OK');
    }
    console.log('MEDICAL_GUI_CACHE_OK: patient selection, finite two-pass segmentation, green completion, cached looping analysis, previews independent of paint');
    return;
  }
  await ctx.dshStartStream([frame('002.bin',2),frame('001.bin',1)]);await Promise.all(parameters);
  if(expectFailure){
    assert(uploads>=1&&uploads<=12,'failure may retain at most four pending and eight in-flight inputs');
    assert.strictEqual(returned.length,0);
    assert.strictEqual(vm.runInContext('dshStreamCompleted',ctx),0);
    assert.strictEqual(vm.runInContext('dshStreamIndex',ctx),0);
    assert.strictEqual(alerts.length,1);assert.match(alerts[0],/CRC/);
    while(paints.length)paints.shift()();
    assert.strictEqual(elements.streamProcessedCanvas.getContext('2d').writes,undefined);
    console.log('FAST_GUI_FAILURE_OK: no next upload or cached preview after a corrupt return');return;
  }
  assert.deepStrictEqual(alerts,[]);
  assert(uploads>=4,'the initial four frames must be cached before board execution');
  assert(returned.at(-1).stream.completed>=3);
  assert.strictEqual(vm.runInContext('dshStreamCompleted',ctx),returned.at(-1).stream.completed);
  assert.strictEqual(vm.runInContext('dshStreamIndex',ctx),(returned.at(-1).stream.index+1)%2);
  assert.strictEqual(elements.streamProcessedCanvas.getContext('2d').writes,undefined,
    'queued transfers must finish while GUI repaint is withheld');
  assert(!calls.some(url=>url.startsWith('/api/image')||url.startsWith('/api/network/transfer')));
  assert(!calls.some(url=>url.startsWith('/api/network/frame')));
  assert.deepStrictEqual(accepted.slice(0,4).map(url=>url.searchParams.get('name')),
    ['001.bin','002.bin','001.bin','002.bin']);
  accepted.forEach((url,sequence)=>assert.strictEqual(Number(url.searchParams.get('sequence')),sequence));
  assert.strictEqual(returned[0].mode,0);
  assert.strictEqual(returned.at(-1).mode,3);
  assert.strictEqual(returned.at(-1).readback.actual_threshold,77);
  assert.strictEqual(returned.at(-1).readback.mask_transparency,35);
  assert.strictEqual(elements.hdmiOutputToggle.getAttribute('aria-checked'),'true');
  assert.deepStrictEqual(calls.filter(url=>url.startsWith('/api/serial/hdmi_enable')),
    ['/api/serial/hdmi_enable?value=0','/api/serial/hdmi_enable?value=1']);
  assert.strictEqual(elements.dshRbThr.textContent,77);
  assert.strictEqual(elements.dshRbAlpha.textContent,'35%');
  assert.match(elements.streamNetConfig.textContent,/65535 B/);
  assert.match(elements.streamPsTiming.textContent,/输出CRC 2.50 ms/);
  assert.match(elements.streamPcTiming.textContent,/结果HTTP/);
  const browser=delivered.at(-1).timings_ms.browser;
  for(const key of ['source_ms','http_ms','headers_ms','body_ms','decode_ms','http_overhead_ms'])
    assert(Number.isFinite(browser[key])&&browser[key]>=0,key+' must remain measured in the worker');
  assert(browser.server&&typeof browser.server==='object');
  assert(browser.server.handler>=browser.server.preview_wait&&browser.server.preview_wait>=0);
  while(paints.length)paints.shift()();
  const canvas=elements.streamProcessedCanvas,rendered=canvas.getContext('2d').last;
  assert.strictEqual(canvas.attributes['data-result-job'],String(returned.at(-1).job));
  assert.strictEqual(rendered[3],255);assert.strictEqual(rendered[0],33);
  assert.strictEqual(elements.streamOriginalCanvas.getContext('2d').last[0],returned.at(-1).stream.index+1);
  assert.strictEqual(elements.comparisonProcessedLabel.textContent,'叠加掩膜流');
  // A later status-only response cannot repaint a cached image or clear either Canvas.
  const writes=canvas.getContext('2d').writes;
  await ctx.poll();
  assert(calls.includes('/api/network/state'));
  assert.strictEqual(canvas.getContext('2d').writes,writes);
  assert.strictEqual(elements.chooseStream.textContent,'选择流文件夹');
  const requests=calls.length,bad=frame('003.bin',3);bad.size=65535;
  await ctx.dshStartStream([frame('001.bin',1),bad]);
  assert.strictEqual(calls.length,requests);assert.strictEqual(alerts.length,1);assert.match(alerts[0],/65536/);
  console.log('FAST_GUI_OK: worker upload, no repaint barrier, direct BIN Canvas, boundary controls, fresh metrics, stop, metadata-only poll');
})().catch(error=>{console.error(error);process.exitCode=1;});

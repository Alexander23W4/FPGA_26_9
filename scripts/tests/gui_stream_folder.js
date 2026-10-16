// Actual folder/control handlers -> HTTP -> TCP -> fresh saved results.
const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(process.argv[2],'utf8');
const script=source.match(/TAIL_SCRIPT = r"""<script>([\s\S]*?)<\/script>"""/)[1];
const elements={},alerts=[],calls=[],completed=[],parameters=[];
const expectFailure=process.argv[4]==='failure';
const names=['去噪处理','轮廓处理','二值掩膜处理','叠加掩膜处理','伪彩色热力图处理','全显示'];
function element(){return {value:'0',textContent:'',disabled:false,_src:'',srcWrites:0,
  get src(){return this._src;},set src(value){this._src=value;this.srcWrites++;},
  hidden:false,listeners:{},attributes:{},
  get selectedOptions(){return [{textContent:names[Number(this.value)]||this.value}];},
  addEventListener(event,fn){(this.listeners[event]||=[]).push(fn);},
  setAttribute(k,v){this.attributes[k]=v;},getAttribute(k){return this.attributes[k];},
  removeAttribute(k){delete this.attributes[k];if(k==='src')this.src='';},
  replaceChildren(...children){this.children=children;},append(){},appendChild(){},click(){},querySelectorAll(){return [];}};}
const document={getElementById(id){return elements[id]||=element();},
  querySelector:element,querySelectorAll:()=>[],addEventListener(){},createElement:element,
  createDocumentFragment:element,createTextNode:text=>({textContent:text}),
  body:{classList:{contains:()=>false,toggle(){},remove(){}}}};
document.getElementById('systemMode').value='processing';
document.getElementById('width').value='255';document.getElementById('center').value='128';
let uploads=0,ctx;
async function emit(id,event){const target=elements[id];for(const fn of target.listeners[event]||[])await fn({target,currentTarget:target});}
const realFetch=async(url,options)=>{
  calls.push(url);
  const streamUpload=url.startsWith('/api/network/transfer')&&url.includes('stream=1');
  const oldRight=elements.comparisonProcessed.src;
  const responsePromise=fetch(process.argv[3]+url,options);
  if(streamUpload){
    uploads++;
    assert.strictEqual(elements.fullDisplayOption.disabled,true);
    assert.strictEqual(elements.chooseStream.disabled,false,'stop stays available while a frame is in flight');
    if(uploads===1&&!expectFailure){
      assert.match(url,/mode=0$/,'stream selection must leave disabled full-display mode');
      elements.thresholdMode.setAttribute('aria-checked','true');elements.threshold.value='77';
      parameters.push(ctx.dshThrUpdate());
      elements.maskOpacity.value='35';parameters.push(emit('maskOpacityUpdate','click'));
      elements.fpgaOutputMode.value='3';parameters.push(emit('fpgaOutputMode','change'));
      assert.strictEqual(elements.comparisonProcessed.src,oldRight,'mode choice cannot display a cached result');
    }
  }
  const response=await responsePromise;
  if(streamUpload){
    const result=await response.clone().json();
    if(expectFailure){
      assert.strictEqual(result.ok,false);assert.match(result.log,/CRC/);
      assert.strictEqual(elements.comparisonProcessed.src,oldRight,'a failed return cannot display an old disk file');
      return response;
    }
    assert.strictEqual(result.ok,true,JSON.stringify(result));
    assert.strictEqual(result.frames,1);assert.strictEqual(result.results.length,1);
    assert.strictEqual(result.readback.ok,true,'each completed frame requires fresh register readback');
    assert.strictEqual(elements.comparisonProcessed.src,oldRight,'HTTP/TCP receive must precede the repaint');
    completed.push(result);
    if(completed.length===3)ctx.dshStopStream();
  }
  return response;
};
ctx=vm.createContext({document,URLSearchParams,setTimeout,setInterval(){},
  window:{matchMedia:()=>({matches:false,addEventListener(){}})},alert:value=>alerts.push(value),fetch:realFetch});
vm.runInContext(fs.readFileSync(path.join(path.dirname(process.argv[2]),'assets/heartcare.js'),'utf8'),ctx);
vm.runInContext(script,ctx);
function frame(name,value){const input=new Uint8Array(65536).fill(value);return {
  name,size:65536,webkitRelativePath:'CaseA/'+name,arrayBuffer:async()=>input.buffer};}
(async()=>{
  // The directory picker deliberately supplies reverse order and an unrelated file.
  if(expectFailure){
    elements.fpgaOutputMode.value='0';
    ctx.renderProcessedResults({'0':{mode:0,image:'previous-confirmed',job:999}},999);
  }
  elements.fpgaOutputMode.value='5';
  elements.streamFolder.files=[frame('002.bin',2),{name:'notes.txt',size:3,webkitRelativePath:'CaseA/notes.txt'},frame('001.bin',1)];
  await emit('streamFolder','change');await Promise.all(parameters);
  if(expectFailure){
    assert.strictEqual(calls.filter(url=>url.startsWith('/api/network/')).length,1,'a failed return must stop before the next source');
    assert.strictEqual(alerts.length,1);assert.match(alerts[0],/CRC/);
    assert.strictEqual(elements.comparisonProcessed.src,'data:image/png;base64,previous-confirmed');
    assert.strictEqual(vm.runInContext('dshStreamRunning',ctx),false);
    assert.strictEqual(vm.runInContext('dshStreamIndex',ctx),0,'a failed frame remains pending for an explicit retry');
    console.log('GUI_STREAM_FAILURE_OK: no next upload or stale display after CRC failure');return;
  }
  assert.deepStrictEqual(alerts,[]);
  const network=calls.filter(url=>url.startsWith('/api/network/'));
  assert.strictEqual(network.length,3,'queued controls must not send any additional frame or render request');
  assert.deepStrictEqual(network.map(url=>new URL('http://test'+url).searchParams.get('name')),['001.bin','002.bin','001.bin']);
  assert.deepStrictEqual(network.map(url=>new URL('http://test'+url).searchParams.get('mode')),['0','3','3']);
  const firstReturn=calls.findIndex(url=>url.includes('name=002.bin'));
  for(const prefix of ['/api/serial/threshold?','/api/serial/mask_transparency?']){
    const index=calls.findIndex(url=>url.startsWith(prefix));assert(index>0&&index<firstReturn,'parameters apply before reading the next source');
  }
  assert.strictEqual(elements.imageName.textContent,'CaseA');
  assert.strictEqual(elements.comparisonOriginalLabel.textContent,'原流');
  assert.strictEqual(elements.comparisonProcessedLabel.textContent,'叠加掩膜流');
  assert.strictEqual(elements.comparisonProcessed.src,'data:image/png;base64,'+completed.at(-1).results[0].image);
  assert.strictEqual(elements.comparisonProcessed.attributes['data-result-job'],String(completed.at(-1).results[0].job));
  assert.notStrictEqual(completed[0].results[0].image,completed[2].results[0].image,'same source filename must receive a freshly generated result');
  assert.strictEqual(completed[0].results[0].files.bin,completed[2].results[0].files.bin,'repeat source and different modes share one output filename');
  assert.strictEqual(elements.dshRbThr.textContent,77);
  assert.strictEqual(elements.dshRbAlpha.textContent,'35%');
  assert.strictEqual(elements.processingStatus.textContent,'');
  assert.strictEqual(elements.chooseStream.textContent,'选择流文件夹');
  assert.strictEqual(elements.chooseImage.disabled,false);
  assert.strictEqual(vm.runInContext('dshStreamRunning',ctx),false);
  assert.strictEqual(elements.fullDisplayOption.disabled,true,'full display stays unavailable for a selected stream');
  // A stale poll is unable to replace the newest returned frame or original.
  const right=elements.comparisonProcessed.src,left=elements.comparisonOriginal.src;
  ctx.renderProcessedResults({'0':{mode:0,image:'stale',job:999}},completed[0].results_revision);
  ctx.showOriginalFrame('stale','OldFolder',completed[0].source_revision);
  assert.strictEqual(elements.comparisonProcessed.src,right);assert.strictEqual(elements.comparisonOriginal.src,left);
  // A fresh return with identical pixels still commits its new job to the preview.
  const writes=elements.comparisonProcessed.srcWrites,last=completed.at(-1).results[0];
  ctx.renderProcessedResults({'3':{...last,job:last.job+1}},completed.at(-1).results_revision+1);
  assert.strictEqual(elements.comparisonProcessed.srcWrites,writes+1);
  // Invalid BIN files fail preflight, before sending the otherwise valid first frame.
  const count=calls.length,bad=frame('003.bin',3);bad.size=65535;
  await ctx.dshStartStream([frame('001.bin',1),bad]);
  assert.strictEqual(calls.length,count);assert.strictEqual(alerts.length,1);assert.match(alerts[0],/65536/);
  console.log('GUI_STREAM_HTTP_OK: folder loop, fresh result commits, ACK/readback ordering, queued controls, overwrite, stop, stale poll and preflight');
})().catch(error=>{console.error(error);process.exitCode=1;});

// Run the real UI and dedicated-worker script against HTTP/TCP with repaint deliberately withheld.
const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(process.argv[2],'utf8');
const script=source.match(/TAIL_SCRIPT = r"""<script>([\s\S]*?)<\/script>"""/)[1];
const assets=path.join(path.dirname(process.argv[2]),'assets');
const elements={},alerts=[],calls=[],paints=[],parameters=[],returned=[];
let uploads=0,ctx;
const expectFailure=process.argv[4]==='failure';
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
for(const [id,value] of Object.entries({systemMode:'processing',width:'255',center:'128'}))document.getElementById(id).value=value;
async function emit(id,event){for(const fn of elements[id].listeners[event]||[])await fn({target:elements[id],currentTarget:elements[id]});}
class ScriptWorker{
  constructor(url){
    assert.strictEqual(url,'/assets/stream_worker.js');this.terminated=false;
    const self={postMessage:(message,transfer)=>{
      const copy=structuredClone(message,{transfer:transfer||[]});
      queueMicrotask(()=>{if(!this.terminated)this.onmessage({data:copy});});
    }};
    this.env=vm.createContext({self,URLSearchParams,TextDecoder,DataView,Uint8Array,performance,
      fetch:async(url,options)=>{
        calls.push(url);uploads++;
        const pending=fetch(process.argv[3]+url,options);
        if(uploads===1&&!expectFailure){
          elements.thresholdMode.setAttribute('aria-checked','true');elements.threshold.value='77';
          parameters.push(ctx.dshThrUpdate());
          elements.maskOpacity.value='35';parameters.push(emit('maskOpacityUpdate','click'));
          elements.fpgaOutputMode.value='3';parameters.push(emit('fpgaOutputMode','change'));
        }
        const response=await pending;
        if(!response.ok)return response;
        const bytes=await response.clone().arrayBuffer();
        const size=new DataView(bytes).getUint32(0);
        returned.push(JSON.parse(new TextDecoder().decode(new Uint8Array(bytes,4,size))));
        if(uploads===3)ctx.dshStopStream();
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
  alert:text=>alerts.push(text),fetch:(url,options)=>{calls.push(url);return fetch(process.argv[3]+url,options);}});
vm.runInContext(fs.readFileSync(path.join(assets,'heartcare.js'),'utf8'),ctx);
vm.runInContext(script,ctx);
function frame(name,value){return {name,size:65536,webkitRelativePath:'CaseA/'+name,
  arrayBuffer:async()=>new Uint8Array(65536).fill(value).buffer};}
(async()=>{
  await ctx.dshStartStream([frame('002.bin',2),frame('001.bin',1)]);await Promise.all(parameters);
  if(expectFailure){
    assert.strictEqual(uploads,1);
    assert.strictEqual(vm.runInContext('dshStreamCompleted',ctx),0);
    assert.strictEqual(vm.runInContext('dshStreamIndex',ctx),0);
    assert.strictEqual(alerts.length,1);assert.match(alerts[0],/CRC/);
    while(paints.length)paints.shift()();
    assert.strictEqual(elements.streamProcessedCanvas.getContext('2d').writes,undefined);
    console.log('FAST_GUI_FAILURE_OK: no next upload or cached preview after a corrupt return');return;
  }
  assert.deepStrictEqual(alerts,[]);
  assert.strictEqual(uploads,3);
  assert.strictEqual(vm.runInContext('dshStreamCompleted',ctx),3);
  assert.strictEqual(vm.runInContext('dshStreamIndex',ctx),1);
  assert.strictEqual(elements.streamProcessedCanvas.getContext('2d').writes,undefined,
    'all three transfers must finish while GUI repaint is withheld');
  assert(!calls.some(url=>url.startsWith('/api/image')||url.startsWith('/api/network/transfer')));
  assert.deepStrictEqual(calls.filter(url=>url.startsWith('/api/network/frame')).map(url=>new URL('http://x'+url).searchParams.get('name')),
    ['001.bin','002.bin','001.bin']);
  assert.deepStrictEqual(returned.map(item=>item.mode),[0,3,3]);
  assert.deepStrictEqual(returned.slice(1).map(item=>item.readback.actual_threshold),[77,77]);
  assert.deepStrictEqual(returned.slice(1).map(item=>item.readback.mask_transparency),[35,35]);
  assert.strictEqual(elements.dshRbThr.textContent,77);
  assert.strictEqual(elements.dshRbAlpha.textContent,'35%');
  while(paints.length)paints.shift()();
  const canvas=elements.streamProcessedCanvas,rendered=canvas.getContext('2d').last;
  assert.strictEqual(canvas.attributes['data-result-job'],String(returned.at(-1).job));
  assert.strictEqual(rendered[3],255);assert.strictEqual(rendered[0],33);
  assert.strictEqual(elements.streamOriginalCanvas.getContext('2d').last[0],1);
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

const fs=require('fs'),vm=require('vm'),assert=require('assert');
const elements={},alerts=[],calls=[];
function element(){return {value:'0',textContent:'',src:'',attributes:{},listeners:{},
  get selectedOptions(){return [{textContent:'去噪处理'}];},
  addEventListener(type,fn){(this.listeners[type]||=[]).push(fn);},
  setAttribute(k,v){this.attributes[k]=v;},getAttribute(k){return this.attributes[k];},
  removeAttribute(k){delete this.attributes[k];},appendChild(){},append(){},replaceChildren(){},
  querySelectorAll:()=>[],focus(){}};}
const document={getElementById:id=>elements[id]||=element(),querySelector:element,querySelectorAll:()=>[],
  createElement:element,createDocumentFragment:element,addEventListener(){},
  body:{classList:{toggle(){},remove(){},contains:()=>false}}};
document.getElementById('systemMode').value='processing';
const ctx=vm.createContext({document,performance,URLSearchParams,setInterval(){},
  window:{matchMedia:()=>({matches:false,addEventListener(){}})},alert:text=>alerts.push(text),
  fetch:(url,options)=>{calls.push(url);return fetch(process.argv[3]+url,options);}});
vm.runInContext(fs.readFileSync(process.argv[2],'utf8'),ctx);
async function select(mode){elements.systemMode.value=mode;await elements.systemMode.listeners.change[0]();}
(async()=>{
  await select('medical');
  assert.strictEqual(elements.systemMode.value,'medical');
  await ctx.poll();assert.strictEqual(elements.systemMode.value,'medical','poll must preserve confirmed medical mode');
  await select('processing');assert.strictEqual(elements.systemMode.value,'processing');
  await select('medical'); // Third write is rejected by the mocked PS readback.
  assert.strictEqual(elements.systemMode.value,'processing','failed write must restore previous menu selection');
  assert.strictEqual(alerts.length,1);assert.match(alerts[0],/mismatch/);
  assert.deepStrictEqual(calls.filter(url=>url.startsWith('/api/system_mode')),
    ['/api/system_mode?mode=medical','/api/system_mode?mode=processing','/api/system_mode?mode=medical']);
  console.log('GUI_SYSTEM_MODE_OK');
})().catch(error=>{console.error(error);process.exitCode=1;});

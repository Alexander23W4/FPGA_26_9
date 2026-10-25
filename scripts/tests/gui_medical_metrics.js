const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const root=process.argv[2],assets=path.join(root,'network/host/assets');
const js=fs.readFileSync(path.join(assets,'heartcare.js'),'utf8');
const renderer=js.slice(js.indexOf('function renderMedicalMetrics('),js.indexOf('function renderMetrics('));
const host=fs.readFileSync(path.join(root,'network/host/monitor_network.py'),'utf8');
const tail=host.match(/TAIL_SCRIPT = r"""<script>([\s\S]*?)<\/script>"""/)[1];
const html=fs.readFileSync(path.join(assets,'heartcare.html'),'utf8');
const elements={};
function element(){return {value:'0',textContent:'',files:[],attributes:{},addEventListener(){},
  setAttribute(k,v){this.attributes[k]=v;},getAttribute(k){return this.attributes[k];},replaceChildren(){}};}
const document={getElementById(id){return elements[id]||=element();},querySelectorAll(){return [];},
  createElement:element,createTextNode:text=>({textContent:text})};
const ctx=vm.createContext({document,setInterval(){},updateOverlayControls(){},updatePreviewLayout(){}});
vm.runInContext(renderer+'\n'+tail,ctx);
const readback={ok:true,mode:0,video_mode:0,actual_threshold:128,mask_transparency:45,
  lesion_pixels:0,lesion_mm2:'0.000',medical_volumes_ml:{},medical_ef_percent:{EF_LV:'60.00',EF_RV:'50.00'},
  medical_scale_assumed:true};
for(const chamber of ['LA','RA','LV','RV'])for(const phase of ['EDV','ESV']){
  const key=phase+'_'+chamber;
  assert(html.includes('id="medical'+key+'"'),'missing volume output '+key);
  readback.medical_volumes_ml[key]=phase==='EDV'?'123.45':'49.38';
}
ctx.dshApplyReadback(readback);
assert.equal(elements.medicalEDV_LV.textContent,'123.45');
assert.equal(elements.medicalESV_LV.textContent,'49.38');
assert.equal(elements.medicalEF_LV.textContent,'60.00');
assert.equal(elements.medicalEF_RV.textContent,'50.00');
assert(elements.medicalScaleNote.textContent.includes('按 CAMUS'));
assert(elements.medicalMetricState.textContent.includes('PS 已更新'));
for(const key in readback.medical_volumes_ml)readback.medical_volumes_ml[key]=null;
readback.medical_ef_percent={EF_LV:null,EF_RV:null};
ctx.dshApplyReadback(readback);
assert.equal(elements.medicalEDV_LV.textContent,'—');assert.equal(elements.medicalEF_LV.textContent,'—');
assert(elements.medicalMetricState.textContent.includes('完整心动周期'));
delete readback.medical_volumes_ml;delete readback.medical_ef_percent;
ctx.dshApplyReadback(readback);
assert.equal(elements.medicalEF_RV.textContent,'—');
assert(elements.medicalMetricState.textContent.includes('等待 PS'));
console.log('GUI_MEDICAL_METRICS_OK: eight volumes, two PS EFs, missing phase, old firmware, assumed scale');

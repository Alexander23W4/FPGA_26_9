/* UI presentation and mode navigation. UART actions are supplied by monitor_network. */
const thresholdMode=document.getElementById('thresholdMode');
const threshold=document.getElementById('threshold');
const systemMode=document.getElementById('systemMode');
const menuToggle=document.getElementById('menuToggle');
const systemDrawer=document.getElementById('systemDrawer');
const workspace=document.querySelector('.workspace');
const fpgaOutputMode=document.getElementById('fpgaOutputMode');
const singlePreview=document.getElementById('singlePreview');
const comparisonPreview=document.getElementById('comparisonPreview');
const fullPreview=document.getElementById('fullPreview');
const modeButtons=[...systemDrawer.querySelectorAll('[data-mode]')];
const compactNavigation=window.matchMedia('(max-width:960px)');
let simulateOn=false;
let lastThreshold=null;
let systemModePending=false;
let systemModeRevision=0;
let confirmedSystemMode=systemMode.value;
let processedResults={};
let sourceRevision=-1;
let resultsRevision=-1;
let displayedResultTimes=[];
let hasDisplayedResult=false;
let frameRatePaused=false;
const streamModeLabels=['去噪流','轮廓流','二值掩膜流','叠加掩膜流','伪彩色映射流'];

function isStreamMode(){return typeof dshStreamMode!=='undefined'&&dshStreamMode;}
function isProcessingMode(){return systemMode.value==='processing'||systemMode.value==='medical';}
function fastStreamMode(){return isStreamMode()&&typeof dshFastStream!=='undefined'&&dshFastStream;}
function streamRunning(){return typeof dshStreamRunning!=='undefined'&&dshStreamRunning;}
function transferBusy(){return (typeof dshTransferBusy!=='undefined'&&dshTransferBusy)||streamRunning();}
function refreshFrameRate(now=performance.now()){
  const display=document.getElementById('dshGuiFps');
  if(!display)return;
  if(frameRatePaused){display.textContent='0.00';return;}
  displayedResultTimes=displayedResultTimes.filter(time=>time>=now-10000);
  if(!hasDisplayedResult){display.textContent='—';return;}
  if(displayedResultTimes.length<2){display.textContent='0.00';return;}
  const elapsed=Math.min(10000,now-displayedResultTimes[0]);
  display.textContent=((displayedResultTimes.length-1)*1000/elapsed).toFixed(2);
}
function updateFrameRate(){
  if(frameRatePaused)return;
  displayedResultTimes.push(performance.now());
  hasDisplayedResult=true;
  refreshFrameRate();
}
function resetFrameRate(paused=false){
  displayedResultTimes=[];
  hasDisplayedResult=false;
  frameRatePaused=paused;
  const display=document.getElementById('dshGuiFps');
  if(display)display.textContent=paused?'0.00':'—';
}
function resumeFrameRate(){
  if(frameRatePaused)resetFrameRate();
}
setInterval(refreshFrameRate,500);
function showOriginalFrame(imageBase64,name,revision=null){
  if(Number.isFinite(revision)){
    if(revision<sourceRevision)return false;
    sourceRevision=revision;
  }
  const src='data:image/png;base64,'+imageBase64;
  for(const id of ['view','comparisonOriginal','fullViewOriginal']){
    const image=document.getElementById(id);
    if(image.src!==src)image.src=src;
  }
  document.getElementById('imageName').textContent=name;
  document.getElementById('imageName').title=name;
  return true;
}
function renderProcessedResults(results,revision=null){
  if(fastStreamMode())return false; // Stream BIN goes directly to Canvas; never repaint disk/poll caches.
  if(Number.isFinite(revision)){
    if(revision<resultsRevision)return false;
    resultsRevision=revision;
  }
  processedResults=Object.fromEntries(Object.entries(results||{}).filter(([,result])=>result&&result.image));
  function show(id,result){
    const image=document.getElementById(id);
    image.hidden=!result;
    if(result){
      const src='data:image/png;base64,'+result.image;
      const job=result.job===undefined?'':String(result.job);
      // A new completed transfer must repaint even when its pixel bytes are identical.
      const updated=image.src!==src||image.getAttribute('data-result-job')!==job;
      if(updated)image.src=src;
      image.setAttribute('data-result-job',job);
      image.title=result.files&&result.files.bin||'FPGA 回传结果';
      return updated;
    }else{image.removeAttribute('src');image.removeAttribute('data-result-job');image.title='等待 FPGA 回传';return false;}
  }
  let comparisonResult=processedResults[fpgaOutputMode.value];
  if(isStreamMode()){
    // Requested mode may already have changed while the previous frame is still in flight.
    const entries=Object.entries(processedResults);
    const last=entries.length?entries[entries.length-1]:null;
    comparisonResult=last&&last[1];
    const actualMode=comparisonResult&&comparisonResult.mode!==undefined?Number(comparisonResult.mode):last?Number(last[0]):Number(fpgaOutputMode.value);
    document.getElementById('comparisonProcessedLabel').textContent=systemMode.value==='medical'?'处理流':(streamModeLabels[actualMode]||'处理流');
  }else{
    document.getElementById('comparisonProcessedLabel').textContent=systemMode.value==='medical'?'处理流':fpgaOutputMode.selectedOptions[0].textContent;
  }
  let visibleResultChanged=show('comparisonProcessed',comparisonResult)&&!comparisonPreview.hidden;
  for(let mode=0;mode<5;mode++){
    const changed=show('fullViewMode'+mode,processedResults[String(mode)]);
    if(changed&&!fullPreview.hidden)visibleResultChanged=true;
  }
  if(visibleResultChanged)updateFrameRate();
  return true;
}

function updatePreviewLayout(){
  const processing=isProcessingMode();
  const medical=systemMode.value==='medical';
  const stream=isStreamMode();
  document.getElementById('fullDisplayOption').disabled=stream;
  const showAll=processing&&!medical&&!stream&&fpgaOutputMode.value==='5';
  const showComparison=processing&&!showAll;
  singlePreview.hidden=processing;
  comparisonPreview.hidden=!showComparison;
  fullPreview.hidden=!showAll;
  const fast=fastStreamMode();
  document.getElementById('streamOriginalCanvas').hidden=!fast;
  document.getElementById('streamProcessedCanvas').hidden=!fast;
  if(fast){
    document.getElementById('comparisonOriginal').hidden=true;
    document.getElementById('comparisonProcessed').hidden=true;
  }else document.getElementById('comparisonOriginal').hidden=false;
  document.getElementById('comparisonOriginalLabel').textContent=medical||stream?'原流':'原图';
  document.getElementById('comparisonOriginal').alt=medical||stream?'原流':'原图';
  document.getElementById('comparisonProcessed').alt=medical?'处理流':stream?'FPGA 回传处理流':'FPGA 回传处理图';
  renderProcessedResults(processedResults);
}
fpgaOutputMode.addEventListener('change',updatePreviewLayout);

for(const id of ['threshold','center','width','alpha']){
  const input=document.getElementById(id);
  input.addEventListener('input',()=>document.getElementById(id+'Value').textContent=input.value);
}
const maskOpacity=document.getElementById('maskOpacity');
const maskOpacityUpdate=document.getElementById('maskOpacityUpdate');
const maskOpacityUpdateLabel=maskOpacityUpdate.textContent;
maskOpacity.addEventListener('input',()=>{
  document.getElementById('maskOpacityValue').textContent=maskOpacity.value;
  maskOpacityUpdate.textContent=maskOpacityUpdateLabel;
});
// The network handler changes HDMI state only after a verified register reply.

function updateThresholdControls(){
  const blocked=transferBusy()&&!streamRunning();
  thresholdMode.disabled=simulateOn||blocked;
  const manual=thresholdMode.getAttribute('aria-checked')==='true';
  document.getElementById('thresholdModeLabel').textContent='阈值模式：'+(manual?'手动':'自动');
  threshold.disabled=simulateOn||!manual||blocked;
}
function sendThreshold(){
  if(simulateOn||isStreamMode()||transferBusy()||thresholdMode.getAttribute('aria-checked')!=='true')return;
  const value=threshold.value;
  if(value!==lastThreshold){lastThreshold=value;fetch('/api/command?threshold='+value);}
}
thresholdMode.addEventListener('click',()=>{
  thresholdMode.setAttribute('aria-checked',thresholdMode.getAttribute('aria-checked')!=='true'?'true':'false');
  lastThreshold=null;updateThresholdControls();sendThreshold();
});
setInterval(sendThreshold,150);
document.getElementById('mode').addEventListener('change',e=>{
  fetch('/api/command?mode='+e.target.value);updatePreviewLabel();
});

function syncNavigation(){
  const mobile=compactNavigation.matches;
  const open=mobile?document.body.classList.contains('nav-open'):!document.body.classList.contains('nav-collapsed');
  menuToggle.setAttribute('aria-expanded',String(open));
  menuToggle.setAttribute('aria-label',open?'收起系统导航':'展开系统导航');
  systemDrawer.inert=mobile&&!open;
  workspace.inert=mobile&&open;
  if(mobile){
    systemDrawer.setAttribute('aria-hidden',String(!open));
    if(open){systemDrawer.setAttribute('role','dialog');systemDrawer.setAttribute('aria-modal','true');}
    else{systemDrawer.removeAttribute('role');systemDrawer.removeAttribute('aria-modal');}
  }else{
    systemDrawer.removeAttribute('aria-hidden');systemDrawer.removeAttribute('role');systemDrawer.removeAttribute('aria-modal');
  }
}
function setNavigationOpen(open){
  if(compactNavigation.matches){document.body.classList.toggle('nav-open',open);}
  else{document.body.classList.toggle('nav-collapsed',!open);}
  syncNavigation();
  if(compactNavigation.matches){
    if(open)document.getElementById('menuClose').focus();
    else menuToggle.focus();
  }
}
menuToggle.addEventListener('click',()=>setNavigationOpen(menuToggle.getAttribute('aria-expanded')!=='true'));
document.getElementById('menuClose').addEventListener('click',()=>setNavigationOpen(false));
document.getElementById('menuBackdrop').addEventListener('click',()=>setNavigationOpen(false));
compactNavigation.addEventListener('change',()=>{document.body.classList.remove('nav-open');syncNavigation();});
document.addEventListener('keydown',e=>{
  if(!compactNavigation.matches||!document.body.classList.contains('nav-open'))return;
  if(e.key==='Escape'){e.preventDefault();setNavigationOpen(false);}
  if(e.key==='Tab'){
    const buttons=[...systemDrawer.querySelectorAll('button:not(:disabled)')];
    const first=buttons[0],last=buttons[buttons.length-1];
    if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}
    else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}
  }
});

function updateModeMenu(){
  for(const button of modeButtons){
    button.setAttribute('aria-pressed',String(button.dataset.mode===systemMode.value));
    button.disabled=systemModePending||transferBusy();
  }
  const captions={simulation:'模拟模式',processing:'图像处理模式',medical:'医学分析模式'};
  document.getElementById('currentModeCaption').textContent=captions[systemMode.value]||'图像处理模式';
}
function updatePreviewLabel(){
  document.getElementById('previewMode').textContent=simulateOn?document.getElementById('mode').selectedOptions[0].textContent:'本地预览';
}
function setSimulateState(enabled,confirmedMode=null){
  if(['simulation','processing','medical'].includes(confirmedMode)){
    confirmedSystemMode=confirmedMode;
    systemMode.value=confirmedMode;
  }
  if(simulateOn!==enabled)lastThreshold=null;
  simulateOn=enabled;
  if(enabled)systemMode.value='simulation';
  else if(systemMode.value==='simulation')systemMode.value='processing';
  document.body.classList.toggle('medical-mode',systemMode.value==='medical');
  updateModeMenu();updatePreviewLabel();updatePreviewLayout();
  for(const group of document.querySelectorAll('[data-system-mode]')){
    group.hidden=group.dataset.systemMode!==systemMode.value&&!(group.dataset.systemMode==='processing'&&isProcessingMode());
  }
  updateThresholdControls();
}
for(const button of modeButtons){
  button.addEventListener('click',()=>{
    if(systemModePending||transferBusy())return;
    const changed=systemMode.value!==button.dataset.mode;
    systemMode.value=button.dataset.mode;
    if(changed)systemMode.dispatchEvent(new Event('change'));
    if(compactNavigation.matches)setNavigationOpen(false);
  });
}
systemMode.addEventListener('change',async()=>{
  const previous=confirmedSystemMode,mode=systemMode.value;
  systemModeRevision++;systemModePending=true;systemMode.disabled=true;
  setSimulateState(mode==='simulation');
  try{
    const response=await fetch('/api/system_mode?mode='+encodeURIComponent(mode));
    const result=await response.json();
    if(!response.ok||!result.ok)throw new Error(result.error||'系统模式切换失败');
    setSimulateState(Boolean(result.simulate),result.system_mode||mode);
  }catch(e){setSimulateState(previous==='simulation',previous);alert('系统模式切换失败: '+e.message);}
  finally{
    systemModePending=false;systemMode.disabled=false;updateModeMenu();
    try{await reloadOriginalImage();}catch(e){/* Keep the existing preview if the source reload fails. */}
    poll();
  }
});

async function reloadOriginalImage(){
  const response=await fetch('/api/original',{cache:'no-store'});
  if(!response.ok)throw new Error('原图重新加载失败');
  const original=await response.json();
  showOriginalFrame(original.image,original.image_name,original.source_revision);
}

function renderMedicalMetrics(readback={}){
  if(typeof renderCardiacCharts==='function')renderCardiacCharts(readback);
  const volumes=readback.medical_volumes_ml||{},efs=readback.medical_ef_percent||{};
  const display=value=>typeof value==='string'&&/^\d+\.\d{2}$/.test(value)?value:'—';
  for(const chamber of ['LA','RA','LV','RV']){
    for(const phase of ['EDV','ESV']){
      const key=phase+'_'+chamber;
      document.getElementById('medical'+key).textContent=display(volumes[key]);
    }
  }
  for(const chamber of ['LV','RV']){
    const key='EF_'+chamber;
    document.getElementById('medical'+key).textContent=display(efs[key]);
  }
  const ready=Object.values(volumes).some(value=>display(value)!=='—');
  document.getElementById('medicalMetricState').textContent=!readback.medical_volumes_ml?
    '等待 PS 容积与 EF 回传':!ready?'等待有效掩膜与完整心动周期':
    'PS 已更新 · '+new Date().toLocaleTimeString('zh-CN',{hour12:false});
  document.getElementById('medicalScaleNote').textContent=(readback.medical_scale_assumed===false?
    '使用 PS 配置的像素尺度': '按 CAMUS 像素尺度估算 · 面积 0.436281 mm²/像素')+
    '；心房容积取自左心室 ED/ES 时相。';
}

const sourceFps=document.getElementById('sourceFps');
sourceFps.addEventListener('input',()=>document.getElementById('sourceFpsValue').textContent=sourceFps.value);
sourceFps.addEventListener('change',()=>{
  if(typeof dshParameter!=='function')return;
  void dshParameter(async()=>{
    const response=await fetch('/api/serial/source_fps?value='+sourceFps.value);
    const reply=await response.json();
    if(!response.ok||!reply.ok)throw new Error(reply.log||'源视频帧率设置失败');
    if(typeof dshReadback==='function')await dshReadback(true);
  });
});

function renderMetrics(status,state){
  const rows=[
    ['目标面积',status.area_mm2,'mm²'],
    ['目标像素',status.area_pixels,'px'],
    ['模拟耗时',status.inference_us===undefined?undefined:(status.inference_us/1000).toFixed(3),'ms'],
    ['帧编号',status.frame_id,''],
    ['显示模式',status.mode_name,''],
    ['分割阈值',status.threshold,''],
    ['预览连接',state.serial_connected?'已连接':'未连接',''],
    ['模拟状态',state.simulate?'运行中':'已停止','']
  ];
  const fragment=document.createDocumentFragment();
  for(const [label,value,unit] of rows){
    const card=document.createElement('div');card.className='metric';
    const caption=document.createElement('span');caption.textContent=label;
    const output=document.createElement('b');output.textContent=value===undefined?'—':String(value);
    if(unit&&value!==undefined){const suffix=document.createElement('span');suffix.className='unit';suffix.textContent=' '+unit;output.appendChild(suffix);}
    card.append(caption,output);fragment.appendChild(card);
  }
  document.getElementById('metrics').replaceChildren(fragment);
}
async function poll(){
  const revision=systemModeRevision;
  try{
    const query=new URLSearchParams({mode:document.getElementById('mode').value,center:document.getElementById('center').value,width:document.getElementById('width').value,alpha:document.getElementById('alpha').value});
    const includeImages=!fastStreamMode()&&(simulateOn||sourceRevision<0);
    const response=await fetch(includeImages?'/api/state?'+query:'/api/network/state');
    const state=await response.json();
    if(systemModePending||revision!==systemModeRevision)return;
    setSimulateState(Boolean(state.simulate),state.system_mode);
    if(!fastStreamMode()&&state.image){
      showOriginalFrame(state.image,state.image_name,state.source_revision);
      if(state.processed_results)renderProcessedResults(state.processed_results,state.results_revision);
    }
    renderMetrics(state.status||{},state);
    document.getElementById('logs').textContent=(state.logs||[]).join('\n');
  }catch(e){/* Keep the last complete preview while reconnecting. */}
}
syncNavigation();updatePreviewLayout();updateThresholdControls();poll();setInterval(poll,150);

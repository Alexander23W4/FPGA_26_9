/* UI presentation and mode navigation. UART actions are supplied by monitor_network. */
const thresholdMode=document.getElementById('thresholdMode');
const threshold=document.getElementById('threshold');
const systemMode=document.getElementById('systemMode');
const menuToggle=document.getElementById('menuToggle');
const systemDrawer=document.getElementById('systemDrawer');
const workspace=document.querySelector('.workspace');
const modeButtons=[...systemDrawer.querySelectorAll('[data-mode]')];
const compactNavigation=window.matchMedia('(max-width:960px)');
let simulateOn=false;
let lastThreshold=null;
let systemModePending=false;
let systemModeRevision=0;

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
// The UART handler marks this button updated only after verified register readback.
function updateOverlayControls(){
  const mode=document.getElementById('fpgaOutputMode').value;
  document.getElementById('outputModeNote').textContent=mode==='5'
    ?'该选项仅为界面展示，暂未连接FPGA输出'
    :mode==='3'?'红色掩膜叠加，0% 完全透明，100% 实心红色':'设置开发板 HDMI 的输出内容';
}
document.getElementById('fpgaOutputMode').addEventListener('change',updateOverlayControls);

function updateThresholdControls(){
  thresholdMode.disabled=simulateOn;
  const manual=thresholdMode.getAttribute('aria-checked')==='true';
  document.getElementById('thresholdModeLabel').textContent='阈值模式：'+(manual?'手动':'自动');
  threshold.disabled=simulateOn||!manual;
}
function sendThreshold(){
  if(simulateOn||thresholdMode.getAttribute('aria-checked')!=='true')return;
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
    button.disabled=systemModePending;
  }
  document.getElementById('currentModeCaption').textContent=simulateOn?'模拟模式':'图像处理模式';
}
function updatePreviewLabel(){
  document.getElementById('previewMode').textContent=simulateOn?document.getElementById('mode').selectedOptions[0].textContent:'本地预览';
}
function setSimulateState(enabled){
  if(simulateOn!==enabled)lastThreshold=null;
  simulateOn=enabled;
  systemMode.value=enabled?'simulation':'processing';
  updateModeMenu();updatePreviewLabel();
  for(const group of document.querySelectorAll('[data-system-mode]'))group.hidden=group.dataset.systemMode!==systemMode.value;
  updateThresholdControls();
}
for(const button of modeButtons){
  button.addEventListener('click',()=>{
    if(systemModePending)return;
    const changed=systemMode.value!==button.dataset.mode;
    systemMode.value=button.dataset.mode;
    if(changed)systemMode.dispatchEvent(new Event('change'));
    if(compactNavigation.matches)setNavigationOpen(false);
  });
}
systemMode.addEventListener('change',async()=>{
  const previous=simulateOn,mode=systemMode.value;
  systemModeRevision++;systemModePending=true;systemMode.disabled=true;
  setSimulateState(mode==='simulation');
  try{
    const response=await fetch('/api/system_mode?mode='+encodeURIComponent(mode));
    const result=await response.json();
    if(!response.ok||!result.ok)throw new Error(result.error||'系统模式切换失败');
    setSimulateState(Boolean(result.simulate));
  }catch(e){setSimulateState(previous);alert('系统模式切换失败: '+e.message);}
  finally{systemModePending=false;systemMode.disabled=false;updateModeMenu();}
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
    const response=await fetch('/api/state?'+query);
    const state=await response.json();
    if(!systemModePending&&revision===systemModeRevision)setSimulateState(Boolean(state.simulate));
    document.getElementById('view').src='data:image/png;base64,'+state.image;
    document.getElementById('imageName').textContent=state.image_name;
    document.getElementById('imageName').title=state.image_name;
    renderMetrics(state.status||{},state);
    document.getElementById('logs').textContent=(state.logs||[]).join('\n');
  }catch(e){/* Keep the last complete preview while reconnecting. */}
}
syncNavigation();updateThresholdControls();poll();setInterval(poll,150);

'use strict';
const componentIds=['jtag','uart','ethernet','build'];
const $=id=>document.getElementById(id);
let checking=false,flashing=false,expiry=null;

function component(name,item){
  const badge=$(name+'Badge');
  badge.className='badge '+(item.ok?'ok':'fail');
  badge.textContent=item.ok?(name==='build'?'已就绪':'已连接'):'需检查';
  $(name+'Detail').textContent=item.detail||'';
}
function hint(message){
  $('connectionHint').textContent=message;
  $('connectionHint').classList.toggle('show',Boolean(message));
}
function progress(value,title,log='',kind=''){
  const pct=Math.max(0,Math.min(100,Number(value)||0));
  $('progressBar').style.width=pct+'%';
  $('progressPercent').textContent=Math.round(pct)+'%';
  $('progressTitle').textContent=title;
  const track=$('progressBar').parentElement;
  track.setAttribute('aria-valuenow',String(Math.round(pct)));
  track.setAttribute('aria-busy',String(flashing));
  $('flashLog').textContent=log;
  $('flashLog').className='flash-log '+kind;
}
async function request(path,options={}){
  const response=await fetch(path,{cache:'no-store',...options});
  const result=await response.json();
  if(!response.ok||result.ok===false)throw new Error(result.error||'服务请求失败');
  return result;
}
async function check(){
  if(checking||flashing)return;
  clearTimeout(expiry);checking=true;
  $('flash').disabled=true;$('recheck').disabled=true;
  $('checkSummary').textContent='正在检查…';hint('');
  for(const id of componentIds){
    $(id+'Badge').className='badge busy';$(id+'Badge').textContent='检查中';
  }
  try{
    const result=await request('/api/startup/check');
    for(const id of componentIds)component(id,result.components[id]||{ok:false,detail:'检查结果缺失'});
    $('checkSummary').textContent=result.ready?'全部就绪':'需要处理连接';
    if(result.ready){
      hint('连接检查通过。点击下方按钮，加载当前位流、PS 程序与 U-Net 权重。');
      $('flash').disabled=false;
      expiry=setTimeout(()=>{
        if(flashing)return;
        $('flash').disabled=true;$('checkSummary').textContent='请重新检查连接';
        hint('连接检查已过期，请点击“重新检查连接”后再烧录。');
      },175000);
    }else{
      hint('暂不能烧录：'+(result.missing||[]).join('；'));
    }
  }catch(error){
    $('checkSummary').textContent='检查失败';hint('无法完成连接检查：'+error.message);
    for(const id of componentIds){$(id+'Badge').className='badge fail';$(id+'Badge').textContent='检查失败';}
  }finally{
    checking=false;$('recheck').disabled=false;
  }
}
function failed(error){
  flashing=false;$('recheck').disabled=false;$('flash').disabled=true;
  $('checkSummary').textContent='烧录未完成';
  progress(Number($('progressPercent').textContent.replace('%','')),'烧录失败',error.message,'error');
  hint('请检查下方错误，修复后点击“重新检查连接”重试。');
}
async function watchFlash(){
  let failures=0;
  while(flashing){
    await new Promise(resolve=>setTimeout(resolve,450));
    let status;
    try{status=await request('/api/startup/status');failures=0;}
    catch(error){
      if(++failures<8){$('progressTitle').textContent='正在恢复进度连接…';continue;}
      throw error;
    }
    progress(status.progress,status.phase,status.message||'',status.state==='error'?'error':'');
    if(status.state==='complete'&&status.ready){
      flashing=false;$('checkSummary').textContent='烧录完成';
      progress(100,'全部就绪，正在进入操作台','位流、PS 程序、模型权重和板端网口服务均已就绪。','success');
      location.replace('/console');return;
    }
    if(status.state==='error')throw new Error(status.error||status.message||'烧录失败');
  }
}
async function flash(){
  if(flashing||$('flash').disabled)return;
  clearTimeout(expiry);flashing=true;
  $('flash').disabled=true;$('recheck').disabled=true;
  $('checkSummary').textContent='正在烧录';hint('请保持开发板通电，等待加载完成。');
  progress(2,'正在准备烧录','连接 JTAG，并验证当前构建文件…');
  try{await request('/api/startup/flash',{method:'POST'});await watchFlash();}
  catch(error){failed(error);}
}
async function initialize(){
  try{
    const status=await request('/api/startup/status');
    if(status.ready){location.replace('/console');return;}
    if(status.state==='running'){
      flashing=true;$('flash').disabled=true;$('recheck').disabled=true;
      $('checkSummary').textContent='正在烧录';
      hint('烧录仍在进行，已恢复进度显示。');
      await watchFlash();return;
    }
    if(status.state==='error'){failed(new Error(status.error||'上次烧录未完成'));return;}
    await check();
  }catch(error){failed(error);}
}
$('recheck').addEventListener('click',()=>void check());
$('flash').addEventListener('click',()=>void flash());
void initialize();

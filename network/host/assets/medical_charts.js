/* Each strip represents per-frame ventricular/atrial VOLUME, not ECG voltage.
 * Full server-side history survives dropped previews. Keep exactly 50 samples. */
const cardiacChambers=[['LA','左心房','#d64550'],['RA','右心房','#ca9d29'],
  ['LV','左心室','#27a273'],['RV','右心室','#4286c8']];
let cardiacHistory=[],cardiacLastSequence=null;
function initializeCardiacCharts(){
  const host=document.getElementById('medicalCurveStrips');
  host.innerHTML=cardiacChambers.map(([c,name,color])=>`<article class="volume-strip" style="--curve-color:${color}">
    <header><h5><i></i>${name}<span>${c}</span></h5><span class="curve-volume"><b id="curveValue${c}">—</b> mL</span></header>
    <div class="volume-strip-plot"><svg viewBox="0 0 800 96" preserveAspectRatio="none" role="img" aria-label="${name}最近50帧容积曲线">
      <defs><linearGradient id="curveFill${c}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="${color}" stop-opacity=".16"/><stop offset="100%" stop-color="${color}" stop-opacity=".01"/></linearGradient></defs>
      <path class="curve-grid" d="M12 24H788 M12 48H788 M12 72H788"/>
      <path id="curveArea${c}" fill="url(#curveFill${c})" stroke="none"/>
      <path id="curveLine${c}" class="curve-line"/>
      <path id="curveEd${c}" class="curve-phase curve-phase-ed"/>
      <path id="curveEs${c}" class="curve-phase curve-phase-es"/>
    </svg><span id="curveEmpty${c}" class="curve-empty">等待本腔室的有效掩膜</span><span id="curveScale${c}" class="curve-scale"></span></div>
  </article>`).join('');
}
function resetCardiacCharts(){
  cardiacHistory=[];cardiacLastSequence=null;
  renderCardiacCharts({});
}
function renderCardiacCharts(readback={}){
  const frame=readback.medical_frame,cycle=readback.medical_cycle||{};
  if(Array.isArray(readback.medical_history)){
    cardiacHistory=readback.medical_history.slice(-50);
    cardiacLastSequence=frame?frame.sequence:null;
  }else if(frame&&frame.index&&frame.sequence!==cardiacLastSequence){
    cardiacHistory.push(frame);cardiacHistory=cardiacHistory.slice(-50);cardiacLastSequence=frame.sequence;
  }
  const samples=cardiacHistory;
  document.getElementById('medicalCurveCount').textContent='最近 '+samples.length+' / 50 帧';
  document.getElementById('medicalHeartRate').textContent=cycle.heart_rate_bpm||'—';
  document.getElementById('medicalCycleSeconds').textContent=Number.isFinite(cycle.period_seconds)?cycle.period_seconds.toFixed(3):'—';
  document.getElementById('medicalCycleFrames').textContent=Number.isInteger(cycle.period_frames)?cycle.period_frames+' 帧 / 周期':'等待两个相邻周期';
  document.getElementById('medicalSourceTiming').textContent=Number.isFinite(cycle.source_fps)?
    '时间尺度按源视频 '+Math.round(cycle.source_fps)+' FPS 设定':'时间尺度按源视频 FPS 滑块设定';
  document.getElementById('medicalCurveRange').textContent=samples.length?
    '帧 '+samples[0].index+' — '+samples[samples.length-1].index+' · 随回传更新':'等待逐帧容积回传';
  for(const [c] of cardiacChambers){
    const value=p=>p.volumes_ml&&p.volumes_ml[c]!==null&&p.volumes_ml[c]!==undefined?Number(p.volumes_ml[c]):NaN;
    const values=samples.map(value).filter(Number.isFinite);
    const latest=samples.length?value(samples[samples.length-1]):NaN;
    document.getElementById('curveValue'+c).textContent=Number.isFinite(latest)?latest.toFixed(2):'—';
    document.getElementById('curveEmpty'+c).hidden=values.length>0;
    const min=values.length?Math.min(...values):0,max=values.length?Math.max(...values):1;
    const pad=Math.max((max-min)*.15,max*.02,.01),lo=Math.max(0,min-pad),hi=max+pad;
    const x=j=>12+j*776/49,y=v=>80-(v-lo)/(hi-lo)*66;
    let line='',area='',segment=[],priorEpoch=null;
    function finish(){
      if(!segment.length)return;
      line+='M'+segment.map(p=>p.join(',')).join('L');
      area+='M'+segment[0][0]+',88L'+segment.map(p=>p.join(',')).join('L')+'L'+segment[segment.length-1][0]+',88Z';
      segment=[];
    }
    samples.forEach((p,j)=>{
      const v=value(p);
      if(!Number.isFinite(v)||p.epoch!==priorEpoch)finish();
      if(Number.isFinite(v))segment.push([x(j).toFixed(2),y(v).toFixed(2)]);
      priorEpoch=p.epoch;
    });finish();
    document.getElementById('curveLine'+c).setAttribute('d',line);
    document.getElementById('curveArea'+c).setAttribute('d',area);
    for(const [phase,index] of [['Ed',cycle.ed_index],['Es',cycle.es_index]]){
      const j=samples.findIndex(p=>p.index===index&&(!frame||p.epoch===frame.epoch));
      document.getElementById('curve'+phase+c).setAttribute('d',j<0?'':'M'+x(j).toFixed(2)+' 12V88');
    }
    document.getElementById('curveScale'+c).textContent=values.length?min.toFixed(1)+'–'+max.toFixed(1)+' mL':'';
  }
}
initializeCardiacCharts();

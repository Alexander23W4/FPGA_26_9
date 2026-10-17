/* Still-image inspection uses a snapshot; no changes to transfers or stream playback. */
(() => {
  const dialog=document.getElementById('imageViewer');
  const stage=document.getElementById('imageViewerStage');
  const image=document.getElementById('imageViewerImage');
  const label=document.getElementById('imageViewerScale');
  let scale=1,x=0,y=0,drag=null,opener=null;
  const isStream=()=>typeof isStreamMode==='function'&&isStreamMode();
  function paint(){
    image.style.width=image.naturalWidth*scale+'px';
    image.style.height=image.naturalHeight*scale+'px';
    image.style.transform=`translate(-50%,-50%) translate(${x}px,${y}px)`;
    label.textContent=Math.round(scale*100)+'%';
  }
  function fit(){
    if(!dialog.open||!image.naturalWidth)return;
    scale=Math.max(.1,Math.min(32,(stage.clientWidth-32)/image.naturalWidth,
      (stage.clientHeight-32)/image.naturalHeight));
    x=y=0;paint();
  }
  function zoom(next,clientX,clientY){
    if(!dialog.open||!image.naturalWidth)return;
    const rect=stage.getBoundingClientRect();
    const mx=clientX===undefined?0:clientX-rect.left-rect.width/2;
    const my=clientY===undefined?0:clientY-rect.top-rect.height/2;
    next=Math.max(.1,Math.min(32,next));
    const ratio=next/scale;
    x=mx-(mx-x)*ratio;y=my-(my-y)*ratio;scale=next;paint();
  }
  function open(source){
    if(isStream()||source.hidden||!source.getAttribute('src')||!source.complete||!source.naturalWidth)return;
    opener=source;x=y=0;
    document.getElementById('imageViewerTitle').textContent=
      source.closest('figure')?.querySelector('figcaption')?.textContent||source.alt||'图像查看';
    image.alt=source.alt;image.style.visibility='hidden';
    image.onload=()=>{fit();image.style.visibility='visible';};
    image.src=source.currentSrc||source.src;
    if(!dialog.open)dialog.showModal();
    document.body.classList.add('image-viewer-open');
    if(image.complete&&image.naturalWidth){fit();image.style.visibility='visible';}
  }
  for(const source of document.querySelectorAll('#singlePreview img, #comparisonPreview img, #fullPreview img')){
    source.classList.add('image-zoomable');
    source.tabIndex=0;
    source.setAttribute('role','button');
    source.setAttribute('aria-haspopup','dialog');
    source.setAttribute('aria-label',(source.alt||'图像')+'，点击放大查看');
    source.addEventListener('click',()=>open(source));
    source.addEventListener('keydown',event=>{
      if(event.key==='Enter'||event.key===' '){event.preventDefault();open(source);}
    });
  }
  stage.addEventListener('wheel',event=>{
    event.preventDefault();
    const delta=event.deltaY*(event.deltaMode===1?16:event.deltaMode===2?stage.clientHeight:1);
    zoom(scale*Math.exp(Math.max(-1,Math.min(1,-delta*.0015))),event.clientX,event.clientY);
  },{passive:false});
  stage.addEventListener('pointerdown',event=>{
    if(event.button!==0||!image.naturalWidth)return;
    event.preventDefault();drag={id:event.pointerId,x:event.clientX,y:event.clientY};
    stage.setPointerCapture(event.pointerId);stage.classList.add('is-dragging');
  });
  stage.addEventListener('pointermove',event=>{
    if(!drag||drag.id!==event.pointerId)return;
    x+=event.clientX-drag.x;y+=event.clientY-drag.y;
    drag.x=event.clientX;drag.y=event.clientY;paint();
  });
  function endDrag(){drag=null;stage.classList.remove('is-dragging');}
  stage.addEventListener('pointerup',endDrag);
  stage.addEventListener('pointercancel',endDrag);
  stage.addEventListener('lostpointercapture',endDrag);
  stage.addEventListener('dblclick',fit);
  document.getElementById('imageViewerZoomOut').addEventListener('click',()=>zoom(scale/1.25));
  document.getElementById('imageViewerZoomIn').addEventListener('click',()=>zoom(scale*1.25));
  document.getElementById('imageViewerFit').addEventListener('click',fit);
  document.getElementById('imageViewerActual').addEventListener('click',()=>{scale=1;x=y=0;paint();});
  document.getElementById('imageViewerClose').addEventListener('click',()=>dialog.close());
  dialog.addEventListener('click',event=>{if(event.target===dialog)dialog.close();});
  dialog.addEventListener('close',()=>{
    endDrag();document.body.classList.remove('image-viewer-open');
    image.onload=null;image.removeAttribute('src');opener?.focus();opener=null;
  });
  window.addEventListener('resize',fit);
})();

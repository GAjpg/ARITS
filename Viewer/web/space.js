import {decodeRLE,encodeRLE,worldToCell,calibratedAt,cellCenter,segmentDistance} from './space_math.js';
import {requestJSON,requestBinary} from './space_api.js';
import {readCloud,cloudRaster,cloudBarriers,guardedStroke,floorSelection,floorSampler} from './space_cloud.js';
import {SpaceEditor} from './space_edit.js';
const $=id=>document.getElementById(id),token=document.querySelector('meta[name="viewer-token"]').content;
const canvas=$('mapCanvas'),ctx=canvas.getContext('2d');
const state={floorAt:null,floorMask:null,floorImage:null,cloud:null,cloudImage:null,barriers:null,cloudVersion:0,data:null,editor:null,layers:{},scale:1,ox:0,oy:0,raster:null,selected:null,drag:null,busy:false,tool:'pan',hover:null,spaceDown:false,
  selectedPath:null,selectedVertex:null,draft:[],start:null,end:null,route:null,previewVersion:0,previewBusy:false,previewQueued:false,previewTimer:null};
const kindNames={room:'房间入口',stair:'楼梯口',elevator:'电梯口',junction:'路口',waypoint:'路点'};
let noticeTimer,rasterFrame;
function notice(message,error=false){$('notice').textContent=message;$('notice').className='visible'+(error?' error':'');clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>$('notice').className='',error?9000:5000);}
function connectionChanged(status,message){$('connectionWarning').hidden=status==='online';$('connectionMessage').textContent=message;}
function api(url,options={}){return requestJSON(url,options,{token,connectionChanged});}
$('reconnect').onclick=()=>location.reload();
function inspector(open){document.body.classList.toggle('inspector-open',open);$('toggleInspector').setAttribute('aria-expanded',String(open));}
$('toggleInspector').onclick=()=>inspector(!document.body.classList.contains('inspector-open'));$('closeInspector').onclick=()=>inspector(false);
function confirmAction(message){return new Promise(resolve=>{const dialog=$('confirmDialog');$('confirmText').textContent=message;const done=value=>{dialog.close();resolve(value);};$('confirmAccept').onclick=()=>done(true);$('confirmCancel').onclick=()=>done(false);dialog.oncancel=event=>{event.preventDefault();done(false);};dialog.showModal();});}
async function discardIfNeeded(){return !state.editor?.dirty&&!state.draft.length||await confirmAction('当前编辑还没有保存。继续会丢弃草稿，是否继续？');}
function activeKey(){return state.data?.project.key;}
function semantic(node){return Boolean(node.kind&&node.kind!=='waypoint'||node.name&&node.kind!=='waypoint');}
function count(bits){let n=0;for(const b of bits)n+=b;return n;}
function setBusy(value){state.busy=value;for(const id of ['mapFile','projects','brushSize','routeStart','routeEnd','pathWidth','insertVertex','deletePath'])$(id).disabled=value;for(const button of document.querySelectorAll('[data-tool]'))button.disabled=value||!state.editor;updateButtons();}
async function perform(operation,message){setBusy(true);if(message)notice(message);try{return await operation();}catch(e){notice(e.message,true);return false;}finally{setBusy(false);}}
function updateButtons(){
 const e=state.editor;$('save').disabled=state.busy||!e?.dirty||Boolean(state.draft.length);$('export').disabled=state.busy||!e||Boolean(state.draft.length);
 $('importCalibration').disabled=state.busy||!e;$('undo').disabled=state.busy||!e?.canUndo;$('redo').disabled=state.busy||!e?.canRedo;
 $('saveState').textContent=!e?'尚未加载':state.draft.length?'正在绘制路径…':e.dirty?'● 未保存修改':'✓ 已保存工作副本';$('saveState').className='save-state'+(e?.dirty?' dirty':'');
 $('undo').title=e?.history.at(-1)?.label??'无可撤销操作';$('redo').title=e?.future.at(-1)?.label??'无可重做操作';
 for(const button of document.querySelectorAll('[data-tool]'))button.classList.toggle('active',button.dataset.tool===state.tool);
 $('pathDraftBar').hidden=!state.draft.length;$('draftCount').textContent=`已点 ${state.draft.length} 个点`;$('finishPath').disabled=state.draft.length<2||state.busy;
 const path=e?.paths.find(p=>p.id===state.selectedPath);$('pathControls').hidden=!path;
 $('removeVertex').disabled=!path||path.points.length<=2||state.selectedVertex===null||state.busy;
}
async function catalog(selected){const {projects}=await api('/api/space/projects');$('projects').replaceChildren(new Option('选择地图版本…',''));for(const p of projects)$('projects').add(new Option(`${p.name} · ${p.geometry_sha256.slice(0,8)}`,p.key));if(selected)$('projects').value=selected;}
function world(x,z){const g=state.editor.spec;return{x:state.ox+(x-g.origin_x)/g.cell_m*state.scale,y:state.oy+(z-g.origin_z)/g.cell_m*state.scale};}
function inverse(x,y){const g=state.editor.spec;return[g.origin_x+(x-state.ox)/state.scale*g.cell_m,g.origin_z+(y-state.oy)/state.scale*g.cell_m];}
function eventPoint(event){const r=canvas.getBoundingClientRect();return{x:event.clientX-r.left,y:event.clientY-r.top};}
function fit(){if(!state.editor)return;const g=state.editor.spec;state.scale=Math.min((canvas.clientWidth-70)/g.width,(canvas.clientHeight-70)/g.height);state.ox=(canvas.clientWidth-g.width*state.scale)/2;state.oy=(canvas.clientHeight-g.height*state.scale)/2;draw();}
function zoom(factor,x=canvas.clientWidth/2,y=canvas.clientHeight/2){if(!state.editor)return;const old=state.scale;state.scale=Math.max(.04,Math.min(80,old*factor));state.ox=x-(x-state.ox)*state.scale/old;state.oy=y-(y-state.oy)*state.scale/old;draw();}
function rebuild(){
 if(!state.editor)return;const g=state.editor.spec,rect=state.editor.rectangle,name=$('layer').value;
 const selected=name==='base'||name==='effective'&&state.editor.dirty?state.editor.mask:state.layers[name];
 const raster=state.raster??document.createElement('canvas');raster.width=g.width;raster.height=g.height;const c=raster.getContext('2d'),image=c.createImageData(g.width,g.height),pixels=image.data;
 for(let j=0;j<g.height;j++)for(let i=0;i<g.width;i++){
  const k=j*g.width+i,o=k*4,green=selected[k],x=g.origin_x+(i+.5)*g.cell_m,z=g.origin_z+(j+.5)*g.cell_m;
  let r=green?147:250,v=green?196:251,b=green?151:246;
  if($('showCoverage').checked&&!calibratedAt(rect,x,z)&&(i+j)%13<2){r=green?187:244;v=green?204:229;b=green?143:199;}
  if($('showObstacles').checked&&state.layers.obstacle[k]){r=green?72:58;v=green?125:77;b=green?85:66;}
  pixels[o]=r;pixels[o+1]=v;pixels[o+2]=b;pixels[o+3]=255;
 }
 c.putImageData(image,0,0);state.raster=raster;draw();
}
function rebuildCloud(){
 state.cloudImage=null;if(!state.cloud)return;
 const r=cloudRaster(state.cloud,state.floorAt,$('cloudBand').value);if(!r)return;
 const c=document.createElement('canvas');c.width=r.width;c.height=r.height;const context=c.getContext('2d'),image=context.createImageData(r.width,r.height);
 for(let k=0;k<r.density.length;k++){if(!r.density[k])continue;const o=k*4;image.data[o]=37;image.data[o+1]=53;image.data[o+2]=66;image.data[o+3]=Math.min(255,175+r.density[k]*20);}
 context.putImageData(image,0,0);state.cloudImage={canvas:c,...r};
 $('cloudStatus').textContent=`${state.data.project.point_count.toLocaleString()} 个原始点 · 当前显示 ${r.visible.toLocaleString()} 点。深色为点云，不随涂色消失。`;draw();
}
async function loadCloud(){
 const key=activeKey(),version=++state.cloudVersion;state.cloud=null;state.cloudImage=null;state.barriers=null;$('cloudStatus').textContent='正在加载原始点云，墙体画笔保护就绪前请稍候…';
 try{const raw=await requestBinary(`/api/space/projects/${key}/geometry`,{token,connectionChanged});if(key!==activeKey()||version!==state.cloudVersion)return;
  state.cloud=readCloud(raw,state.data.project.point_count);state.barriers=cloudBarriers(state.cloud,state.floorAt,state.editor.spec);rebuildCloud();
 }catch(e){if(version!==state.cloudVersion)return;$('cloudStatus').textContent=e.message;notice('点云参考未加载。请刷新；临时绘制可关闭“墙体挡住画笔”。',true);}
}
function scheduleRaster(){if(rasterFrame)return;rasterFrame=requestAnimationFrame(()=>{rasterFrame=null;rebuild();});}
function line(points,color,width,dash=[]){if(points.length<2)return;ctx.beginPath();points.forEach(([x,z],i)=>{const p=world(x,z);i?ctx.lineTo(p.x,p.y):ctx.moveTo(p.x,p.y);});ctx.strokeStyle=color;ctx.lineWidth=width;ctx.setLineDash(dash);ctx.stroke();ctx.setLineDash([]);}
function marker(point,label,color){if(!point)return;const p=world(...point);ctx.beginPath();ctx.arc(p.x,p.y,8,0,Math.PI*2);ctx.fillStyle=color;ctx.fill();ctx.strokeStyle='#fff';ctx.lineWidth=2;ctx.stroke();ctx.font='bold 11px -apple-system,sans-serif';ctx.fillStyle='#fff';ctx.fillText(label,p.x-4,p.y+4);}
function draw(){
 const ratio=Math.min(devicePixelRatio||1,2),w=canvas.clientWidth,h=canvas.clientHeight;
 if(canvas.width!==Math.round(w*ratio)||canvas.height!==Math.round(h*ratio)){canvas.width=Math.round(w*ratio);canvas.height=Math.round(h*ratio);}
 ctx.setTransform(ratio,0,0,ratio,0,0);ctx.clearRect(0,0,w,h);if(!state.editor||!state.raster)return;
 const g=state.editor.spec,rect=state.editor.rectangle;ctx.imageSmoothingEnabled=false;ctx.drawImage(state.raster,state.ox,state.oy,g.width*state.scale,g.height*state.scale);
 if(state.floorImage){ctx.globalAlpha=.65;ctx.drawImage(state.floorImage,state.ox,state.oy,g.width*state.scale,g.height*state.scale);ctx.globalAlpha=1;}
 if($('showCloud').checked&&state.cloudImage){const r=state.cloudImage,p=world(r.origin_x,r.origin_z);ctx.globalAlpha=Number($('cloudOpacity').value)/100;ctx.drawImage(r.canvas,p.x,p.y,r.width*r.cell_m/g.cell_m*state.scale,r.height*r.cell_m/g.cell_m*state.scale);ctx.globalAlpha=1;}
 if($('showLegacy').checked){const nodes=new Map(state.data.nodes.map(n=>[n.id,n]));for(const edge of state.data.edges){const a=nodes.get(edge.from)?.position,b=nodes.get(edge.to)?.position;if(a&&b)line([[a.x,a.z],[b.x,b.z]],'#7c858299',1.5,[5,5]);}}
 if($('showPaths').checked||state.tool==='select')for(const path of state.editor.paths){
  const points=state.drag?.kind==='vertex'&&state.drag.pathID===path.id?state.drag.points:path.points;
  line(points,'#a58cdb55',Math.max(3,path.width_m/g.cell_m*state.scale));line(points,path.id===state.selectedPath?'#7644b2':'#9773be',path.id===state.selectedPath?3:2);
  if(path.id===state.selectedPath&&state.tool==='select')points.forEach(([x,z],i)=>{const p=world(x,z);ctx.fillStyle=i===state.selectedVertex?'#7248a1':'white';ctx.strokeStyle='#7248a1';ctx.lineWidth=2;ctx.beginPath();ctx.arc(p.x,p.y,5,0,Math.PI*2);ctx.fill();ctx.stroke();});
 }
 if(state.draft.length){const points=[...state.draft];if(state.hover)points.push(inverse(state.hover.x,state.hover.y));line(points,'#9c56bb',2.5,[5,4]);for(const point of state.draft){const p=world(...point);ctx.fillStyle='#9c56bb';ctx.beginPath();ctx.arc(p.x,p.y,4,0,Math.PI*2);ctx.fill();}}
 if($('showCoverage').checked&&rect){const p=world(rect.origin_x,rect.origin_z);ctx.strokeStyle='#bd8236';ctx.lineWidth=1.5;ctx.setLineDash([8,4]);ctx.strokeRect(p.x,p.y,rect.width*state.scale*rect.cell_m/g.cell_m,rect.height*state.scale*rect.cell_m/g.cell_m);ctx.setLineDash([]);}
 if($('showNodes').checked)for(const node of state.data.nodes.filter(semantic)){const p=world(node.position.x,node.position.z);ctx.beginPath();ctx.arc(p.x,p.y,4.5,0,Math.PI*2);ctx.fillStyle=node.kind==='room'?'#257b6c':'#496581';ctx.fill();ctx.strokeStyle='#fff';ctx.lineWidth=1.5;ctx.stroke();if(state.scale>1.1||node.id===state.selected?.id){ctx.font='11px -apple-system,sans-serif';ctx.lineWidth=3;ctx.strokeStyle='#fffffff0';ctx.strokeText(node.name||kindNames[node.kind]||'标点',p.x+8,p.y-6);ctx.fillStyle='#35564a';ctx.fillText(node.name||kindNames[node.kind]||'标点',p.x+8,p.y-6);}}
 if(state.route?.status==='ok')line(state.route.points,'#2469b6',3.2);
 marker(state.start,'起','#286e4b');marker(state.end,'终','#c56d3e');
 if(state.hover&&['green','white'].includes(state.tool)){const p=state.hover,r=Number($('brushSize').value)/g.cell_m*state.scale/2;ctx.fillStyle=state.tool==='green'?'#3b9a4530':'#ffffff66';ctx.strokeStyle=state.tool==='green'?'#267b35':'#5f715f';ctx.lineWidth=1.5;ctx.beginPath();ctx.arc(p.x,p.y,r,0,Math.PI*2);ctx.fill();ctx.stroke();}
 let metres=1,pixels=state.scale/g.cell_m;while(metres*pixels<45)metres*=2;while(metres*pixels>160)metres/=2;$('scale').textContent=`${metres} m ≈ ${Math.round(metres*pixels)} px`;
}
function updateStats(){
 if(!state.editor)return;const g=state.editor.spec,stats=$('stats');stats.replaceChildren();
 for(const [value,label] of [[(count(state.editor.mask)*g.cell_m*g.cell_m).toFixed(1),'基础可走 / m²'],[String(state.editor.paths.length),'建议路径'],[String(state.data.nodes.filter(semantic).length),'语义点'],[String(state.data.edges.length),'旧参考连线']]){const div=document.createElement('div'),b=document.createElement('b'),span=document.createElement('span');b.textContent=value;span.textContent=label;div.append(b,span);stats.append(div);}
 const rect=state.editor.rectangle;$('calibrationState').textContent=(state.editor.dirty?'草稿未保存 · ':'')+(rect?'校准矩形内绿白均为最终结果；矩形外未校准。':'尚无校准栅格，自动判断生效；路径单独保存。');
 $('gridInfo').textContent=`${g.width} × ${g.height} 格 · 10 cm${state.editor.dirty?' · 编辑草稿':''}`;
}
function updatePaths(){
 $('pathList').replaceChildren();if(!state.editor?.paths.length)$('pathList').textContent='暂无路径，点击“画路径”逐点绘制。';
 state.editor?.paths.forEach((path,index)=>{const b=document.createElement('button');b.textContent=`路径 ${index+1} · ${path.width_m.toFixed(1)} m · ${path.points.length} 点${path.source==='phone'?' · 手机':''}`;b.className=path.id===state.selectedPath?'active':'';b.onclick=()=>{if(state.busy)return;state.selectedPath=path.id;state.selectedVertex=0;setTool('select');updatePaths();};$('pathList').append(b);});
 const path=state.editor?.paths.find(p=>p.id===state.selectedPath);
 if(path){if(![...$('pathWidth').options].some(o=>Number(o.value)===path.width_m))$('pathWidth').add(new Option(`${path.width_m} m`,String(path.width_m)));$('pathWidth').value=String(path.width_m);}
 updateButtons();draw();
}
function afterEdit(paths=false){
 if(state.selectedPath&&!state.editor.paths.some(p=>p.id===state.selectedPath)){state.selectedPath=null;state.selectedVertex=null;}
 updateStats();updateButtons();if(paths)updatePaths();rebuild();schedulePreview();
}
function setTool(tool){
 if(state.draft.length&&tool!=='path'){notice('请先完成或取消正在绘制的路径。');return;}
 state.tool=tool;if(tool==='start'||tool==='end')inspector(false);canvas.className=['green','white'].includes(tool)?'painting':['path','start','end','select'].includes(tool)?'drawing':'';
 const help={pan:'拖动平移，滚轮缩放。空格或右键可临时平移。',green:'按住拖动涂绿：设为可通行。首次涂改会以当前基础层建立整张画布的校准。',white:'按住拖动涂白：设为不可通行。建议路径仍会覆盖白格，可在“改路径”中删除。',path:'逐点点击绘制折线，点“完成路径”或按 Enter。Esc 取消。',select:'点击紫色路径选择，拖动顶点调整；右侧可改宽度、插入点或删除。',start:'在地图上点击路线起点，随后可选择终点。',end:'在地图上点击路线终点，自动更新预览。'};
 $('toolHelp').textContent=help[tool];if(['green','white'].includes(tool)){$('layer').value='base';$('showObstacles').checked=false;rebuild();}
 updateButtons();draw();
}
function show(data){
 state.previewVersion++;clearTimeout(state.previewTimer);state.previewQueued=false;
 clearFloor();state.cloudImage=null;state.barriers=null;state.cloud=null;state.data=data;state.floorAt=floorSampler(data.grid.grid.floor_y,data.grid.floor_field);state.editor=new SpaceEditor(data);state.layers={};const g=state.editor.spec;
 for(const [name,bits] of Object.entries(data.grid.layers))state.layers[name]=decodeRLE(bits,g.width,g.height);
 state.selected=null;state.selectedPath=null;state.selectedVertex=null;state.draft=[];state.start=null;state.end=null;state.route=null;state.drag=null;
 $('floorReference').textContent=data.grid.floor_field?`采用 ${data.grid.floor_field.block_m} m 网格的局部地面高度。上下限相对各处地面，不是相对同一个全局高度。`:`估计地面 Y = ${data.grid.grid.floor_y.toFixed(2)} m。下限/上限为相对高度；例如上限 0.35 m 可纳入比基准高 35 cm 的地面点。`;
 $('empty').hidden=true;$('mapTitle').textContent=data.project.name;$('projectInfo').textContent=`${data.project.point_count.toLocaleString()} 个原始几何点 · ${data.project.geometry_sha256.slice(0,12)}\n地图 ${data.project.map_id}`;
 $('warnings').replaceChildren();for(const warning of data.warnings){const p=document.createElement('p');p.className='warning';p.textContent=warning;$('warnings').append(p);}
 $('nodeList').replaceChildren();$('routeStart').replaceChildren(new Option('在图上选起点…',''));$('routeEnd').replaceChildren(new Option('在图上选终点…',''));
 for(const node of data.nodes.filter(semantic)){
  const b=document.createElement('button');b.textContent=node.name||kindNames[node.kind]||'未命名';const type=document.createElement('small');type.textContent=kindNames[node.kind]||'旧命名点';b.append(type);
  b.onclick=()=>{selectAt(node.position.x,node.position.z,node);const p=world(node.position.x,node.position.z);state.ox+=canvas.clientWidth/2-p.x;state.oy+=canvas.clientHeight/2-p.y;draw();};$('nodeList').append(b);
 }
 for(const node of data.nodes.filter(n=>n.name&&semantic(n))){for(const select of [$('routeStart'),$('routeEnd')])select.add(new Option(node.name,node.id));}
 $('selection').textContent='在地图上点击查看坐标、通行判定和校准状态。';$('routeStatus').textContent='选择两个位置，预览通行路线。';$('routeStatus').className='status';
 updateStats();updatePaths();setTool('pan');rebuild();fit();loadCloud();
}
function selectAt(x,z,node=null){
 const g=state.editor.spec,cell=worldToCell(g,x,z),known=calibratedAt(state.editor.rectangle,x,z);state.selected={id:node?.id,xz:[x,z]};
 const walkable=cell&&(state.editor.dirty?state.editor.mask[cell.index]:state.layers.effective[cell.index]);
 $('selection').textContent=`${node?`${node.name||'未命名'} · ${kindNames[node.kind]||'旧命名点'}\n`:''}X ${x.toFixed(2)} m · Z ${z.toFixed(2)} m\n${cell?(walkable?'可走':'不可走 / 未观察'):'栅格范围外'} · ${known?'已校准（含白格）':'未校准'}${state.editor.dirty?'\n当前为未保存草稿；紫色路径另外强制通行':''}`;$('selection').style.whiteSpace='pre-line';draw();
}
function invalidatePreview(){state.previewVersion++;clearTimeout(state.previewTimer);state.route=null;draw();}
function schedulePreview(){
 invalidatePreview();if(!state.start||!state.end){$('routeStatus').textContent='选择两个位置，预览通行路线。';$('routeStatus').className='status';return;}
 $('routeStatus').textContent='正在更新路线预览…';$('routeStatus').className='status stale';const version=state.previewVersion;
 state.previewTimer=setTimeout(()=>runPreview(version),300);
}
async function runPreview(version){
 if(version!==state.previewVersion||!state.start||!state.end)return;
 if(state.previewBusy){state.previewQueued=true;return;}
 state.previewBusy=true;const key=activeKey();
 try{
  const result=await api(`/api/space/projects/${key}/preview`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({calibration:state.editor.serialize(),from:state.start,to:state.end,request_id:version})});
  if(version!==state.previewVersion||key!==activeKey())return;
  state.route=result.route;$('routeStatus').className='status'+(result.route.status==='ok'?'':' failed');
  $('routeStatus').textContent=result.route.status==='ok'?`${result.route.length_m.toFixed(1)} m · ${state.editor.dirty?'草稿预览':'已保存校准'}${result.route.used_paths?.length?' · 含建议路径':''}`:`不可达：${result.route.reason}`;draw();
 }catch(e){if(version===state.previewVersion){$('routeStatus').textContent=e.message;$('routeStatus').className='status failed';}}
 finally{state.previewBusy=false;if(state.previewQueued){state.previewQueued=false;runPreview(state.previewVersion);}}
}
function acceptSaved(data){
 const g=state.editor.spec,source=data.grid.grid;
 for(const [name,rle] of Object.entries(data.grid.layers)){
  const input=decodeRLE(rle,source.width,source.height),output=new Uint8Array(g.width*g.height);
  for(let j=0;j<g.height;j++)for(let i=0;i<g.width;i++){const [x,z]=cellCenter(g,i,j),cell=worldToCell(source,x,z);if(cell)output[j*g.width+i]=input[cell.index];}
  state.layers[name]=output;
 }
 state.data.calibration=data.calibration;state.data.calibration_revision=data.calibration_revision;state.editor.markSaved();afterEdit();
}
async function save(){
 if(!state.editor||state.draft.length){notice('请先完成路径。');return false;}
 return perform(async()=>{invalidatePreview();const result=await api(`/api/space/projects/${activeKey()}/edit`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({calibration:state.editor.serialize(),base_revision:state.data.calibration_revision})});acceptSaved(result);notice('校准已保存到本机工作副本；可继续编辑或导出到手机。');return true;},'正在校验并保存校准…');
}
async function exportFile(){
 if(!state.editor)return;
 await perform(async()=>{
  const result=await api(`/api/space/projects/${activeKey()}/export-draft`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({calibration:state.editor.serialize()})});
  location.href=result.download_url;
  notice(state.editor.dirty?'已导出当前草稿。点击“保存校准”可同时保留到工作台。':'已导出校准文件，可直接导入手机。');
 },'正在校验导出文件…');
}
function finishPath(){if(state.draft.length<2){notice('至少点出两个点。');return;}try{state.selectedPath=state.editor.addPath(state.draft,Number($('pathWidth').value)||.6);state.selectedVertex=0;state.draft=[];setTool('select');afterEdit(true);notice('已生成建议路径，可拖动顶点调整。');}catch(e){notice(e.message,true);}}
function cancelDraft(){state.draft=[];updateButtons();draw();}
function pickPath(point){
 let best=null,distance=12;for(const path of state.editor.paths)for(let i=0;i<path.points.length-1;i++){
  const a=world(...path.points[i]),b=world(...path.points[i+1]),d=segmentDistance(point.x,point.y,[a.x,a.y],[b.x,b.y]);if(d<distance){best={path,segment:i};distance=d;}
 }return best;
}
function routePoint(which,point){state[which]=point;$(which==='start'?'routeStart':'routeEnd').value='';schedulePreview();notice(`已设置${which==='start'?'起点':'终点'}：${point.map(x=>x.toFixed(1)).join(', ')} m`);}
for(const button of document.querySelectorAll('[data-tool]'))button.onclick=()=>{if(state.editor&&!state.busy)setTool(button.dataset.tool);};
function clearFloor(){state.floorMask=null;state.floorImage=null;$('applyFloor').disabled=true;$('floorStatus').textContent='蓝色为高度命中的地面预览。确认后才补涂绿色，可一键撤销，不清除其他绿区。范围过高会选到家具。';draw();}
function previewFloor(){
 if(!state.cloud||state.busy||state.drag){notice('请等待点云加载完成或结束当前操作。');return;}
 try{const g=state.editor.spec;state.floorMask=floorSelection(state.cloud,state.floorAt,g,Number($('floorMin').value),Number($('floorMax').value),$('guardBrush').checked?state.barriers:null);
  const c=document.createElement('canvas');c.width=g.width;c.height=g.height;const context=c.getContext('2d'),image=context.createImageData(g.width,g.height);let added=0;
  for(let k=0;k<state.floorMask.length;k++)if(state.floorMask[k]){const o=k*4;image.data[o]=38;image.data[o+1]=164;image.data[o+2]=218;image.data[o+3]=255;if(!state.editor.mask[k])added++;}
  context.putImageData(image,0,0);state.floorImage=c;$('applyFloor').disabled=!added;$('floorStatus').textContent=`蓝色预览 ${(count(state.floorMask)*g.cell_m*g.cell_m).toFixed(1)} m²，其中 ${(added*g.cell_m*g.cell_m).toFixed(1)} m² 将由白补绿。${$('guardBrush').checked?'已避开点云墙格。':''}仅选中有地面点的格子，不自动填补大空洞。`;draw();
 }catch(e){clearFloor();notice(e.message,true);}
}
$('previewFloor').onclick=previewFloor;$('clearFloor').onclick=clearFloor;
for(const id of ['floorMin','floorMax','guardBrush'])$(id).onchange=clearFloor;
$('applyFloor').onclick=async()=>{
 if(state.busy||!state.floorMask||state.draft.length)return;
 const key=activeKey(),mask=state.floorMask;
 if(!await confirmAction('将蓝色命中的格子补涂为可走？这些位置的白格会变绿，其他绿区和建议路径保持原样。可点击“撤销”恢复。'))return;
 if(key!==activeKey()||mask!==state.floorMask||state.busy)return;
 state.editor.paintMask(mask);clearFloor();afterEdit();notice('已按高度补涂地面；检查后保存校准，或点击撤销。');
};
$('showCloud').onchange=draw;$('cloudBand').onchange=rebuildCloud;$('cloudOpacity').oninput=()=>{$('cloudOpacityValue').textContent=$('cloudOpacity').value+'%';draw();};
$('brushSize').oninput=()=>{$('brushValue').textContent=Number($('brushSize').value).toFixed(1)+' m';draw();};
$('undo').onclick=()=>{if(state.editor&&!state.busy){notice('已撤销'+state.editor.undo());afterEdit(true);}};
$('redo').onclick=()=>{if(state.editor&&!state.busy){notice('已重做'+state.editor.redo());afterEdit(true);}};
$('save').onclick=save;$('export').onclick=exportFile;$('finishPath').onclick=finishPath;$('cancelPath').onclick=cancelDraft;
$('pathWidth').onchange=()=>{if(state.selectedPath){state.editor.updatePath(state.selectedPath,{width_m:Number($('pathWidth').value)});afterEdit(true);}};
$('deletePath').onclick=()=>{if(state.selectedPath){state.editor.removePath(state.selectedPath);afterEdit(true);notice('路径已删除，可以撤销。');}};
$('insertVertex').onclick=()=>{const p=state.editor.paths.find(p=>p.id===state.selectedPath);if(!p)return;const i=Math.min(state.selectedVertex??0,p.points.length-2),points=structuredClone(p.points),a=points[i],b=points[i+1];points.splice(i+1,0,[(a[0]+b[0])/2,(a[1]+b[1])/2]);state.editor.updatePath(p.id,{points});state.selectedVertex=i+1;afterEdit(true);};
$('removeVertex').onclick=()=>{const p=state.editor.paths.find(p=>p.id===state.selectedPath);if(!p||state.selectedVertex===null||p.points.length<=2)return;const points=structuredClone(p.points);points.splice(state.selectedVertex,1);state.editor.updatePath(p.id,{points});state.selectedVertex=Math.min(state.selectedVertex,points.length-1);afterEdit(true);};
for(const [which,id] of [['start','routeStart'],['end','routeEnd']])$(id).onchange=()=>{const n=state.data.nodes.find(n=>n.id===$(id).value);state[which]=n?[n.position.x,n.position.z]:null;schedulePreview();};
$('clearRoute').onclick=()=>{state.start=null;state.end=null;$('routeStart').value='';$('routeEnd').value='';schedulePreview();};
$('mapFile').onchange=()=>{const file=$('mapFile').files[0];if(!file)return;perform(async()=>{if(!await discardIfNeeded())return;const form=new FormData();form.append('file',file);const data=await api('/api/space/import',{method:'POST',body:form});show(data);await catalog(data.project.key);notice(data.notice||'地图已导入，可直接选择画笔编辑。');},'正在读取地图…').finally(()=>$('mapFile').value='');};
$('projects').onchange=()=>{const key=$('projects').value;if(!key){$('projects').value=activeKey()||'';return;}perform(async()=>{if(!await discardIfNeeded()){$('projects').value=activeKey();return;}show(await api('/api/space/projects/'+key));},'正在加载工作副本…');};
$('importCalibration').onclick=()=>$('calibrationFile').click();
$('calibrationFile').onchange=()=>{const file=$('calibrationFile').files[0],key=activeKey();if(!file||!key)return;perform(async()=>{const text=await file.text(),incoming=JSON.parse(text);if(!await confirmAction(`替换本机校准层${state.editor.dirty?'并丢弃未保存草稿':''}？\n建议路径 ${state.editor.paths.length} → ${incoming.suggested_paths?.length??0} 条。\n原始地图 ZIP 不会改变。`))return;const form=new FormData();form.append('file',file);show(await api(`/api/space/projects/${key}/calibration`,{method:'POST',body:form}));notice('校准已加载，可以继续涂改。');},'正在检查校准文件…').finally(()=>$('calibrationFile').value='');};
for(const id of ['layer','showObstacles','showCoverage'])$(id).onchange=rebuild;for(const id of ['showPaths','showLegacy','showNodes'])$(id).onchange=draw;
$('fit').onclick=fit;$('zoomIn').onclick=()=>zoom(1.35);$('zoomOut').onclick=()=>zoom(1/1.35);
canvas.oncontextmenu=e=>e.preventDefault();canvas.addEventListener('wheel',event=>{event.preventDefault();const p=eventPoint(event);zoom(Math.exp(-event.deltaY*.001),p.x,p.y);},{passive:false});
canvas.onpointerdown=event=>{
 if(!state.editor||state.busy||!event.isPrimary)return;canvas.focus({preventScroll:true});canvas.setPointerCapture(event.pointerId);const p=eventPoint(event),point=inverse(p.x,p.y);state.hover=p;
 if(event.button!==0||state.spaceDown||state.tool==='pan'){state.drag={kind:'pan',x:event.clientX,y:event.clientY,ox:state.ox,oy:state.oy,moved:false};return;}
 if(['green','white'].includes(state.tool)){
  let allowed=null;if($('guardBrush').checked){if(!state.barriers){notice('点云保护尚未就绪，请稍候，或关闭“墙体挡住画笔”。');return;}allowed=guardedStroke(state.barriers,state.editor.spec,point,point,Number($('brushSize').value)).allowed;const cell=worldToCell(state.editor.spec,...point);if(!cell||!allowed[cell.index]){notice('请从墙线内侧的空地起笔；墙线误挡时可关闭保护。');return;}}
  state.editor.beginStroke(state.tool==='green');state.editor.paint(point,point,Number($('brushSize').value),allowed);state.drag={kind:'paint',last:point,guard:Boolean(allowed)};invalidatePreview();scheduleRaster();return;
 }
 if(state.tool==='select'){
  const path=state.editor.paths.find(p=>p.id===state.selectedPath);
  if(path)for(let i=0;i<path.points.length;i++){const h=world(...path.points[i]);if(Math.hypot(h.x-p.x,h.y-p.y)<10){state.selectedVertex=i;state.drag={kind:'vertex',pathID:path.id,points:structuredClone(path.points),vertex:i};invalidatePreview();updateButtons();return;}}
  const hit=pickPath(p);state.selectedPath=hit?.path.id??null;state.selectedVertex=hit?.segment??null;updatePaths();return;
 }
 if(state.tool==='path'){if(state.draft.length>=2000){notice('每条路径最多 2000 个点，请完成当前路径。');return;}if(worldToCell(state.editor.spec,...point)){state.draft.push(point);updateButtons();draw();}return;}
 if(state.tool==='start'){routePoint('start',point);setTool(state.end?'pan':'end');return;}
 if(state.tool==='end'){routePoint('end',point);setTool('pan');}
};
canvas.onpointermove=event=>{
 if(!state.editor)return;const p=eventPoint(event),point=inverse(p.x,p.y);state.hover=p;
 if(state.drag?.kind==='pan'){const dx=event.clientX-state.drag.x,dy=event.clientY-state.drag.y;if(Math.hypot(dx,dy)>3)state.drag.moved=true;state.ox=state.drag.ox+dx;state.oy=state.drag.oy+dy;draw();}
 else if(state.drag?.kind==='paint'){const stroke=state.drag.guard?guardedStroke(state.barriers,state.editor.spec,state.drag.last,point,Number($('brushSize').value)):{last:point,allowed:null};state.editor.paint(state.drag.last,stroke.last,Number($('brushSize').value),stroke.allowed);state.drag.last=stroke.last;scheduleRaster();}
 else if(state.drag?.kind==='vertex'){if(worldToCell(state.editor.spec,...point))state.drag.points[state.drag.vertex]=point;draw();}
 else draw();
 $('cursor').textContent=`${({green:'涂绿',white:'涂白',path:'画路径',select:'改路径'})[state.tool]||'地图'} · X ${point[0].toFixed(2)} · Z ${point[1].toFixed(2)} m`;
};
canvas.onpointerup=event=>{
 const drag=state.drag;state.drag=null;if(!drag||!state.editor)return;
 if(drag.kind==='paint'){state.editor.endStroke();afterEdit();return;}
 if(drag.kind==='vertex'){state.editor.updatePath(drag.pathID,{points:drag.points});afterEdit(true);return;}
 if(drag.kind==='pan'&&!drag.moved&&event.button===0){const p=eventPoint(event);let node=null,min=14;for(const n of state.data.nodes.filter(semantic)){const h=world(n.position.x,n.position.z),d=Math.hypot(p.x-h.x,p.y-h.y);if(d<min){node=n;min=d;}}const point=node?[node.position.x,node.position.z]:inverse(p.x,p.y);selectAt(...point,node);}
};
function cancelDrag(){if(state.drag?.kind==='paint')state.editor.cancelStroke();state.drag=null;afterEdit();}
canvas.onpointercancel=()=>{if(state.drag)cancelDrag();};canvas.onpointerleave=()=>{if(!state.drag){state.hover=null;draw();}};
window.addEventListener('keydown',event=>{
 if(state.busy||['INPUT','SELECT','TEXTAREA'].includes(event.target.tagName)||$('confirmDialog').open)return;
 if(event.code==='Space'){event.preventDefault();state.spaceDown=true;}
 if(event.key==='Escape'){if(state.drag)cancelDrag();cancelDraft();}
 if(event.key==='Enter'&&state.draft.length){event.preventDefault();finishPath();}
 if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='z'&&state.editor){event.preventDefault();if(state.drag)cancelDrag();if(state.draft.length){state.draft.pop();updateButtons();draw();}else{event.shiftKey?state.editor.redo():state.editor.undo();afterEdit(true);}}
});window.addEventListener('keyup',e=>{if(e.code==='Space')state.spaceDown=false;});window.addEventListener('blur',()=>{state.spaceDown=false;if(state.drag)cancelDrag();});
window.addEventListener('beforeunload',event=>{if(state.editor?.dirty||state.draft.length){event.preventDefault();event.returnValue='';}});
new ResizeObserver(()=>{if(state.editor)fit();else draw();}).observe($('viewport'));
await perform(async()=>{await catalog();const initial=$('projects').options[1]?.value;if(initial){$('projects').value=initial;show(await api('/api/space/projects/'+initial));}},'正在连接本机工作台…');

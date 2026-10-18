import {decodeRLE,encodeRLE,cellCenter,segmentDistance} from './space_math.js';
const clone=value=>structuredClone(value);
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const id=()=>globalThis.crypto.randomUUID();
const now=()=>new Date().toISOString();

export class SpaceEditor {
  constructor(data){
    this.project=data.project;this.spec=clone(data.grid.grid);this.params=clone(data.grid.params);
    this.original=data.calibration?clone(data.calibration):null;
    this.mask=decodeRLE(data.grid.layers.base,this.spec.width,this.spec.height);
    this.paths=clone(data.grid.suggested_paths);this.maskEdited=false;
    this.coverage=null;
    const rect=data.calibration?.walkable,g=this.spec;
    if(rect){
      // Match the original authoritative rectangle at this grid's cell centers.
      this.coverage={x0:Math.max(0,Math.ceil((rect.origin_x-g.origin_x)/g.cell_m-.5-1e-8)),z0:Math.max(0,Math.ceil((rect.origin_z-g.origin_z)/g.cell_m-.5-1e-8)),
        x1:Math.min(g.width,Math.ceil((rect.origin_x+rect.width*rect.cell_m-g.origin_x)/g.cell_m-.5-1e-8)),z1:Math.min(g.height,Math.ceil((rect.origin_z+rect.height*rect.cell_m-g.origin_z)/g.cell_m-.5-1e-8))};
    }
    this.history=[];this.future=[];this.historyBytes=0;this.current=id();this.saved=this.current;this.updated=now();this.stroke=null;
  }
  get dirty(){return this.current!==this.saved||Boolean(this.stroke?.changes.size);}
  get canUndo(){return this.history.length>0;}
  get canRedo(){return this.future.length>0;}
  get rectangle(){
    if(!this.maskEdited)return this.original?.walkable??null;
    const c=this.coverage,g=this.spec;
    return c?{origin_x:g.origin_x+c.x0*g.cell_m,origin_z:g.origin_z+c.z0*g.cell_m,cell_m:g.cell_m,width:c.x1-c.x0,height:c.z1-c.z0}:null;
  }
  beginStroke(value){if(this.stroke)throw Error('请先结束当前笔画');this.stroke={value:value?1:0,changes:new Map(),coverage:clone(this.coverage),maskEdited:this.maskEdited};}
  paint(a,b,diameter,allowed=null){
    if(!this.stroke||!Number.isFinite(diameter)||diameter<.1||diameter>20)return;
    const g=this.spec,r=diameter/2;
    const x0=Math.max(0,Math.floor((Math.min(a[0],b[0])-r-g.origin_x)/g.cell_m));
    const z0=Math.max(0,Math.floor((Math.min(a[1],b[1])-r-g.origin_z)/g.cell_m));
    const x1=Math.min(g.width-1,Math.floor((Math.max(a[0],b[0])+r-g.origin_x)/g.cell_m));
    const z1=Math.min(g.height-1,Math.floor((Math.max(a[1],b[1])+r-g.origin_z)/g.cell_m));
    let touched=false,loX=g.width,loZ=g.height,hiX=0,hiZ=0;
    for(let j=z0;j<=z1;j++)for(let i=x0;i<=x1;i++){
      const [x,z]=cellCenter(g,i,j);if(allowed&&!allowed[j*g.width+i]||segmentDistance(x,z,a,b)>r+1e-8)continue;
      touched=true;loX=Math.min(loX,i);loZ=Math.min(loZ,j);hiX=Math.max(hiX,i+1);hiZ=Math.max(hiZ,j+1);
      const k=j*g.width+i;if(this.mask[k]!==this.stroke.value){if(!this.stroke.changes.has(k))this.stroke.changes.set(k,this.mask[k]);this.mask[k]=this.stroke.value;}
    }
    if(touched){
      if(!this.coverage)this.coverage={x0:0,z0:0,x1:g.width,z1:g.height};
      else this.coverage={x0:Math.min(this.coverage.x0,loX),z0:Math.min(this.coverage.z0,loZ),x1:Math.max(this.coverage.x1,hiX),z1:Math.max(this.coverage.z1,hiZ)};
      this.maskEdited=true;
    }
  }
  paintMask(bits,value=true){
    if(bits.length!==this.mask.length)throw Error('地面预览与当前地图尺寸不一致');
    this.beginStroke(value);const g=this.spec;let loX=g.width,loZ=g.height,hiX=0,hiZ=0,touched=false;
    for(let k=0;k<bits.length;k++)if(bits[k]){
      touched=true;const x=k%g.width,z=Math.floor(k/g.width);loX=Math.min(loX,x);loZ=Math.min(loZ,z);hiX=Math.max(hiX,x+1);hiZ=Math.max(hiZ,z+1);
      if(this.mask[k]!==this.stroke.value){this.stroke.changes.set(k,this.mask[k]);this.mask[k]=this.stroke.value;}
    }
    if(touched){this.coverage=this.coverage?{x0:Math.min(this.coverage.x0,loX),z0:Math.min(this.coverage.z0,loZ),x1:Math.max(this.coverage.x1,hiX),z1:Math.max(this.coverage.z1,hiZ)}:{x0:0,z0:0,x1:g.width,z1:g.height};this.maskEdited=true;}
    const changed=this.endStroke();if(changed)this.history.at(-1).label='按高度补涂地面';return changed;
  }
  endStroke(){
    const stroke=this.stroke;if(!stroke)return false;this.stroke=null;
    if(!stroke.changes.size&&same(stroke.coverage,this.coverage)&&stroke.maskEdited===this.maskEdited)return false;
    const indices=Uint32Array.from(stroke.changes.keys()),before=Uint8Array.from(stroke.changes.values());
    this.push({kind:'paint',label:stroke.value?'涂绿':'涂白',indices,before,value:stroke.value,
      beforeCoverage:stroke.coverage,afterCoverage:clone(this.coverage),beforeEdited:stroke.maskEdited,afterEdited:this.maskEdited,bytes:indices.byteLength+before.byteLength+256});
    return true;
  }
  cancelStroke(){
    if(!this.stroke)return;for(const [k,value] of this.stroke.changes)this.mask[k]=value;
    this.coverage=this.stroke.coverage;this.maskEdited=this.stroke.maskEdited;this.stroke=null;
  }
  push(command){
    command.previous=this.current;command.next=id();this.current=command.next;this.updated=now();
    this.history.push(command);this.future=[];this.historyBytes+=command.bytes;
    while(this.history.length>100||this.historyBytes>32_000_000&&this.history.length>1)this.historyBytes-=this.history.shift().bytes;
  }
  changePaths(next,label){
    if(same(next,this.paths))return false;
    const command={kind:'paths',label,before:clone(this.paths),after:clone(next),bytes:JSON.stringify([this.paths,next]).length*2+256};
    this.paths=clone(next);this.push(command);return true;
  }
  addPath(points,width=.6){
    if(points.length<2||points.length>2000)throw Error('一条建议路径需要 2–2000 个点');if(this.paths.length>=500)throw Error('最多保存 500 条建议路径');
    const path={id:id(),points:clone(points),width_m:width,source:'workbench',created_utc:now()};
    this.changePaths([...this.paths,path],'新增建议路径');return path.id;
  }
  updatePath(pathID,patch){
    const path=this.paths.find(p=>p.id===pathID);if(!path)throw Error('未找到这条路径');
    const next={...path,...clone(patch)};if(next.points.length<2||next.points.length>2000)throw Error('路径需要 2–2000 个点，可以删除整条路径');
    this.changePaths(this.paths.map(p=>p.id===pathID?next:p),'修改建议路径');
  }
  removePath(pathID){this.changePaths(this.paths.filter(p=>p.id!==pathID),'删除建议路径');}
  apply(command,forward){
    if(command.kind==='paint'){
      command.indices.forEach((k,i)=>{this.mask[k]=forward?command.value:command.before[i];});
      this.coverage=clone(forward?command.afterCoverage:command.beforeCoverage);this.maskEdited=forward?command.afterEdited:command.beforeEdited;
    }else this.paths=clone(forward?command.after:command.before);
    this.current=forward?command.next:command.previous;this.updated=now();
  }
  undo(){const c=this.history.pop();if(!c)return;this.historyBytes-=c.bytes;this.apply(c,false);this.future.push(c);return c.label;}
  redo(){const c=this.future.pop();if(!c)return;this.apply(c,true);this.history.push(c);this.historyBytes+=c.bytes;return c.label;}
  markSaved(){this.saved=this.current;}
  serialize(){
    const value=this.original?clone(this.original):{schema_version:1,kind:'lidar_passage_calibration',map_id:this.project.map_id,walkable:null,base_geometry_sha256:this.project.geometry_sha256,auto_params:clone(this.params)};
    if(this.maskEdited&&this.coverage){
      const c=this.coverage,width=c.x1-c.x0,height=c.z1-c.z0,bits=new Uint8Array(width*height);
      for(let j=0;j<height;j++)bits.set(this.mask.subarray((c.z0+j)*this.spec.width+c.x0,(c.z0+j)*this.spec.width+c.x1),j*width);
      value.walkable={...this.rectangle,rle:encodeRLE(bits,width,height)};
      value.base_geometry_sha256=this.project.geometry_sha256;value.auto_params=clone(this.params);
    }
    value.suggested_paths=clone(this.paths);value.editor='workbench';value.updated_utc=this.updated;
    return value;
  }
}

// Old grids fall back to one global floor. New fields use the same block lookup as Swift.
export function floorSampler(global,field=null){
 if(!Number.isFinite(global))throw Error('地面高度无效');
 if(!field)return()=>global;
 const {origin_x,origin_z,block_m,width,height,values}=field;
 if(![origin_x,origin_z,block_m].every(Number.isFinite)||block_m<=0||!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width*height>4000000||!Array.isArray(values)||values.length!==width*height||!values.every(Number.isFinite))throw Error('局部地面高度数据无效');
 const fallback=Number.isFinite(field.global)?field.global:global;
 return(x,z)=>{const i=Math.floor((x-origin_x)/block_m),j=Math.floor((z-origin_z)/block_m);return i>=0&&j>=0&&i<width&&j<height?values[j*width+i]:fallback;};
}
const heightAt=(floor,x,z)=>typeof floor==='function'?floor(x,z):floor;
// Visual reference and optional brush guard; never changes the planner's obstacle layer.
export function readCloud(buffer, expectedCount){
 if(buffer.byteLength!==expectedCount*12||expectedCount>400000)throw Error('点云长度与地图记录不一致');
 const data=new DataView(buffer),points=new Float32Array(expectedCount*3);
 for(let i=0;i<points.length;i++){points[i]=data.getFloat32(i*4,true);if(!Number.isFinite(points[i]))throw Error('点云包含无效坐标');}
 return points;
}
export function cloudRaster(points,floorY,band='structure'){
 let minX=Infinity,minZ=Infinity,maxX=-Infinity,maxZ=-Infinity;
 for(let i=0;i<points.length;i+=3){minX=Math.min(minX,points[i]);minZ=Math.min(minZ,points[i+2]);maxX=Math.max(maxX,points[i]);maxZ=Math.max(maxZ,points[i+2]);}
 if(!points.length)return null;
 const cell=Math.max(.05,(maxX-minX)/2500,(maxZ-minZ)/2500),width=Math.ceil((maxX-minX)/cell)+1,height=Math.ceil((maxZ-minZ)/cell)+1;
 const density=new Uint8Array(width*height);let visible=0;
 for(let i=0;i<points.length;i+=3){const y=points[i+1]-heightAt(floorY,points[i],points[i+2]);if(band==='structure'&&(y<.4||y>2.6))continue;
  const k=Math.floor((points[i+2]-minZ)/cell)*width+Math.floor((points[i]-minX)/cell);density[k]=Math.min(255,density[k]+1);visible++;
 }
 return{origin_x:minX,origin_z:minZ,cell_m:cell,width,height,density,visible};
}
export function cloudBarriers(points,floorY,g){
 const n=g.width*g.height,hits=new Uint16Array(n),low=new Float32Array(n).fill(Infinity),high=new Float32Array(n).fill(-Infinity);
 for(let i=0;i<points.length;i+=3){const y=points[i+1]-heightAt(floorY,points[i],points[i+2]);if(y<.4||y>2.6)continue;
  const x=Math.floor((points[i]-g.origin_x)/g.cell_m),z=Math.floor((points[i+2]-g.origin_z)/g.cell_m);if(x<0||z<0||x>=g.width||z>=g.height)continue;
  const k=z*g.width+x;hits[k]=Math.min(65535,hits[k]+1);low[k]=Math.min(low[k],y);high[k]=Math.max(high[k],y);
 }
 const barriers=new Uint8Array(n);
 for(let z=0;z<g.height;z++)for(let x=0;x<g.width;x++){const k=z*g.width+x;if(!(hits[k]>=4||hits[k]>=2&&high[k]-low[k]>=.25))continue;
  // One-cell guard band closes tiny sampling gaps; not a traversability claim.
  for(let dz=-1;dz<=1;dz++)for(let dx=-1;dx<=1;dx++){const xx=x+dx,zz=z+dz;if(xx>=0&&zz>=0&&xx<g.width&&zz<g.height)barriers[zz*g.width+xx]=1;}
 }
 return barriers;
}
// A room may connect to its exterior through a distant door. Restrict each dab by
// local visibility as well, so that connectivity cannot let a large brush cross walls.
export function guardedStroke(barriers,g,a,b,diameter){
 const cellAt=p=>{const x=Math.floor((p[0]-g.origin_x)/g.cell_m),z=Math.floor((p[1]-g.origin_z)/g.cell_m);return x>=0&&z>=0&&x<g.width&&z<g.height?z*g.width+x:-1;};
 const clear=(p,q)=>{
  const steps=Math.max(1,Math.ceil(Math.hypot(q[0]-p[0],q[1]-p[1])/(g.cell_m/3)));let previous=cellAt(p);
  if(previous<0||barriers[previous])return false;
  for(let s=1;s<=steps;s++){const f=s/steps,k=cellAt([p[0]+(q[0]-p[0])*f,p[1]+(q[1]-p[1])*f]);if(k<0||barriers[k])return false;
   // Supercover a diagonal corner: don't slip between two touching wall cells.
   if(k!==previous&&k%g.width!==previous%g.width&&Math.floor(k/g.width)!==Math.floor(previous/g.width)){
    if(barriers[Math.floor(previous/g.width)*g.width+k%g.width]||barriers[Math.floor(k/g.width)*g.width+previous%g.width])return false;
   }previous=k;
  }return true;
 };
 const steps=Math.max(1,Math.ceil(Math.hypot(b[0]-a[0],b[1]-a[1])/(g.cell_m/3)));let last=a;
 for(let s=1;s<=steps;s++){const f=s/steps,p=[a[0]+(b[0]-a[0])*f,a[1]+(b[1]-a[1])*f];if(!clear(last,p))break;last=p;}
 const allowed=new Uint8Array(barriers.length),r=diameter/2,dx=last[0]-a[0],dz=last[1]-a[1],length2=dx*dx+dz*dz;
 const x0=Math.max(0,Math.floor((Math.min(a[0],last[0])-r-g.origin_x)/g.cell_m)),x1=Math.min(g.width-1,Math.floor((Math.max(a[0],last[0])+r-g.origin_x)/g.cell_m));
 const z0=Math.max(0,Math.floor((Math.min(a[1],last[1])-r-g.origin_z)/g.cell_m)),z1=Math.min(g.height-1,Math.floor((Math.max(a[1],last[1])+r-g.origin_z)/g.cell_m));
 for(let z=z0;z<=z1;z++)for(let x=x0;x<=x1;x++){const q=[g.origin_x+(x+.5)*g.cell_m,g.origin_z+(z+.5)*g.cell_m],t=length2?Math.max(0,Math.min(1,((q[0]-a[0])*dx+(q[1]-a[1])*dz)/length2)):0;
  const p=[a[0]+t*dx,a[1]+t*dz];if(Math.hypot(q[0]-p[0],q[1]-p[1])<=r+1e-8&&clear(p,q))allowed[z*g.width+x]=1;
 }
 return{allowed,last};
}

// Explicit manual height selection, not a second automatic traversability algorithm.
export function floorSelection(points,floorY,g,min,max,barriers=null){
 if(!Number.isFinite(min)||!Number.isFinite(max)||min>=max||min< -2||max>2)throw Error('高度范围需在 −2 到 2 米之间，且下限小于上限');
 const mask=new Uint8Array(g.width*g.height);
 for(let i=0;i<points.length;i+=3){const dy=points[i+1]-heightAt(floorY,points[i],points[i+2]);if(dy<min||dy>max)continue;
  const x=Math.floor((points[i]-g.origin_x)/g.cell_m),z=Math.floor((points[i+2]-g.origin_z)/g.cell_m);if(x<0||z<0||x>=g.width||z>=g.height)continue;
  const k=z*g.width+x;if(!barriers||!barriers[k])mask[k]=1;
 }return mask;
}

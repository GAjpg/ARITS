import assert from 'node:assert/strict';
import {readCloud,cloudRaster,cloudBarriers,guardedStroke,floorSelection,floorSampler} from './space_cloud.js';
import {SpaceEditor} from './space_edit.js';
import {encodeRLE} from './space_math.js';
const g={origin_x:-2,origin_z:-2,cell_m:.1,width:40,height:40};
const pts=[];
// A closed rectangular wall, with observations at two heights in each cell.
for(let i=10;i<=29;i++)for(const h of [.5,1.5])for(const [x,z] of [[i,10],[i,29],[10,i],[29,i]])pts.push(-2+(x+.5)*.1,h,-2+(z+.5)*.1);
pts.push(-1.5,0,-1.5,1.5,3,1.5);const points=new Float32Array(pts);
assert.deepEqual(readCloud(points.buffer,points.length/3),points);
assert.throws(()=>readCloud(points.buffer,1),/长度/);
const bad=new Float32Array([NaN,0,0]);assert.throws(()=>readCloud(bad.buffer,1),/无效/);
const raster=cloudRaster(points,0),all=cloudRaster(points,0,'all');
assert.equal(all.visible,raster.visible+2);assert(raster.origin_x<=-1.5&&raster.origin_x+raster.width*raster.cell_m>1.5,'Raw cloud extent includes points outside painted/floor regions');
const barriers=cloudBarriers(points,0,g),inside=guardedStroke(barriers,g,[0,0],[0,0],8).allowed;
assert(inside[20*40+20]);assert.equal(inside[0],0);assert.equal(inside[10*40+20],0);
const fixture={project:{map_id:'test',geometry_sha256:'hash'},calibration:null,grid:{grid:g,params:{cell_m:.1},suggested_paths:[],layers:{base:encodeRLE(new Uint8Array(1600),40,40)}}};
const e=new SpaceEditor(fixture);e.beginStroke(1);e.paint([0,0],[1.8,1.8],8,inside);e.endStroke();
assert(e.mask[20*40+20]);assert.equal(e.mask[0],0);assert.equal(e.mask[39*40+39],0,'Fast drag and large brush cannot escape a closed wall');
const painted=e.mask.slice();e.beginStroke(0);e.paint([0,0],[0,0],8,inside);e.endStroke();e.undo();assert.deepEqual(e.mask,painted);
e.undo();assert(!e.mask.some(Boolean));e.redo();assert.deepEqual(e.mask,painted);
e.beginStroke(1);e.paint([0,0],[0,0],8);e.endStroke();assert.equal(e.mask[0],1,'Disabling guard permits deliberate correction');
assert(!guardedStroke(barriers,g,[-.95,-.95],[-.95,-.95],8).allowed.some(Boolean),'Starting on a wall cannot start an unguarded fill');
console.log('Point cloud height reference, exact XYZ, closed-wall brush guard, fast drag and undo: passed.');

// Open-ended corridor: global connectivity reaches the exterior, but a dab must not.
const open=new Uint8Array(1600);for(let z=3;z<37;z++){open[z*40+12]=1;open[z*40+27]=1;}

const dab=guardedStroke(open,g,[0,0],[0,0],8);
assert(dab.allowed[20*40+20]);assert.equal(dab.allowed[20*40+1],0);assert.equal(dab.allowed[20*40+38],0);
const fast=guardedStroke(open,g,[0,0],[1.8,0],8);assert(fast.last[0]<.8);assert.equal(fast.allowed[20*40+38],0);
const smooth=guardedStroke(open,g,[0,-1],[0,1],.5);assert(smooth.allowed[10*40+20]&&smooth.allowed[29*40+20]);
console.log('Open corridor visibility and continuous fast-drag wall clipping: passed.');

const heightPoints=new Float32Array([0,.24,0, .5,.02,.5, 1,.8,1]);
const lower=floorSelection(heightPoints,0,g,-.15,.15),wider=floorSelection(heightPoints,0,g,-.15,.35);
assert.equal(lower[20*40+20],0);assert.equal(wider[20*40+20],1);assert.equal(wider[30*40+30],0,'A table above the selected height stays excluded');
const exclude=new Uint8Array(1600);exclude[20*40+20]=1;assert.equal(floorSelection(heightPoints,0,g,-.15,.35,exclude)[20*40+20],0);
assert.throws(()=>floorSelection(heightPoints,0,g,.5,.1),/高度范围/);
const assisted=new SpaceEditor(fixture);assisted.addPath([[0,0],[1,1]],.6);const before=assisted.mask.slice();
assisted.paintMask(wider);assert.equal(assisted.mask[20*40+20],1);assert.equal(assisted.paths.length,1);assisted.undo();assert.deepEqual(assisted.mask,before);assert.equal(assisted.paths.length,1);assisted.redo();assert.equal(assisted.mask[20*40+20],1);
console.log('Manual floor height selection, furniture exclusion, wall guard and reversible bulk calibration: passed.');

const local=floorSampler(-1.5,{origin_x:-2,origin_z:-2,block_m:2,width:2,height:2,values:[-1.5,-1.2,-1.5,-1.2],global:-1.5});
assert.equal(local(-.1,-.1),-1.5);assert.equal(local(0,-.1),-1.2);assert.equal(local(-2.01,-.1),-1.5);assert.equal(local(2,0),-1.5);
const drift=new Float32Array([-1,-1.5,-1, 1,-1.2,-1, 1,-.5,-1]);
assert.equal(floorSelection(drift,local,g,-.15,.15).reduce((a,b)=>a+b),2);
assert.equal(floorSelection(drift,-1.5,g,-.15,.15).reduce((a,b)=>a+b),1);
assert.equal(cloudRaster(drift,local).visible,1,'Local ground never becomes a structural point merely because its global Y drifts');
assert.equal(floorSampler(-1.5)(100,100),-1.5);
assert.throws(()=>floorSampler(-1.5,{origin_x:0,origin_z:0,block_m:2,width:2,height:1,values:[0],global:0}),/局部地面/);
console.log('Optional local floor lookup, negative/boundary coordinates, drifting-ground selection and old-grid fallback: passed.');

import assert from 'node:assert/strict';
import {SpaceEditor} from './space_edit.js';
import {encodeRLE,decodeRLE,worldToCell} from './space_math.js';
const spec={origin_x:-1,origin_z:-1,cell_m:.1,width:40,height:20};
function fixture(calibration=null){const base=new Uint8Array(800);return{project:{map_id:'test-map',geometry_sha256:'new-geometry'},calibration,grid:{grid:spec,params:{cell_m:.1},layers:{base:encodeRLE(base,40,20)},suggested_paths:calibration?.suggested_paths??[]}};}
assert.equal(encodeRLE(Uint8Array.from([0,1,1,1,1,1]),3,2),Buffer.from([1,2,0,3]).toString('base64'));
for(const width of [1,3,127,200])for(const height of [1,4]){const bits=Uint8Array.from({length:width*height},(_,i)=>+(i%3===0));assert.deepEqual(decodeRLE(encodeRLE(bits,width,height),width,height),bits);}
const editor=new SpaceEditor(fixture());
editor.beginStroke(1);editor.paint([-.8,-.65],[2.8,-.65],.21);editor.endStroke();
for(let i=2;i<38;i++)assert.equal(editor.mask[3*40+i],1,'Fast drag must leave a continuous stroke');
assert.equal(editor.dirty,true);assert.equal(editor.serialize().walkable.width,40);
const painted=editor.mask.slice();editor.undo();assert.equal(editor.mask.some(Boolean),false);assert.equal(editor.serialize().walkable,null);assert.equal(editor.dirty,false);
editor.redo();assert.deepEqual(editor.mask,painted);editor.markSaved();assert.equal(editor.dirty,false);editor.undo();assert.equal(editor.dirty,true);editor.redo();assert.equal(editor.dirty,false);
editor.beginStroke(0);editor.paint([0,-.65],[2,-.65],.4);editor.cancelStroke();assert.deepEqual(editor.mask,painted);assert.equal(editor.dirty,false);
const pathID=editor.addPath([[0,0],[2,0]],.6);assert.equal(editor.serialize().suggested_paths.length,1);
const exported=editor.serialize();assert.equal(decodeRLE(exported.walkable.rle,40,20)[worldToCell(spec,1,0).index],0,'Forced paths must never be burned into the base mask');
editor.updatePath(pathID,{points:[[0,0],[1,.2],[2,0]]});assert.equal(editor.paths[0].points.length,3);editor.undo();assert.equal(editor.paths[0].points.length,2);editor.removePath(pathID);assert.equal(editor.paths.length,0);editor.undo();assert.equal(editor.paths[0].id,pathID);
const old={schema_version:1,kind:'lidar_passage_calibration',map_id:'test-map',base_geometry_sha256:'old-geometry',editor:'phone',updated_utc:'old',walkable:{origin_x:0,origin_z:0,cell_m:.1,width:2,height:2,rle:encodeRLE(new Uint8Array(4),2,2)},suggested_paths:[],auto_params:{old_param:123},future_field:{keep:true}};
const partial=new SpaceEditor(fixture(old));partial.addPath([[0,0],[1,0]]);let saved=partial.serialize();assert.deepEqual(saved.walkable,old.walkable);assert.equal(saved.base_geometry_sha256,'old-geometry');assert.deepEqual(saved.auto_params,old.auto_params);assert.deepEqual(saved.future_field,old.future_field);
partial.beginStroke(1);partial.paint([1,.5],[1,.5],.3);partial.endStroke();saved=partial.serialize();assert.equal(saved.base_geometry_sha256,'new-geometry');assert(saved.walkable.width<spec.width);assert.equal(saved.walkable.origin_x,0);partial.undo();assert.deepEqual(partial.serialize().walkable,old.walkable);
console.log('Space editing continuous strokes, undo/redo, independent paths and calibration provenance: passed.');

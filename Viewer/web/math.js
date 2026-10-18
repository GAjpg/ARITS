import * as THREE from './vendor/three.module.js';
export function rowMatrix(rows) {
  if (!Array.isArray(rows) || rows.length !== 4 || rows.some(r => !Array.isArray(r) || r.length !== 4 || r.some(v => !Number.isFinite(v)))) throw new Error('无效姿态矩阵');
  return new THREE.Matrix4().set(...rows.flat());
}
export function cameraPose(candidate, frame) {
  return rowMatrix(candidate.transform_query_to_map).multiply(rowMatrix(frame.camera_to_session));
}
export function frustumSegments(c, depth=0.7) {
  const corner=(u,v)=>[(u-c.cx)/c.fx*depth,-(v-c.cy)/c.fy*depth,-depth];
  const corners=[corner(0,0),corner(c.image_width,0),corner(c.image_width,c.image_height),corner(0,c.image_height)];
  const segments=[];
  for(let i=0;i<4;i++) segments.push(0,0,0,...corners[i],...corners[i],...corners[(i+1)%4]);
  segments.push(0,0,0,0,0,-depth*1.6);
  return segments;
}
export function poseText(pose) {
  const p=new THREE.Vector3().setFromMatrixPosition(pose);
  const f=new THREE.Vector3(0,0,-1).transformDirection(pose);
  const heading=Math.atan2(f.x,-f.z)*180/Math.PI;
  return {position:p.toArray(),heading,forward:f.toArray()};
}
export function intrinsicProjection(c, near=.03, far=500) {
  return new THREE.Matrix4().set(2*c.fx/c.image_width,0,1-2*c.cx/c.image_width,0,
    0,2*c.fy/c.image_height,2*c.cy/c.image_height-1,0,
    0,0,-(far+near)/(far-near),-2*far*near/(far-near),0,0,-1,0);
}

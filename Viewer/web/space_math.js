// Display codec only. Planning and calibration acceptance belong to the shared Swift core.
export function decodeRLE(text, width, height) {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || width > 4000 || height > 4000 || width * height > 4000000) throw Error('栅格尺寸无效');
  if (typeof text !== 'string' || text.length > 22369624 || text.length % 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text)) throw Error('RLE Base64 无效');
  const raw = atob(text);
  if (raw.length > 16000000) throw Error('RLE 数据过大');
  const bits = new Uint8Array(width * height);
  let cursor = 0;
  function run() {
    let value = 0, multiplier = 1;
    for (let n = 0; n < 5; n++) {
      if (cursor >= raw.length) throw Error('RLE 数据不完整');
      const b = raw.charCodeAt(cursor++); value += (b & 127) * multiplier;
      if (!(b & 128)) return value;
      multiplier *= 128;
    }
    throw Error('RLE 游程过大');
  }
  for (let j = 0; j < height; j++) {
    let column = 0, green = false, first = true;
    while (column < width) {
      const count = run();
      if ((!first && count === 0) || column + count > width) throw Error('RLE 游程无效');
      if (green) bits.fill(1, j * width + column, j * width + column + count);
      column += count; green = !green; first = false;
    }
  }
  if (cursor !== raw.length) throw Error('RLE 有多余数据');
  return bits;
}

export function worldToCell(grid, x, z) {
  const i = Math.floor((x - grid.origin_x) / grid.cell_m), j = Math.floor((z - grid.origin_z) / grid.cell_m);
  return i >= 0 && j >= 0 && i < grid.width && j < grid.height ? {i, j, index:j * grid.width + i} : null;
}
export function calibratedAt(rect, x, z) {
  if (!rect) return false;
  const cell = rect.cell_m ?? 0.1;
  return x >= rect.origin_x && z >= rect.origin_z && x < rect.origin_x + rect.width * cell && z < rect.origin_z + rect.height * cell;
}
export function cellCenter(grid, i, j) {
  return [grid.origin_x + (i + 0.5) * grid.cell_m, grid.origin_z + (j + 0.5) * grid.cell_m];
}

// Shared on-disk codec; each row starts with a zero run, unsigned LEB128, standard Base64.
export function encodeRLE(bits, width, height) {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || width > 4000 || height > 4000 || width*height > 4000000 || bits.length !== width*height) throw Error('栅格尺寸无效');
  const bytes=[];
  const run=n=>{while(n>=128){bytes.push((n%128)|128);n=Math.floor(n/128);}bytes.push(n);};
  for(let j=0;j<height;j++){
    let value=0,count=0;
    for(let i=0;i<width;i++){const next=bits[j*width+i]?1:0;if(next===value)count++;else{run(count);count=1;value=next;}}
    run(count);
  }
  let binary='';for(let i=0;i<bytes.length;i+=16384)binary+=String.fromCharCode(...bytes.slice(i,i+16384));
  return btoa(binary);
}
export function segmentDistance(x,z,a,b) {
  const dx=b[0]-a[0],dz=b[1]-a[1],n=dx*dx+dz*dz;
  const t=n?Math.max(0,Math.min(1,((x-a[0])*dx+(z-a[1])*dz)/n)):0;
  return Math.hypot(x-a[0]-t*dx,z-a[1]-t*dz);
}

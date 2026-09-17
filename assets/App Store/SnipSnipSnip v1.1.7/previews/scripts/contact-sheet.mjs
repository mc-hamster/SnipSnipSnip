import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
const require = createRequire(import.meta.url);
const sharp = require('sharp');
const [input, output, intervalArg='5', startArg='0', endArg='120'] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: contact-sheet.mjs input output [interval start end]');
const interval=Number(intervalArg), start=Number(startArg), end=Number(endArg);
const columns=4, width=480, height=270, label=28;
const times=[];
for(let t=start;t<end;t+=interval) times.push(t);
const tiles=[];
for(let index=0;index<times.length;index++) {
  const t=times[index];
  const r=spawnSync(process.env.FFMPEG??'ffmpeg',['-hide_banner','-loglevel','error','-ss',String(t),'-i',input,'-frames:v','1','-vf',`scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:white`,'-f','image2pipe','-vcodec','png','-'],{maxBuffer:8*1024*1024});
  if(r.status!==0 || !r.stdout.length) throw new Error(r.stderr.toString()||`No frame at ${t}`);
  const x=(index%columns)*width, y=Math.floor(index/columns)*(height+label);
  tiles.push({input:r.stdout,left:x,top:y});
  const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${label}"><rect width="100%" height="100%" fill="#172135"/><text x="12" y="20" font-family="Helvetica" font-size="16" fill="white">${t.toFixed(1)} seconds</text></svg>`;
  tiles.push({input:Buffer.from(svg),left:x,top:y+height});
}
mkdirSync(path.dirname(output),{recursive:true});
await sharp({create:{width:columns*width,height:Math.ceil(times.length/columns)*(height+label),channels:3,background:'#172135'}}).composite(tiles).png().toFile(output);
console.log(output);

import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import sharp from 'sharp';

const root=path.dirname(fileURLToPath(import.meta.url));
const work=path.join(root,'review/preview-render');
await fs.mkdir(work,{recursive:true});
const headlines=['Compare two versions.','Explain it in Steps.','Bring every view together.'];
const labels=['COMPARISON','STEPS','COMBINED IMAGE'];
for(let i=0;i<3;i++) {
  const svg=`<svg width="1920" height="1080" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#f7eee3"/><stop offset="1" stop-color="#e3d2c0"/></linearGradient></defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <g font-family="Helvetica Neue, Arial, sans-serif">
    <circle cx="85" cy="42" r="6" fill="#ef741b"/>
    <text x="104" y="49" font-size="19" letter-spacing="2" font-weight="600" fill="#625b54">${labels[i]}</text>
    <text x="80" y="118" font-size="55" font-weight="700" fill="#181817">${headlines[i]}</text>
    <text x="1840" y="49" text-anchor="end" font-size="19" letter-spacing="2" font-weight="700" fill="#625b54">SNIPSNIPSNIP</text>
  </g></svg>`;
  await sharp(Buffer.from(svg)).png().toFile(path.join(work,`background-${i}.png`));
}
const output=path.join(root,'previews/en-US/SnipSnipSnip-1.2.0-Create.mp4');
await fs.mkdir(path.dirname(output),{recursive:true});
const args=['-hide_banner','-loglevel','error','-i',path.join(root,'captures/preview-source.mp4')];
for(let i=0;i<3;i++) args.push('-loop','1','-framerate','30','-i',path.join(work,`background-${i}.png`));
args.push('-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=48000',
  '-filter_complex',
  '[1:v][2:v]overlay=enable=gte(t\\,8.5)[bg1];[bg1][3:v]overlay=enable=gte(t\\,17)[bg];[0:v]scale=1660:900,setsar=1[ui];[bg][ui]overlay=130:165:shortest=1,format=yuv420p[v]',
  '-map','[v]','-map','4:a','-t','25.5','-r','30','-c:v','libx264','-preset','medium',
  '-profile:v','high','-level:v','4.0','-b:v','10M','-minrate','10M','-maxrate','10M',
  '-bufsize','20M','-x264-params','nal-hrd=cbr:force-cfr=1',
  '-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709',
  '-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-movflags','+faststart','-y',output);
execFileSync('ffmpeg',args,{stdio:'inherit'});
execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-ss','7','-i',output,
  '-frames:v','1','-y',path.join(root,'review/Preview-Poster.png')],{stdio:'inherit'});
console.log(output);

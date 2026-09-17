import {createRequire} from 'node:module';
import {spawn} from 'node:child_process';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
process.chdir(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'));
const require=createRequire(import.meta.url);
const sharp=require('sharp');
const manifest=JSON.parse(readFileSync('videos.json','utf8'));
const out='build';mkdirSync(out,{recursive:true});mkdirSync('captions',{recursive:true});
const esc=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const run=args=>new Promise((resolve,reject)=>{const p=spawn(process.env.FFMPEG??'ffmpeg',args,{stdio:['ignore','inherit','inherit']});p.on('error',reject);p.on('exit',code=>code===0?resolve():reject(new Error(`ffmpeg exited ${code}`)));});
if(process.argv[2]&&!manifest.videos.some(v=>v.id===process.argv[2]))throw Error('Video ID must be 01, 02, or 03.');
for(const v of manifest.videos){
 if(process.argv[2]&&process.argv[2]!==v.id)continue;
 const total=v.clips.reduce((sum,c)=>sum+c.duration,0);if(Math.abs(total-30)>.0001)throw new Error(`Duration ${total}`);
 const args=['-hide_banner','-loglevel','warning','-y','-filter_complex_threads','2'],filters=[];
 v.clips.forEach((c,i)=>{
  args.push('-ss',String(c.start),'-t',String(c.duration+.2),'-i',c.source);
  const [cw,ch,cx,cy]=c.crop, scale=Math.min(1920/cw,960/ch);
  const width=v.layout==='legacy'?2*Math.round(cw*960/ch/2):2*Math.floor(cw*scale/2),height=v.layout==='legacy'?960:2*Math.floor(ch*scale/2);
  filters.push(`[${i}:v]setpts=PTS-STARTPTS,fps=30,trim=end_frame=${Math.round(c.duration*30)},settb=AVTB,crop=${cw}:${ch}:${cx}:${cy},scale=${width}:${height}:flags=lanczos:out_color_matrix=bt709,setsar=1,pad=1920:1080:(ow-iw)/2:120+(960-ih)/2:color=0x131A29,format=yuv420p[s${i}]`);
 });
 filters.push(v.clips.map((_,i)=>`[s${i}]`).join('')+`concat=n=${v.clips.length}:v=1:a=0[base]`);
 let last='base';
 for(let k=0;k<v.captions.length;k++){
  const [start,end,feature,line]=v.captions[k],file=`captions/${v.id}-${k}.png`;
  const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="120"><rect width="1920" height="120" fill="#131A29"/><text x="68" y="32" fill="#9FB7FF" font-family="Helvetica" font-size="17" font-weight="700" letter-spacing="2">${esc(feature)}</text><text x="68" y="87" fill="#FFFFFF" font-family="Helvetica" font-size="43" font-weight="700">${esc(line)}</text><text x="1852" y="77" fill="#DCE5F6" text-anchor="end" font-family="Helvetica" font-size="27" font-weight="700">SnipSnipSnip</text><rect x="68" y="110" width="52" height="3" rx="1.5" fill="#789BFF"/></svg>`;
  await sharp(Buffer.from(svg)).png().toFile(file);
  const idx=v.clips.length+k;args.push('-loop','1','-framerate','30','-i',file);
  filters.push(`[${last}][${idx}:v]overlay=0:0:enable='gte(t,${start})*lt(t,${end})':shortest=1[c${k}]`);last=`c${k}`;
 }
 filters.push(`[${last}]setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709[video]`);
 const audioIdx=v.clips.length+v.captions.length;args.push('-i',v.audio);
 filters.push(`[${audioIdx}:a]loudnorm=I=${v.lufs}:LRA=5:TP=-2,aresample=48000,atrim=duration=30,asetpts=PTS-STARTPTS[audio]`);
 args.push('-filter_complex',filters.join(';'),'-map','[video]','-map','[audio]','-t','30','-r','30','-fps_mode','cfr','-c:v','libx264','-preset','medium','-profile:v','high','-level:v','4.0','-pix_fmt','yuv420p','-b:v','11M','-minrate','11M','-maxrate','11M','-bufsize','22M','-x264-params','nal-hrd=cbr:force-cfr=1','-g','60','-keyint_min','60','-sc_threshold','0','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv','-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-video_track_timescale','30000','-movflags','+faststart','-metadata',`title=SnipSnipSnip — ${v.name.substring(3).replaceAll('-',' ')}`,'-metadata','comment=Real App Store build footage. Screenshot and video workflows. Original instrumental score.',`${out}/${v.name}.mp4`);
 writeFileSync(`${out}/${v.id}-render-command.json`,JSON.stringify(args,null,2));
 console.log(`Rendering ${v.name}`);await run(args);
 await run(['-hide_banner','-loglevel','error','-y','-ss',String(v.poster),'-i',`${out}/${v.name}.mp4`,'-frames:v','1',`${out}/${v.name}-poster.png`]);
 console.log(`Completed ${v.name}.`);
}

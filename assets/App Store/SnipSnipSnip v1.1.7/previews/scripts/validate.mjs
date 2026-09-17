import {readFileSync,writeFileSync,statSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
process.chdir(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'));
const out=process.argv[2]??'output';
const manifest=JSON.parse(readFileSync('videos.json','utf8'));
const run=(bin,args)=>{const r=spawnSync(bin,args,{encoding:'utf8',maxBuffer:16*1024*1024});if(r.status!==0)throw new Error(r.stderr||`${bin} ${r.status}`);return r.stdout;};
const all=[];
for(const item of manifest.videos){
 const file=`${out}/${item.name}.mp4`, b=readFileSync(file);
 const p=JSON.parse(run(process.env.FFPROBE??'ffprobe',['-v','error','-show_format','-show_streams','-of','json',file]));
 const v=p.streams.find(s=>s.codec_type==='video'), a=p.streams.find(s=>s.codec_type==='audio');
 const frames=JSON.parse(run(process.env.FFPROBE??'ffprobe',['-v','error','-select_streams','v:0','-show_frames','-show_entries','frame=best_effort_timestamp_time','-of','json',file])).frames;
 let cfr=true;
 frames.forEach((f,i)=>{if(Math.abs(Number(f.best_effort_timestamp_time)-i/30)>.00001)cfr=false;});
 let moov=-1,mdat=-1;
 for(let off=0;off+8<b.length;){let n=b.readUInt32BE(off);const type=b.toString('ascii',off+4,off+8);if(type==='moov')moov=off;if(type==='mdat')mdat=off;if(n===1)n=Number(b.readBigUInt64BE(off+8));if(n===0)break;off+=n;}
 const checks={duration30:Math.abs(Number(p.format.duration)-30)<.001,dimensions:v.width===1920&&v.height===1080,frames900:frames.length===900,cfr30:cfr&&v.avg_frame_rate==='30/1',h264:v.codec_name==='h264',highLevel40:v.profile==='High'&&v.level===40,pixelFormat:v.pix_fmt==='yuv420p',progressive:v.field_order==='progressive',bt709:v.color_space==='bt709'&&v.color_transfer==='bt709'&&v.color_primaries==='bt709',targetBitrate:Number(v.bit_rate)>=10000000&&Number(v.bit_rate)<=12000000,aacStereo48k:a?.codec_name==='aac'&&a.channels===2&&Number(a.sample_rate)===48000,audio256k:Math.abs(Number(a.bit_rate)-256000)<15000,sizeBelow500MB:b.length<500000000,fastStart:moov>=0&&moov<mdat};
 run(process.env.FFMPEG??'ffmpeg',['-hide_banner','-v','error','-xerror','-i',file,'-f','null','-']);checks.fullDecode=true;
 const result={file,bytes:statSync(file).size,duration:Number(p.format.duration),videoBitrate:Number(v.bit_rate),audioBitrate:Number(a.bit_rate),frames:frames.length,posterSeconds:item.poster,sha256:createHash('sha256').update(b).digest('hex'),checks,pass:Object.values(checks).every(Boolean)};
 all.push(result);console.log(item.name,result.pass?'PASS':'FAIL',checks);
}
writeFileSync(`${out}/technical-validation.json`,JSON.stringify(all,null,2));
if(all.some(r=>!r.pass))process.exitCode=1;

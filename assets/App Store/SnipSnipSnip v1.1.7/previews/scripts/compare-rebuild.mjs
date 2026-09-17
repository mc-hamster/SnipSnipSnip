// Pixel-similarity regression check; complements, not replaces, visual review.
import {readFileSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
process.chdir(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'));
const manifest=JSON.parse(readFileSync('videos.json','utf8')),results=[];
for(const v of manifest.videos){
 const r=spawnSync(process.env.FFMPEG??'ffmpeg',['-hide_banner','-nostats','-i',v.output,'-i',`build/${v.name}.mp4`,'-filter_complex','[0:v][1:v]ssim','-an','-f','null','-'],{encoding:'utf8',maxBuffer:4*1024*1024});
 if(r.status!==0)throw Error(r.stderr);
 const match=/All:([0-9.]+)/.exec(r.stderr);if(!match)throw Error('No SSIM result');
 const similarity=Number(match[1]),pass=similarity>=.995;
 results.push({id:v.id,ssim:similarity,threshold:.995,pass});console.log(v.id,similarity,pass?'PASS':'FAIL');
}
writeFileSync('build/rebuild-comparison.json',JSON.stringify(results,null,2)+'\n');
if(results.some(r=>!r.pass))process.exitCode=1;

// Lossless archival compression. Decoded pixels must match before any source is replaced.
import {readFileSync,writeFileSync,mkdirSync,renameSync,existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
process.chdir(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'));
const ffmpeg=process.env.FFMPEG??'ffmpeg';
const run=args=>{const r=spawnSync(ffmpeg,args,{encoding:'utf8',maxBuffer:1024*1024});if(r.status!==0)throw Error(r.stderr);return r.stdout;};
const videos=JSON.parse(readFileSync('videos.json','utf8')).videos;
mkdirSync('build/compact',{recursive:true});
for(const source of new Set(videos.flatMap(v=>v.clips.map(c=>c.source)))){
 const dest='build/compact/'+path.basename(source);
 if(existsSync(dest))throw Error('Temporary file already exists: '+dest);
 run(['-v','error','-n','-i',source,'-an','-map_metadata','-1','-c:v','libx264','-qp','0','-preset','medium','-threads','2',dest]);
 const hash=file=>run(['-v','error','-i',file,'-map','0:v','-vf','format=yuv420p','-f','hash','-hash','sha256','-']);
 if(hash(source)!==hash(dest))throw Error('Decoded pixel mismatch: '+source);
 renameSync(dest,source);console.log('Lossless pixels verified:',source);
}
const entries=readFileSync('assets.sha256','utf8').trim().split('\n').map(line=>line.slice(66));
writeFileSync('assets.sha256',entries.map(file=>createHash('sha256').update(readFileSync(file)).digest('hex')+'  '+file).join('\n')+'\n');

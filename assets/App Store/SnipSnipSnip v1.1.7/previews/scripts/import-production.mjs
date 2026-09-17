// One-time archiving from the local production directory. Not needed to render or retrieve.
import {readFileSync,writeFileSync,mkdirSync,copyFileSync,existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const production=process.argv[2];
if(!production)throw Error('Usage: node scripts/import-production.mjs /absolute/path/to/Live Previews');
if(existsSync(path.join(root,'videos.json')))throw Error('Archive already exists; refusing to replace it.');
const revision=path.join(production,'Video 02 Revision');
const read=p=>JSON.parse(readFileSync(p,'utf8'));
const original=read(path.join(production,'edit-manifest.json'));
const revised=read(path.join(revision,'edit-manifest.json')).videos[0];
const selected=[original.videos[0],revised,original.videos[2]];
const drives=['1OEx6lSWU2V4UITmsG2UF1Vq9Lo4_CCZy','1wPvX3W634G3ZdONkvLWtmIa53_fWJ96J','1qG34sVgwuLnb047N8UnwwPQy5M7Yt_9_'];
const hashes=['5657f1a28712272bfeabd9c93db85ceca9f2f13eb6a2e13f9b4c139aee82ca03','db62d6ff12b11c1db0df44dd7a40f695245817a696b9e9ffa12ece5f5267d548','ab6dc5233de3b1aeb62d58fadee94214f2769278e391125f1fa93fa2cba8646e'];
for(const d of ['sources','audio','output'])mkdirSync(path.join(root,d),{recursive:true});
const digest=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
const videos=[];
for(let i=0;i<selected.length;i++){
 const v=selected[i],id=String(i+1).padStart(2,'0'),base=i===1?revision:production;
 const final=path.join(base,'Final Previews',v.name+'.mp4');
 if(digest(final)!==hashes[i])throw Error('Approved final hash differs: '+final);
 const output='output/'+v.name+'.mp4';copyFileSync(final,path.join(root,output));
 const poster='output/'+v.name+'-poster.png';copyFileSync(path.join(base,'Final Previews',v.name+'-poster.png'),path.join(root,poster));
 const clips=[];
 for(let k=0;k<v.clips.length;k++){
  const c=v.clips[k],source=path.isAbsolute(c.source)?c.source:path.join(base,c.source);
  const crop=c.crop??[2560,1440-c.cropTop,0,c.cropTop],frames=Math.round(c.duration*30);
  const dest=`sources/${id}-${String(k+1).padStart(2,'0')}.mkv`;
  if(existsSync(path.join(root,dest)))throw Error('Existing source: '+dest);
  // Decode only the selected interval, retain the reviewed crop, and save losslessly.
  // No unselected/private desktop pixels or audio are carried into the repository.
  const args=['-hide_banner','-loglevel','error','-n','-ss',String(c.start),'-t',String(c.duration+.2),'-i',source,'-vf',`setpts=PTS-STARTPTS,fps=30,trim=end_frame=${frames},crop=${crop.join(':')}`,'-an','-map_metadata','-1','-c:v','libx264','-qp','0','-preset','medium','-threads','2',path.join(root,dest)];
  const r=spawnSync(process.env.FFMPEG??'ffmpeg',args,{stdio:'inherit'});if(r.status!==0)throw Error('Source extraction failed: '+dest);
  clips.push({source:dest,start:0,duration:c.duration,crop:[crop[0],crop[1],0,0],origin:{take:path.basename(c.source),start:c.start,crop},note:c.note??'Reviewed live UI footage from the approved original cut.'});
  console.log('Archived',dest);
 }
 const audio=i===1?'audio/energetic.wav':'audio/quiet.wav';
 if(!existsSync(path.join(root,audio)))copyFileSync(path.join(base,'original-preview-score.wav'),path.join(root,audio));
 videos.push({id,name:v.name,poster:v.poster,posterFile:poster,output,sha256:hashes[i],bytes:readFileSync(final).length,drive:{fileId:drives[i],url:`https://drive.google.com/file/d/${drives[i]}/view?usp=drivesdk`},audio,lufs:i===1?-20:-22,layout:i===1?'contain':'legacy',clips,captions:v.captions.map(c=>c.length===3?[c[0],c[1],v.feature,c[2]]:c)});
}
writeFileSync(path.join(root,'videos.json'),JSON.stringify({schemaVersion:1,build:{version:'1.1.7',number:171,edition:'App Store Release',sandboxed:true},format:{width:1920,height:1080,fps:30,seconds:30},driveFolder:'https://drive.google.com/drive/folders/12C2_deds_Tq5zSoSJFqPWial0KpfzLma',videos},null,2)+'\n');
const files=[...new Set(videos.flatMap(v=>[v.output,v.posterFile,v.audio,...v.clips.map(c=>c.source)]))];
writeFileSync(path.join(root,'assets.sha256'),files.map(f=>digest(path.join(root,f))+'  '+f).join('\n')+'\n');
console.log('Archive complete.');

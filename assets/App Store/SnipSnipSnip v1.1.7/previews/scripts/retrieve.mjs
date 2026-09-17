import {createReadStream,createWriteStream} from 'node:fs';
import {readFile,mkdir,mkdtemp,link,rm,stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {Readable,Transform} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export async function sha256(file){
 const hash=createHash('sha256');
 for await(const chunk of createReadStream(file))hash.update(chunk);
 return hash.digest('hex');
}
export function within(root,relative){
 const p=path.resolve(root,relative);
 if(path.isAbsolute(relative)||!p.startsWith(path.resolve(root)+path.sep))throw Error('Asset path escapes archive');
 return p;
}
export async function verifyFile(file,expected,bytes){
 const info=await stat(file);
 if(bytes!==undefined&&info.size!==bytes)throw Error('Size mismatch: '+file);
 if(await sha256(file)!==expected)throw Error('SHA-256 mismatch: '+file);
}
export async function materialize(video,destination,{root,fromDrive=false,token,fetchImpl=fetch}={}){
 const target=path.join(destination,path.basename(video.output));
 try{await stat(target);await verifyFile(target,video.sha256,video.bytes);return 'Already verified: '+target;}
 catch(error){if(error.code!=='ENOENT')throw error;}
 await mkdir(destination,{recursive:true});
 const temporary=await mkdtemp(path.join(destination,'.preview-retrieve-'));
 const partial=path.join(temporary,'download.partial');
 try{
  let input;
  if(fromDrive){
   if(!token)throw Error('Private Drive download requires GOOGLE_DRIVE_ACCESS_TOKEN with read access. No credentials are stored by this script.');
   if(!/^[A-Za-z0-9_-]+$/.test(video.drive.fileId))throw Error('Invalid Drive file ID');
   const response=await fetchImpl(`https://www.googleapis.com/drive/v3/files/${video.drive.fileId}?alt=media`,{headers:{Authorization:`Bearer ${token}`},redirect:'error'});
   if(!response.ok)throw Error(`Drive download failed (HTTP ${response.status}). Use an account with access to the private folder.`);
   if(!response.body)throw Error('Drive returned no file body');
   input=Readable.fromWeb(response.body);
  }else input=createReadStream(within(root,video.output));
  let received=0;
  const limit=new Transform({transform(chunk,encoding,callback){received+=chunk.length;callback(received>video.bytes?Error('Download exceeds expected size'):null,chunk);}});
  await pipeline(input,limit,createWriteStream(partial,{flags:'wx',mode:0o600}));
  await verifyFile(partial,video.sha256,video.bytes);
  // Atomic, no-clobber publication. Existing files are never replaced, including races.
  await link(partial,target);
  return 'Retrieved and verified: '+target;
 }finally{await rm(temporary,{recursive:true,force:true});}
}
export async function verifyAssets(root){
 const entries=(await readFile(path.join(root,'assets.sha256'),'utf8')).trim().split('\n');
 for(const entry of entries){
  const match=/^([0-9a-f]{64})  (.+)$/.exec(entry);if(!match)throw Error('Invalid checksum entry');
  await verifyFile(within(root,match[2]),match[1]);
 }
 return entries.length;
}
async function main(){
 const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
 const manifest=JSON.parse(await readFile(path.join(root,'videos.json'),'utf8'));
 const args=process.argv.slice(2);let destination=path.join(root,'output'),fromDrive=false,verify=false,links=false;
 for(let i=0;i<args.length;i++){
  if(args[i]==='--to'){if(!args[i+1])throw Error('--to requires a directory');destination=path.resolve(args[++i]);}
  else if(args[i]==='--from-drive')fromDrive=true;
  else if(args[i]==='--verify')verify=true;
  else if(args[i]==='--links')links=true;
  else throw Error('Usage: retrieve.mjs [--to DIRECTORY] [--from-drive] [--verify] [--links]');
 }
 if(links){for(const v of manifest.videos)console.log(v.id,v.name,v.drive.url);return;}
 if(verify){console.log(`Verified ${await verifyAssets(root)} archived assets.`);return;}
 for(const v of manifest.videos)console.log(await materialize(v,destination,{root,fromDrive,token:process.env.GOOGLE_DRIVE_ACCESS_TOKEN}));
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(error=>{console.error(error.message);process.exitCode=1;});

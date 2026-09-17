import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,readdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {materialize,within} from './retrieve.mjs';
async function fixture(t){
 const root=await mkdtemp(path.join(tmpdir(),'preview-retrieval-test-'));
 t.after(()=>rm(root,{recursive:true,force:true}));
 await mkdir(path.join(root,'output'));
 const data=Buffer.from('test media bytes');await writeFile(path.join(root,'output/test.mp4'),data);
 return {root,data,destination:path.join(root,'delivery'),video:{output:'output/test.mp4',bytes:data.length,sha256:createHash('sha256').update(data).digest('hex'),drive:{fileId:'test-file'}}};
}
test('local retrieval is hash-verified and idempotent',async t=>{
 const f=await fixture(t);await materialize(f.video,f.destination,{root:f.root});
 assert.deepEqual(await readFile(path.join(f.destination,'test.mp4')),f.data);
 assert.match(await materialize(f.video,f.destination,{root:f.root}),/Already verified/);
});
test('existing different files are preserved',async t=>{
 const f=await fixture(t);await mkdir(f.destination);await writeFile(path.join(f.destination,'test.mp4'),'keep');
 await assert.rejects(materialize(f.video,f.destination,{root:f.root}),/mismatch/);
 assert.equal(await readFile(path.join(f.destination,'test.mp4'),'utf8'),'keep');
});
test('corrupt downloaded bytes are rejected and partial files removed',async t=>{
 const f=await fixture(t);
 await assert.rejects(materialize(f.video,f.destination,{root:f.root,fromDrive:true,token:'test-token',fetchImpl:async()=>new Response('bad')}),/mismatch/);
 assert.deepEqual(await readdir(f.destination),[]);
});
test('authenticated download verifies bytes without exposing credentials',async t=>{
 const f=await fixture(t);
 await materialize(f.video,f.destination,{root:f.root,fromDrive:true,token:'test-token',fetchImpl:async(url,options)=>{
  assert.equal(url,'https://www.googleapis.com/drive/v3/files/test-file?alt=media');
  assert.equal(options.headers.Authorization,'Bearer test-token');assert.equal(options.redirect,'error');
  return new Response(f.data);
 }});
 assert.deepEqual(await readFile(path.join(f.destination,'test.mp4')),f.data);
});
test('authentication failure and oversized downloads leave no result',async t=>{
 const f=await fixture(t);
 await assert.rejects(materialize(f.video,f.destination,{root:f.root,fromDrive:true}),/requires/);
 await assert.rejects(materialize(f.video,f.destination,{root:f.root,fromDrive:true,token:'test',fetchImpl:async()=>new Response('',{status:403})}),/HTTP 403/);
 await assert.rejects(materialize(f.video,f.destination,{root:f.root,fromDrive:true,token:'test',fetchImpl:async()=>new Response(Buffer.alloc(100))}),/exceeds/);
 assert.deepEqual(await readdir(f.destination),[]);
});
test('archive paths cannot escape their root',()=>{assert.throws(()=>within('/tmp/archive','../secret'));assert.throws(()=>within('/tmp/archive','/private/secret'));});

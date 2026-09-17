import {writeFileSync} from 'node:fs';
// Original 128 BPM instrumental. Every sound is synthesized here; no samples.
const rate=48000,seconds=30,n=rate*seconds,beat=60/128;
const left=new Float64Array(n),right=new Float64Array(n);
const chords=[[48,55,59,64,67],[45,52,55,60,64],[41,48,52,57,60],[43,50,55,59,62]];
let seed=81291;const noise=()=>{seed=(1664525*seed+1013904223)>>>0;return seed/2147483648-1;};
const freq=m=>440*2**((m-69)/12);
function note(time,midi,amp,duration,pan=0){
 const begin=Math.floor(time*rate),len=Math.min(Math.floor(duration*rate),n-begin),f=freq(midi);
 for(let i=0;i<len;i++){
  const t=i/rate,env=(1-Math.exp(-t*180))*Math.exp(-t*4)*Math.min(1,(duration-t)*15);
  const tone=Math.sin(2*Math.PI*f*t)+.23*Math.sin(4*Math.PI*f*t)*Math.exp(-t*5)+.07*Math.sin(6*Math.PI*f*t)*Math.exp(-t*8),v=tone*env*amp;
  left[begin+i]+=v*Math.sqrt((1-pan)/2);right[begin+i]+=v*Math.sqrt((1+pan)/2);
 }
}
function drum(time,kind,amp){
 const begin=Math.floor(time*rate),len=Math.min(Math.floor(rate*.22),n-begin);let prev=0;
 for(let i=0;i<len;i++){
  const t=i/rate,raw=noise(),hi=raw-prev;prev=raw;let v;
  if(kind==='kick')v=Math.sin(2*Math.PI*(47*t+2.2*(1-Math.exp(-t*35))))*Math.exp(-t*30)*amp;
  else if(kind==='clap')v=(hi*.45+Math.sin(2*Math.PI*180*t)*.12)*Math.exp(-t*42)*amp;
  else v=hi*Math.exp(-t*110)*amp;
  left[begin+i]+=v;right[begin+i]+=v*(kind==='hat'?.8:1);
 }
}
for(let bar=0;bar<16;bar++){
 const c=chords[Math.floor(bar/2)%4],base=bar*4*beat;
 for(let b=0;b<4;b++){
  drum(base+b*beat,'kick',.065);
  if(b%2)drum(base+b*beat,'clap',.045);
  drum(base+(b+.5)*beat,'hat',.023);
  note(base+b*beat,c[0]-12,.12,.43,-.05);
 }
 const pattern=[[0,1],[.5,2],[1.5,3],[2,4],[2.75,2],[3.5,3]];
 for(const [offset,k]of pattern)note(base+offset*beat,c[k]+12,.067,.75,(k-2.5)*.24);
}
const delay=Math.floor(beat*.75*rate);
for(let i=delay;i<n;i++){left[i]+=right[i-delay]*.14;right[i]+=left[i-delay]*.11;}
const wav=Buffer.alloc(44+n*4);
wav.write('RIFF',0);wav.writeUInt32LE(36+n*4,4);wav.write('WAVEfmt ',8);wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(2,22);wav.writeUInt32LE(rate,24);wav.writeUInt32LE(rate*4,28);wav.writeUInt16LE(4,32);wav.writeUInt16LE(16,34);wav.write('data',36);wav.writeUInt32LE(n*4,40);
for(let i=0;i<n;i++){
 const t=i/rate,fade=Math.min(1,t/.025,Math.max(0,(30-t)/.7));
 wav.writeInt16LE(Math.round(Math.tanh(left[i])*fade*32767),44+i*4);
 wav.writeInt16LE(Math.round(Math.tanh(right[i])*fade*32767),46+i*4);
}
writeFileSync(new URL('../audio/energetic.wav',import.meta.url),wav);console.log('Generated original 128 BPM score.');

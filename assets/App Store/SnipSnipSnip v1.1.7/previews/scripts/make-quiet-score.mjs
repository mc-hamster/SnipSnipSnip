import { writeFileSync } from 'node:fs';
// Original instrumental composed for these previews. No samples or third-party music.
const rate=48000, seconds=30, n=rate*seconds, beat=60/112;
const left=new Float64Array(n), right=new Float64Array(n);
const chords=[[48,55,59,64,67],[45,52,55,60,64],[41,48,52,57,60],[43,50,55,57,62],[48,55,59,64,67],[41,48,52,57,60],[48,55,60,62,64]];
const freq=m=>440*2**((m-69)/12);
function note(time,midi,amp,duration,pan=0){
 const begin=Math.floor(time*rate), len=Math.min(Math.floor(duration*rate),n-begin), f=freq(midi);
 for(let i=0;i<len;i++){
  const t=i/rate, attack=1-Math.exp(-t*130), env=attack*Math.exp(-t*2.5)*Math.min(1,(duration-t)*6);
  const tone=Math.sin(2*Math.PI*f*t)+0.25*Math.sin(2*Math.PI*f*2*t)*Math.exp(-t*4)+0.09*Math.sin(2*Math.PI*f*3*t)*Math.exp(-t*8);
  const v=tone*env*amp;
  left[begin+i]+=v*Math.sqrt((1-pan)/2);right[begin+i]+=v*Math.sqrt((1+pan)/2);
 }
}
for(let bar=0;bar<14;bar++){
 const c=chords[Math.floor(bar/2)], base=bar*4*beat;
 note(base,c[0],0.095,2.3,-.1);
 const pattern=[[0,1],[.75,2],[1.5,3],[2.5,4],[3.25,2]];
 for(const [offset,k]of pattern) note(base+offset*beat,c[k]+12,0.074,1.4,(k-2.5)*.23);
 for(const offset of[0,2]){
  const begin=Math.floor((base+offset*beat)*rate);
  for(let i=0;i<rate*.14&&begin+i<n;i++){
   const t=i/rate,v=.055*Math.sin(2*Math.PI*(48*t+2.0*(1-Math.exp(-t*32))))*Math.exp(-t*35);
   left[begin+i]+=v;right[begin+i]+=v;
  }
 }
}
// Quiet, diffuse delay gives a little space without obscuring UI sounds.
const delay=Math.floor(beat*.75*rate);
for(let i=delay;i<n;i++){left[i]+=right[i-delay]*.16;right[i]+=left[i-delay]*.13;}
const wav=Buffer.alloc(44+n*4);
wav.write('RIFF',0);wav.writeUInt32LE(36+n*4,4);wav.write('WAVEfmt ',8);wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(2,22);wav.writeUInt32LE(rate,24);wav.writeUInt32LE(rate*4,28);wav.writeUInt16LE(4,32);wav.writeUInt16LE(16,34);wav.write('data',36);wav.writeUInt32LE(n*4,40);
for(let i=0;i<n;i++){
 const t=i/rate,fade=Math.min(1,t/.12,Math.max(0,(30-t)/1.7));
 wav.writeInt16LE(Math.round(Math.tanh(left[i])*fade*32767),44+i*4);
 wav.writeInt16LE(Math.round(Math.tanh(right[i])*fade*32767),46+i*4);
}
writeFileSync(new URL('../audio/quiet.wav',import.meta.url),wav);
console.log('Original 30-second stereo score generated.');

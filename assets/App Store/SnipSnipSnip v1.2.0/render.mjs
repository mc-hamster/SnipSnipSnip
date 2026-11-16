import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import sharp from 'sharp';

const root = path.dirname(fileURLToPath(import.meta.url));
const slides = JSON.parse(await fs.readFile(path.join(root, 'slides.json'), 'utf8'));
const output = path.join(root, 'screenshots/en-US');
await fs.mkdir(output, {recursive:true});
const xml = s => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const text = (s,x,y,size,weight=500,color='#56524d') => s.split('\n').map((line,i) => `<text x="${x}" y="${y+i*size*1.35}" font-size="${size}" font-weight="${weight}" fill="${color}">${xml(line)}</text>`).join('');

function chrome(slide) {
  const side = slide.layout === 'palette';
  return Buffer.from(`<svg width="1440" height="900" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#f7eee3"/><stop offset="1" stop-color="#e3d2c0"/></linearGradient>
      <radialGradient id="warm"><stop stop-color="#ff9a3d" stop-opacity=".17"/><stop offset="1" stop-color="#ff9a3d" stop-opacity="0"/></radialGradient>
      <radialGradient id="cool"><stop stop-color="#6ea9d8" stop-opacity=".14"/><stop offset="1" stop-color="#6ea9d8" stop-opacity="0"/></radialGradient>
      <linearGradient id="rule"><stop stop-color="#ef741b"/><stop offset="1" stop-color="#ef741b" stop-opacity="0"/></linearGradient>
    </defs>
    <rect width="1440" height="900" fill="url(#bg)"/>
    <ellipse cx="1180" cy="340" rx="550" ry="440" fill="url(#warm)"/>
    <ellipse cx="120" cy="740" rx="500" ry="390" fill="url(#cool)"/>
    <g font-family="Helvetica Neue, Arial, sans-serif">
      <circle cx="76" cy="58" r="6" fill="#ef741b"/>
      <text x="96" y="65" font-size="17" font-weight="700" letter-spacing="1.9" fill="#625b54">${xml(slide.eyebrow)}</text>
      ${text(slide.headline,70,side?242:145,side?62:66,750,'#181817')}
      ${text(slide.subhead,73,side?310:199,27)}
      <rect x="72" y="${side?405:228}" width="${side?400:510}" height="3" rx="1.5" fill="url(#rule)"/>
      ${slide.detail?text(slide.detail,73,473,25,500):''}
      ${slide.layout==='tools'?text('Measure with Screen Ruler.',74,349,29,600,'#25221f')+text('Inspect color and pixel detail.',74,624,29,600,'#25221f'):''}
      <text x="72" y="868" font-size="16" font-weight="700" letter-spacing="2" fill="#68625c">SNIPSNIPSNIP</text>
    </g>
  </svg>`);
}

async function fit(source, box) {
  const p = path.join(root,'captures',source);
  // Missing sources are fatal; never make uploadable placeholders.
  let input = sharp(p);
  if (source === '09-screen-ruler.png') {
    // Keep the captured ruler face; omit the desktop behind its floating close button.
    input = input.extract({left:24,top:56,width:1232,height:94});
  } else {
    const m=await input.metadata();
    // Exclude pixels outside the native rounded panel, without repainting its UI.
    input=input.composite([{input:Buffer.from(`<svg width="${m.width}" height="${m.height}" xmlns="http://www.w3.org/2000/svg"><rect width="${m.width}" height="${m.height}" rx="38" fill="white"/></svg>`),blend:'dest-in'}]);
  }
  const normalized=await input.png().toBuffer();
  const {data,info} = await sharp(normalized).resize({width:box.w,height:box.h,fit:'inside'}).png().toBuffer({resolveWithObject:true});
  return {input:data,left:box.x+Math.round((box.w-info.width)/2),top:box.y+Math.round((box.h-info.height)/2)};
}
for (const slide of slides) {
  const layers=[];
  if (slide.layout==='palette') {
    layers.push(await fit(slide.source,{x:780,y:112,w:545,h:694}));
  } else if (slide.layout==='tools') {
    layers.push(await fit(slide.source,{x:902,y:250,w:410,h:575}));
    layers.push(await fit(slide.secondary,{x:72,y:383,w:775,h:160}));
  } else {
    layers.push(await fit(slide.source,{x:48,y:246,w:1344,h:584}));
  }
  const filename=`SnipSnipSnip-1.2.0-${slide.number}.png`;
  await sharp(chrome(slide)).composite(layers).flatten({background:'#eee1d3'}).toColourspace('srgb').removeAlpha().png({compressionLevel:9}).toFile(path.join(output,filename));
  console.log(filename);
}
const tiles=[];
for(let i=0;i<slides.length;i++) {
  const p=path.join(output,`SnipSnipSnip-1.2.0-${slides[i].number}.png`);
  tiles.push({input:await sharp(p).resize(480,300).toBuffer(),left:(i%3)*480,top:Math.floor(i/3)*300});
}
await fs.mkdir(path.join(root,'review'),{recursive:true});
await sharp({create:{width:1440,height:900,channels:3,background:'#eee1d3'}}).composite(tiles).png().toFile(path.join(root,'review/Contact-Sheet.png'));

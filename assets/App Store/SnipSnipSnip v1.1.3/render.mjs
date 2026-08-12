import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const sharp = require("sharp");
const root = path.dirname(fileURLToPath(import.meta.url));
const slides = JSON.parse(await fs.readFile(path.join(root, "slides.json"), "utf8"));
const outputDirectory = path.join(root, "output");
await fs.mkdir(outputDirectory, { recursive: true });

const campaignVersion = "1.1.3";
const canvas = { width: 1440, height: 900 };
const hero = { x: 72, y: 268, width: 1296, height: 560, radius: 28 };

function escapeXML(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function wrapText(value, maxCharacters) {
  const words = value.split(/\s+/);
  const lines = [];
  let line = "";
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (candidate.length > maxCharacters && line) {
      lines.push(line);
      line = word;
    } else {
      line = candidate;
    }
  }
  if (line) lines.push(line);
  return lines;
}

function textLines(lines, x, y, lineHeight, attributes) {
  return lines
    .map(
      (line, index) =>
        `<text x="${x}" y="${y + index * lineHeight}" ${attributes}>${escapeXML(line)}</text>`,
    )
    .join("");
}

function chromeSVG(slide) {
  const headlineLines = wrapText(slide.headline, 33);
  const subheadLines = wrapText(slide.subhead, 84);
  const headlineStart = headlineLines.length > 1 ? 104 : 126;
  const subheadStart = headlineStart + headlineLines.length * 72 + 20;

  return Buffer.from(`
    <svg width="${canvas.width}" height="${canvas.height}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="background" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#f7eee3"/>
          <stop offset="0.52" stop-color="#eddfd0"/>
          <stop offset="1" stop-color="#e3d2c0"/>
        </linearGradient>
        <radialGradient id="warmGlow" cx="50%" cy="50%" r="50%">
          <stop offset="0" stop-color="#ff9a3d" stop-opacity="0.22"/>
          <stop offset="0.48" stop-color="#ffbd83" stop-opacity="0.09"/>
          <stop offset="1" stop-color="#000000" stop-opacity="0"/>
        </radialGradient>
        <radialGradient id="coolGlow" cx="50%" cy="50%" r="50%">
          <stop offset="0" stop-color="#6ea9d8" stop-opacity="0.18"/>
          <stop offset="0.55" stop-color="#9fc2da" stop-opacity="0.07"/>
          <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="rule" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stop-color="#ef741b"/>
          <stop offset="0.45" stop-color="#ff9b45"/>
          <stop offset="1" stop-color="#ff7a21" stop-opacity="0"/>
        </linearGradient>
        <filter id="shadow" x="-30%" y="-30%" width="160%" height="180%">
          <feDropShadow dx="0" dy="20" stdDeviation="24" flood-color="#2c2118" flood-opacity="0.20"/>
        </filter>
      </defs>

      <rect width="1440" height="900" fill="url(#background)"/>
      <ellipse cx="1180" cy="320" rx="540" ry="440" fill="url(#warmGlow)"/>
      <ellipse cx="155" cy="720" rx="470" ry="390" fill="url(#coolGlow)"/>
      <rect x="72" y="51" width="12" height="12" rx="6" fill="#ef741b"/>
      <text x="96" y="69"
        font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        font-size="18" font-weight="750" letter-spacing="2.1" fill="#5e5851">
        ${escapeXML(slide.eyebrow)}
      </text>

      ${textLines(
        headlineLines,
        72,
        headlineStart,
        72,
        `font-family="'SF Pro Rounded', -apple-system, BlinkMacSystemFont, sans-serif" font-size="66" font-weight="800" letter-spacing="-2.5" fill="#181817"`,
      )}
      ${textLines(
        subheadLines,
        74,
        subheadStart,
        34,
        `font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif" font-size="27" font-weight="450" fill="#56524d"`,
      )}

      <rect x="72" y="250" width="520" height="3" rx="1.5" fill="url(#rule)"/>
      <rect x="${hero.x}" y="${hero.y}" width="${hero.width}" height="${hero.height}"
        rx="${hero.radius}" fill="#fffdf9" filter="url(#shadow)"/>
      <rect x="${hero.x}" y="${hero.y}" width="${hero.width}" height="${hero.height}"
        rx="${hero.radius}" fill="#ffffff" fill-opacity="0.58" stroke="#2f2922" stroke-opacity="0.10" stroke-width="1"/>

      <text x="72" y="868"
        font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        font-size="17" font-weight="700" letter-spacing="1.7" fill="#68625c">
        SNIPSNIPSNIP
      </text>
      <text x="1368" y="868" text-anchor="end"
        font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        font-size="18" font-weight="800" fill="#e76612">
        ${escapeXML(slide.number)}
      </text>
    </svg>
  `);
}

function heroMaskSVG() {
  return Buffer.from(`
    <svg width="${hero.width}" height="${hero.height}" xmlns="http://www.w3.org/2000/svg">
      <rect width="${hero.width}" height="${hero.height}" rx="${hero.radius}" fill="#fff"/>
    </svg>
  `);
}

async function sourceBuffer(slide) {
  const sourcePath = path.join(root, slide.source);
  try {
    await fs.access(sourcePath);
    const foreground = await sharp(sourcePath)
      .resize({
        width: hero.width - 70,
        height: hero.height - 40,
        fit: slide.fit ?? "contain",
        position: slide.focus ?? "centre",
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      })
      .png()
      .toBuffer();
    return await sharp({
      create: {
        width: hero.width,
        height: hero.height,
        channels: 4,
        background: { r: 255, g: 253, b: 249, alpha: 0 },
      },
    })
      .composite([
        {
          input: await sharp(foreground)
            .extend({
              top: 14,
              bottom: 22,
              left: 22,
              right: 22,
              background: { r: 0, g: 0, b: 0, alpha: 0 },
            })
            .png()
            .toBuffer(),
          gravity: "centre",
        },
        { input: heroMaskSVG(), blend: "dest-in" },
      ])
      .png()
      .toBuffer();
  } catch {
    const label = escapeXML(`CAPTURE NEEDED • ${slide.source}`);
    return await sharp({
      create: {
        width: hero.width,
        height: hero.height,
        channels: 4,
        background: { r: 22, g: 24, b: 29, alpha: 1 },
      },
    })
      .composite([
        {
          input: Buffer.from(`
            <svg width="${hero.width}" height="${hero.height}" xmlns="http://www.w3.org/2000/svg">
              <rect x="1" y="1" width="${hero.width - 2}" height="${hero.height - 2}" rx="${hero.radius}" fill="none" stroke="#ff8a2a" stroke-opacity="0.38" stroke-width="2" stroke-dasharray="10 10"/>
              <text x="${hero.width / 2}" y="${hero.height / 2}" text-anchor="middle"
                font-family="-apple-system, BlinkMacSystemFont, sans-serif"
                font-size="22" font-weight="700" letter-spacing="1.2" fill="#8f939b">${label}</text>
            </svg>
          `),
        },
        { input: heroMaskSVG(), blend: "dest-in" },
      ])
      .png()
      .toBuffer();
  }
}

for (const slide of slides) {
  const image = await sourceBuffer(slide);
  const fileName = `SnipSnipSnip v${campaignVersion}.${slide.number}.png`;
  await sharp(chromeSVG(slide))
    .composite([{ input: image, left: hero.x, top: hero.y }])
    .flatten({ background: "#eddfd0" })
    .removeAlpha()
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toFile(path.join(outputDirectory, fileName));
}

const thumbWidth = 480;
const thumbHeight = 300;
const gap = 18;
const columns = 2;
const rows = Math.ceil(slides.length / columns);
const contact = sharp({
  create: {
    width: columns * thumbWidth + (columns + 1) * gap,
    height: rows * thumbHeight + (rows + 1) * gap,
    channels: 3,
    background: "#ded8d0",
  },
});
const contactComposites = [];
for (const [index, slide] of slides.entries()) {
  const fileName = `SnipSnipSnip v${campaignVersion}.${slide.number}.png`;
  contactComposites.push({
    input: await sharp(path.join(outputDirectory, fileName))
      .resize(thumbWidth, thumbHeight)
      .png()
      .toBuffer(),
    left: gap + (index % columns) * (thumbWidth + gap),
    top: gap + Math.floor(index / columns) * (thumbHeight + gap),
  });
}
await contact
  .composite(contactComposites)
  .removeAlpha()
  .png({ compressionLevel: 9 })
  .toFile(path.join(outputDirectory, "Contact Sheet.png"));

process.stdout.write(`Rendered ${slides.length} slides to ${outputDirectory}\n`);

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
const hero = { x: 72, y: 268, width: 1296, height: 560 };

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

      <text x="72" y="868"
        font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        font-size="17" font-weight="700" letter-spacing="1.7" fill="#68625c">
        SNIPSNIPSNIP
      </text>
    </svg>
  `);
}

async function sourceBuffer(slide) {
  const sourcePath = path.join(root, slide.source);
  try {
    await fs.access(sourcePath);
    const metadata = await sharp(sourcePath).metadata();
    const edgeInset = slide.edgeInset ?? 3;
    const foreground = await sharp(sourcePath)
      .extract({
        left: edgeInset,
        top: edgeInset,
        width: metadata.width - edgeInset * 2,
        height: metadata.height - edgeInset * 2,
      })
      .resize({
        width: hero.width,
        height: hero.height,
        fit: slide.fit ?? "contain",
        position: slide.focus ?? "centre",
        background: { r: 255, g: 255, b: 255, alpha: 1 },
      })
      // XCTest window screenshots preserve transparency in the rounded
      // corners. Dropping alpha directly exposes their black hidden RGB
      // values, so composite those pixels over the window's white surface.
      .flatten({ background: "#ffffff" })
      .png()
      .toBuffer();
    // AppKit's window screenshots include an opaque dark desktop wedge just
    // outside the rounded top-left window corner. Fill only that tiny exterior
    // shape; the traffic lights begin farther in and remain untouched.
    const topLeftRepairSize = 24;
    const topLeftRepair = Buffer.from(`
      <svg width="${topLeftRepairSize}" height="${topLeftRepairSize}" xmlns="http://www.w3.org/2000/svg">
        <path d="M0 0 H${topLeftRepairSize} A${topLeftRepairSize} ${topLeftRepairSize} 0 0 0 0 ${topLeftRepairSize} Z" fill="#ffffff"/>
      </svg>
    `);
    if (slide.repairTopRight === false) {
      return sharp(foreground)
        .composite([{ input: topLeftRepair, left: 0, top: 0 }])
        .png()
        .toBuffer();
    }

    // Window captures include a gray desktop sliver inside the rounded
    // top-right corner. Extend clean pixels from immediately inside the window
    // through that corner so the image meets the artwork without a folded-edge
    // artifact. The traffic-light corner remains untouched.
    const cornerSize = 48;
    const cornerFill = await sharp(foreground)
      .extract({
        left: hero.width - cornerSize - 12,
        top: 0,
        width: 1,
        height: cornerSize,
      })
      .resize({ width: cornerSize, height: cornerSize, fit: "fill" })
      .png()
      .toBuffer();
    return sharp(foreground)
      .composite([
        { input: topLeftRepair, left: 0, top: 0 },
        { input: cornerFill, left: hero.width - cornerSize, top: 0 },
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
              <rect x="1" y="1" width="${hero.width - 2}" height="${hero.height - 2}" fill="none" stroke="#ff8a2a" stroke-opacity="0.38" stroke-width="2" stroke-dasharray="10 10"/>
              <text x="${hero.width / 2}" y="${hero.height / 2}" text-anchor="middle"
                font-family="-apple-system, BlinkMacSystemFont, sans-serif"
                font-size="22" font-weight="700" letter-spacing="1.2" fill="#8f939b">${label}</text>
            </svg>
          `),
        },
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

import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const sharp = require("sharp");
const root = path.dirname(fileURLToPath(import.meta.url));
const captureDirectory = path.join(root, "capture-1.1.3");

const basePath = path.join(captureDirectory, "07-capture-home.png");
const rulerPath = path.join(captureDirectory, "09-screen-ruler.png");
const toolsPath = path.join(captureDirectory, "10-screen-ruler-inspector.png");
const outputPath = path.join(captureDirectory, "10-screen-tools-composite.png");

// Isolate the actual tool surfaces before placing them over the privacy-safe
// Capture screen. This avoids bringing along rectangular pieces of the desktop
// or the app content that happened to sit behind each floating tool.
const ruler = await sharp(rulerPath)
  .extract({ left: 860, top: 840, width: 1300, height: 190 })
  .composite([
    {
      input: Buffer.from(`
        <svg width="1300" height="190" xmlns="http://www.w3.org/2000/svg">
          <rect x="30" y="37" width="1234" height="127" rx="18" fill="#fff"/>
          <circle cx="1255" cy="44" r="24" fill="#fff"/>
        </svg>
      `),
      blend: "dest-in",
    },
  ])
  .png()
  .toBuffer();

const inspector = await sharp(toolsPath)
  .extract({ left: 2136, top: 69, width: 841, height: 1126 })
  .composite([
    {
      input: Buffer.from(`
        <svg width="841" height="1126" xmlns="http://www.w3.org/2000/svg">
          <rect width="841" height="1126" rx="42" fill="#fff"/>
        </svg>
      `),
      blend: "dest-in",
    },
  ])
  .png()
  .toBuffer();

await sharp(basePath)
  .composite([
    { input: ruler, left: 430, top: 610 },
    { input: inspector, left: 1717, top: 55 },
  ])
  // Preserve a clean white app surface at the transparent macOS window
  // corners instead of exposing the hidden black RGB pixels.
  .flatten({ background: "#ffffff" })
  .png({ compressionLevel: 9, adaptiveFiltering: true })
  .toFile(outputPath);

process.stdout.write(`Prepared ${outputPath}\n`);

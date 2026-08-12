import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const sharp = require("sharp");
const root = path.dirname(fileURLToPath(import.meta.url));
const captureDirectory = path.join(root, "capture-1.1.3");

const basePath = path.join(captureDirectory, "07-capture-home.png");
const toolsPath = path.join(captureDirectory, "10-screen-ruler-inspector.png");
const outputPath = path.join(captureDirectory, "10-screen-tools-composite.png");

const ruler = await sharp(toolsPath)
  .extract({ left: 760, top: 730, width: 1230, height: 150 })
  .png()
  .toBuffer();

const inspector = await sharp(toolsPath)
  .extract({ left: 1870, top: 62, width: 850, height: 1125 })
  .png()
  .toBuffer();

await sharp(basePath)
  .composite([
    { input: ruler, left: 430, top: 610 },
    { input: inspector, left: 1660, top: 55 },
  ])
  .png({ compressionLevel: 9, adaptiveFiltering: true })
  .toFile(outputPath);

process.stdout.write(`Prepared ${outputPath}\n`);

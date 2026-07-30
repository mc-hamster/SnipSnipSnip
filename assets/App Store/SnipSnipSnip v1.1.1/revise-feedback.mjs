import fs from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const sharp = require("sharp");
const root = path.dirname(fileURLToPath(import.meta.url));
const prepared = path.join(root, "prepared");
const previousCampaign = path.join(root, "..", "SnipSnipSnip v1.0.23");

async function contain(input, width, height, background = "#0d0f12") {
  return sharp(input)
    .resize({
      width,
      height,
      fit: "contain",
      background,
    })
    .removeAlpha()
    .png()
    .toBuffer();
}

const createOverview = path.join(prepared, "01-overview.png");
const createHeader = await sharp(createOverview)
  .extract({ left: 0, top: 0, width: 1130, height: 220 })
  .removeAlpha()
  .png()
  .toBuffer();
const comparison = await contain(path.join(prepared, "05-compare.png"), 540, 370);
const steps = await contain(path.join(prepared, "06-steps.png"), 540, 370);

await sharp({
  create: {
    width: 1130,
    height: 620,
    channels: 3,
    background: "#0d0f12",
  },
})
  .composite([
    { input: createHeader, left: 0, top: 0 },
    { input: comparison, left: 15, top: 235 },
    { input: steps, left: 575, top: 235 },
  ])
  .removeAlpha()
  .png({ compressionLevel: 9 })
  .toFile(path.join(prepared, "02-create.png"));

const htmlReportCapture = path.join(root, "capture-temp", "05-html-report.jpg");
try {
  await fs.access(htmlReportCapture);
  const appComparison = await contain(
    path.join(prepared, "05-compare.png"),
    525,
    520,
  );
  const htmlCaptureMetadata = await sharp(htmlReportCapture).metadata();
  const htmlReport = await sharp(htmlReportCapture)
    .extract({
      left: 0,
      top: 100,
      width: htmlCaptureMetadata.width,
      height: htmlCaptureMetadata.height - 100,
    })
    .resize({
      width: 540,
      height: 520,
      fit: "contain",
      background: "#0d0f12",
    })
    .sharpen({ sigma: 0.5 })
    .removeAlpha()
    .png()
    .toBuffer();
  const htmlLabels = Buffer.from(`
    <svg width="1130" height="620" xmlns="http://www.w3.org/2000/svg">
      <rect x="15" y="14" width="525" height="42" rx="12" fill="#191c21"/>
      <circle cx="37" cy="35" r="5" fill="#ff8f2c"/>
      <text x="51" y="41"
        font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        font-size="17" font-weight="750" letter-spacing="1.4" fill="#e4e6ea">
        REVIEW IN SNIPSNIPSNIP
      </text>
      <rect x="575" y="14" width="540" height="42" rx="12" fill="#191c21"/>
      <circle cx="597" cy="35" r="5" fill="#ff8f2c"/>
      <text x="611" y="41"
        font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        font-size="17" font-weight="750" letter-spacing="1.4" fill="#e4e6ea">
        INTERACTIVE HTML • ONE OFFLINE FILE
      </text>
      <rect x="557" y="72" width="2" height="520" rx="1" fill="#ffffff" fill-opacity="0.09"/>
    </svg>
  `);

  await sharp({
    create: {
      width: 1130,
      height: 620,
      channels: 3,
      background: "#0d0f12",
    },
  })
    .composite([
      { input: htmlLabels, left: 0, top: 0 },
      { input: appComparison, left: 15, top: 72 },
      { input: htmlReport, left: 575, top: 72 },
    ])
    .removeAlpha()
    .png({ compressionLevel: 9 })
    .toFile(path.join(prepared, "05-html-export.png"));
} catch (error) {
  // Keep the existing HTML-export composition when no fresh browser capture
  // is present.
  if (error?.code !== "ENOENT") {
    process.stderr.write(`Could not prepare slide 05: ${error.stack ?? error}\n`);
  }
}

const nativeLibrary = path.join(root, "capture-temp", "07-library-native.jpg");
try {
  await fs.access(nativeLibrary);
  await sharp(nativeLibrary)
    .extract({ left: 0, top: 350, width: 1130, height: 295 })
    .sharpen({ sigma: 0.6 })
    .removeAlpha()
    .png({ compressionLevel: 9 })
    .toFile(path.join(prepared, "07-library.png"));
} catch {
  // Keep the existing privacy-cropped native Library asset when no fresh
  // Computer Use capture is present.
}

const clipboardSource = path.join(
  previousCampaign,
  "SnipSnipSnip v1.0.23.007.png",
);
const clipboardHeader = await sharp(clipboardSource)
  .extract({ left: 260, top: 214, width: 876, height: 114 })
  .resize({ width: 1100, height: 135, fit: "fill" })
  .sharpen({ sigma: 0.5 })
  .removeAlpha()
  .png()
  .toBuffer();
const clipboardList = await sharp(clipboardSource)
  .extract({ left: 260, top: 328, width: 438, height: 488 })
  .resize({ width: 535, height: 455, fit: "fill" })
  .sharpen({ sigma: 0.5 })
  .removeAlpha()
  .png()
  .toBuffer();
const clipboardPreview = await sharp(clipboardSource)
  .extract({ left: 698, top: 328, width: 438, height: 488 })
  .resize({ width: 535, height: 455, fit: "fill" })
  .sharpen({ sigma: 0.5 })
  .removeAlpha()
  .png()
  .toBuffer();

await sharp({
  create: {
    width: 1130,
    height: 620,
    channels: 3,
    background: "#0d0f12",
  },
})
  .composite([
    { input: clipboardHeader, left: 15, top: 15 },
    { input: clipboardList, left: 15, top: 150 },
    { input: clipboardPreview, left: 580, top: 150 },
  ])
  .removeAlpha()
  .png({ compressionLevel: 9 })
  .toFile(path.join(prepared, "08-clipboard.png"));

const rulerSource = path.join(
  previousCampaign,
  "SnipSnipSnip v1.0.23.008.png",
);
const inspectorSource = path.join(
  previousCampaign,
  "SnipSnipSnip v1.0.23.009.png",
);
const ruler = await sharp(rulerSource)
  .extract({ left: 287, top: 220, width: 970, height: 575 })
  .resize({ width: 680, height: 560, fit: "cover" })
  .sharpen({ sigma: 0.45 })
  .removeAlpha()
  .png()
  .toBuffer();
const inspector = await sharp(inspectorSource)
  .extract({ left: 500, top: 190, width: 495, height: 710 })
  .resize({
    width: 405,
    height: 590,
    fit: "contain",
    background: "#0d0f12",
  })
  .sharpen({ sigma: 0.45 })
  .removeAlpha()
  .png()
  .toBuffer();

await sharp({
  create: {
    width: 1130,
    height: 620,
    channels: 3,
    background: "#0d0f12",
  },
})
  .composite([
    { input: ruler, left: 20, top: 30 },
    { input: inspector, left: 710, top: 15 },
  ])
  .removeAlpha()
  .png({ compressionLevel: 9 })
  .toFile(path.join(prepared, "10-tools.png"));

await fs.rm(path.join(root, "capture-temp"), { recursive: true, force: true });
process.stdout.write("Prepared feedback revisions for slides 02, 05, 07, 08, and 10.\n");

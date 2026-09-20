#!/usr/bin/env node
/**
 * pixel_diff.cjs — deterministic pixel comparison for shader iteration.
 *
 * Vision models describe; this measures. When tuning a shader you need a
 * number ("the change affected 16.3% of pixels"), not a paragraph.
 *
 * Usage:
 *   node tools/pixel_diff.cjs before.png after.png
 *   node tools/pixel_diff.cjs before.png after.png --threshold 8
 *
 * Exit codes: 0 ok, 1 usage/IO error.
 */

const fs = require('fs');
const path = require('path');

function usage(msg) {
  if (msg) console.error('error: ' + msg);
  console.error('usage: node tools/pixel_diff.cjs <before.png> <after.png> [--threshold N]');
  process.exit(1);
}

function parseArgs(argv) {
  const files = [];
  let threshold = 16;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--threshold') {
      threshold = Number(argv[++i]);
      if (!Number.isFinite(threshold)) usage('--threshold needs a number');
    } else if (argv[i] === '-h' || argv[i] === '--help') {
      usage();
    } else {
      files.push(argv[i]);
    }
  }
  return { files, threshold };
}

function loadSharp() {
  // sharp lives in the DSH web profile (installed alongside dsh-vision-router).
  const candidates = [
    'sharp',
    path.join(process.env.DSH_HOME || '', 'profiles', 'web', 'node_modules', 'sharp'),
    'C:/Users/SDD/.dsh/profiles/web/node_modules/sharp',
  ];
  for (const c of candidates) {
    try { return require(c); } catch { /* next */ }
  }
  console.error('error: cannot find "sharp".');
  console.error('Install it with:  dsh plugin --profile web add sharp');
  process.exit(1);
}

(async () => {
  const { files, threshold } = parseArgs(process.argv.slice(2));
  if (files.length !== 2) usage('need exactly two images');

  const [pa, pb] = files.map(f => path.resolve(f));
  for (const p of [pa, pb]) if (!fs.existsSync(p)) usage('no such file: ' + p);

  const sharp = loadSharp();
  const a = await sharp(pa).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const b = await sharp(pb).ensureAlpha().raw().toBuffer({ resolveWithObject: true });

  const { data: da, info } = a;
  const { data: db } = b;
  const { width, height, channels } = info;

  if (b.info.width !== width || b.info.height !== height) {
    console.error('error: size mismatch ' + width + 'x' + height +
      ' vs ' + b.info.width + 'x' + b.info.height);
    process.exit(1);
  }

  const total = width * height;
  const GRID = 8;
  const cw = Math.ceil(width / GRID);
  const chh = Math.ceil(height / GRID);
  const cells = Array.from({ length: GRID * GRID }, () => 0);

  let diff = 0;
  let sumDelta = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * channels;
      const d = Math.max(
        Math.abs(da[i] - db[i]),
        Math.abs(da[i + 1] - db[i + 1]),
        Math.abs(da[i + 2] - db[i + 2])
      );
      if (d > 0) sumDelta += d;
      if (d > threshold) {
        diff++;
        const cx = Math.floor(x / cw);
        const cy = Math.floor(y / chh);
        cells[cy * GRID + cx]++;
      }
    }
  }

  const pct = (100 * diff / total);
  console.log('resolution   : ' + width + 'x' + height);
  console.log('threshold    : >' + threshold + ' per channel');
  console.log('changed px   : ' + diff + ' / ' + total);
  console.log('DIFF RATIO   : ' + pct.toFixed(2) + '%');
  console.log('mean delta   : ' + (sumDelta / total).toFixed(2) + ' (over all px)');

  const ranked = cells
    .map((count, idx) => ({
      count,
      cx: idx % GRID,
      cy: Math.floor(idx / GRID),
    }))
    .filter(c => c.count > 0)
    .sort((x, y) => y.count - x.count);

  if (ranked.length > 0) {
    console.log('');
    console.log('worst 8x8-grid cells (cell = ' + cw + 'x' + chh + ' px):');
    for (const c of ranked.slice(0, 6)) {
      const x0 = c.cx * cw;
      const y0 = c.cy * chh;
      console.log('  cell(' + c.cx + ',' + c.cy + ')  px[' + x0 + ',' + y0 + ']  ' +
        c.count + ' px  (' + (100 * c.count / total).toFixed(2) + '%)');
    }
  } else {
    console.log('');
    console.log('no cells changed above threshold — frames are effectively identical');
  }
})();

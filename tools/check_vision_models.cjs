#!/usr/bin/env node
/**
 * check_vision_models.cjs — verify which configured models can actually see images.
 *
 * A model being listed under a provider does NOT mean it accepts images. This
 * sends a known-content probe image and reports whether the answer is correct,
 * so you find out before wiring a model into the shader loop.
 *
 * Usage:
 *   node tools/check_vision_models.cjs
 *   node tools/check_vision_models.cjs kimi-k3 minimax-m3
 *   node tools/check_vision_models.cjs --image screenshots/before.png
 *
 * Exit codes: 0 at least one model saw the image, 2 none did.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const PROBE = path.join(os.tmpdir(), 'dsh-vision-probe.png');

const BASE = 'https://ark.cn-beijing.volces.com/api/plan/v3';
const DEFAULT_MODELS = ['kimi-k3', 'doubao-seed-2.1-turbo', 'minimax-m3'];

function loadSharp() {
  const candidates = [
    'sharp',
    path.join(process.env.DSH_HOME || '', 'profiles', 'web', 'node_modules', 'sharp'),
    'C:/Users/SDD/.dsh/profiles/web/node_modules/sharp',
  ];
  for (const c of candidates) {
    try { return require(c); } catch { /* next */ }
  }
  console.error('error: cannot find "sharp". Run: dsh plugin --profile web add sharp');
  process.exit(1);
}

function readKey() {
  const p = path.join(process.env.DSH_HOME || 'C:/Users/SDD/.dsh', '.credentials.yaml');
  const txt = fs.readFileSync(p, 'utf8');
  const m = txt.match(/VISION_API_KEY:\s*(\S+)/) || txt.match(/AGENTPLAN_API_KEY:\s*(\S+)/);
  if (!m) {
    console.error('error: no VISION_API_KEY / AGENTPLAN_API_KEY in ' + p);
    process.exit(1);
  }
  return m[1];
}

/** Known-content probe: dark blue field, orange circle, white "42". */
async function makeProbe() {
  const sharp = loadSharp();
  const svg = Buffer.from(
    '<svg width="240" height="120" xmlns="http://www.w3.org/2000/svg">' +
    '<rect width="240" height="120" fill="#1e3a8a"/>' +
    '<circle cx="60" cy="60" r="35" fill="#f59e0b"/>' +
    '<text x="120" y="74" font-size="46" fill="white" font-family="sans-serif">42</text>' +
    '</svg>'
  );
  fs.mkdirSync(path.dirname(PROBE), { recursive: true });
  await sharp(svg).png().toFile(PROBE);
  return PROBE;
}

function parseArgs(argv) {
  const models = [];
  let image = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--image') image = argv[++i];
    else models.push(argv[i]);
  }
  return { models: models.length ? models : DEFAULT_MODELS, image };
}

async function ask(model, key, imgPath) {
  const b64 = fs.readFileSync(imgPath).toString('base64');
  const question = imgPath === PROBE
    ? 'What number is shown in this image, and what color is the circle? Answer in one short sentence.'
    : 'Describe this image in one specific sentence. What is rendered, and what colors dominate?';

  const t = Date.now();
  try {
    const r = await fetch(BASE + '/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + key },
      body: JSON.stringify({
        model,
        max_tokens: 800,
        messages: [{
          role: 'user',
          content: [
            { type: 'text', text: question },
            { type: 'image_url', image_url: { url: 'data:image/png;base64,' + b64 } },
          ],
        }],
      }),
      signal: AbortSignal.timeout(180000),
    });
    const txt = await r.text();
    return { status: r.status, ms: Date.now() - t, body: txt };
  } catch (e) {
    return { status: 0, ms: Date.now() - t, body: e.name + ': ' + e.message };
  }
}

function extract(body) {
  try {
    const j = JSON.parse(body);
    if (j.error) return { err: JSON.stringify(j.error).slice(0, 200) };
    const c = j.choices?.[0]?.message?.content;
    if (typeof c === 'string') return { text: c };
    if (Array.isArray(c)) return { text: c.map(x => x.text || '').join(' ') };
    return { text: JSON.stringify(j).slice(0, 200) };
  } catch {
    return { text: body.slice(0, 200) };
  }
}

(async () => {
  const { models, image } = parseArgs(process.argv.slice(2));
  const key = readKey();
  const probe = await makeProbe();
  const target = image ? path.resolve(image) : probe;
  const isProbe = target === probe;

  console.log('probe image : ' + target);
  console.log('endpoint    : ' + BASE + '/chat/completions');
  console.log('format      : base64 data URL (what local screenshots need)');
  console.log('');

  let anyOk = false;
  for (const model of models) {
    const res = await ask(model, key, target);
    const { text, err } = extract(res.body);
    const line = '[' + model + ']';

    if (res.status === 200 && text) {
      anyOk = true;
      console.log(line + ' HTTP 200  (' + res.ms + ' ms)');
      console.log('    ' + text.replace(/\s+/g, ' ').trim());
      if (isProbe) {
        const saw42 = /\b42\b/.test(text);
        const sawColor = /orang|橙|黄/i.test(text);
        console.log('    -> number 42: ' + (saw42 ? 'YES' : 'NO') +
                    ' | circle color: ' + (sawColor ? 'YES' : 'NO') +
                    (saw42 && sawColor ? '   ==> VISION OK' : '   ==> LOOKS BLIND'));
      }
    } else if (res.status === 200) {
      console.log(line + ' HTTP 200 but no text (' + res.ms + ' ms)');
      console.log('    ' + (text || '').slice(0, 180));
    } else if (err) {
      console.log(line + ' HTTP ' + res.status + '  ' + err);
    } else {
      console.log(line + ' HTTP ' + res.status + '  ' + String(text).slice(0, 180));
    }
    console.log('');
  }

  if (!image) fs.rmSync(probe, { force: true });
  process.exitCode = anyOk ? 0 : 2;
})();

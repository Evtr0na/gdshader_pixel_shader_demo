#!/usr/bin/env node
/**
 * look_at_frame.cjs — hand a captured Godot frame to a vision model.
 *
 * The DSH agent is text-only, so it cannot see the Godot window. This script
 * is the "eyes" half of the shader iteration loop: it reads one or more PNGs
 * and prints what a vision model sees.
 *
 * Usage:
 *   node tools/look_at_frame.cjs screenshots/frame_0001.png
 *   node tools/look_at_frame.cjs before.png after.png      # compare two
 *   node tools/look_at_frame.cjs shot.png --ask "Is the edge aliased?"
 *   node tools/look_at_frame.cjs shot.png --models kimi-k3,minimax-m3
 *
 * Backends are tried in order:
 *   1. The user's own vision models (fast, no rate limit) — needs VISION_API_KEY
 *   2. OVHcloud's anonymous free tier (no key, but IP-throttled ~1 req/min)
 *
 * Exit codes: 0 ok, 1 usage/IO error, 2 all vision backends failed.
 */

const fs = require('fs');
const path = require('path');

const ARK = 'https://ark.cn-beijing.volces.com/api/plan/v3/chat/completions';
const OVH = 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions';

const OWN_MODELS = ['kimi-k3', 'minimax-m3', 'doubao-seed-2.1-turbo'];
const FREE_MODELS = ['Qwen2.5-VL-72B-Instruct', 'Mistral-Small-3.2-24B-Instruct-2506'];

const DEFAULT_ASK =
  'Describe this Godot game viewport screenshot precisely and concretely:\n' +
  '(1) What is rendered, and does it look pixelated / blocky / blurred?\n' +
  '(2) Any visible HUD or text — transcribe it.\n' +
  '(3) The 3 dominant colors as hex.\n' +
  'Report only what is actually visible. Do not speculate.';

function usage(msg) {
  if (msg) console.error('error: ' + msg);
  console.error('usage: node tools/look_at_frame.cjs <image.png> [image2.png] [--ask "q"] [--models a,b]');
  process.exit(1);
}

function parseArgs(argv) {
  const images = [];
  let ask = DEFAULT_ASK;
  let models = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--ask') {
      ask = argv[++i];
      if (ask === undefined) usage('--ask needs a value');
    } else if (a === '--models') {
      const v = argv[++i];
      if (!v) usage('--models needs a value');
      models = v.split(',').map(s => s.trim()).filter(Boolean);
    } else if (a === '-h' || a === '--help') {
      usage();
    } else {
      images.push(a);
    }
  }
  return { images, ask, models };
}

function loadImage(p) {
  const abs = path.resolve(p);
  if (!fs.existsSync(abs)) usage('no such file: ' + abs);
  const ext = path.extname(abs).toLowerCase();
  const mime = ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg'
    : ext === '.webp' ? 'image/webp'
    : 'image/png';
  return { abs, mime, b64: fs.readFileSync(abs).toString('base64') };
}

/** The user's own key, resolved the same way DSH resolves VISION_API_KEY. */
function ownKey() {
  const p = path.join(process.env.DSH_HOME || 'C:/Users/SDD/.dsh', '.credentials.yaml');
  try {
    const txt = fs.readFileSync(p, 'utf8');
    const m = txt.match(/VISION_API_KEY:\s*(\S+)/) || txt.match(/AGENTPLAN_API_KEY:\s*(\S+)/);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

function buildBackends(requested) {
  const key = ownKey();
  const list = [];

  const ownNames = requested ? requested.filter(m => OWN_MODELS.includes(m)) : OWN_MODELS;
  if (key) {
    for (const m of ownNames) list.push({ label: m, url: ARK, model: m, key });
  }

  const freeNames = requested ? requested.filter(m => !OWN_MODELS.includes(m)) : FREE_MODELS;
  for (const m of freeNames) list.push({ label: 'ovh/' + m, url: OVH, model: m, key: null });

  return list;
}

async function tryBackend(b, images, ask) {
  const content = [{ type: 'text', text: ask }];
  for (const img of images) {
    content.push({
      type: 'image_url',
      image_url: { url: 'data:' + img.mime + ';base64,' + img.b64 },
    });
  }
  const headers = { 'Content-Type': 'application/json' };
  if (b.key) headers.Authorization = 'Bearer ' + b.key;

  const t = Date.now();
  const r = await fetch(b.url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ model: b.model, max_tokens: 1200, messages: [{ role: 'user', content }] }),
    signal: AbortSignal.timeout(180000),
  });
  const txt = await r.text();
  return { ok: r.ok, status: r.status, ms: Date.now() - t, body: txt };
}

(async () => {
  const { images: rawImages, ask, models } = parseArgs(process.argv.slice(2));
  if (rawImages.length === 0) usage('need at least one image');

  const images = rawImages.map(loadImage);
  const backends = buildBackends(models);

  console.log('images:');
  for (const i of images) console.log('  ' + i.abs + '  (' + Math.round(i.b64.length * 0.75 / 1024) + ' KB)');
  console.log('question: ' + ask.split('\n')[0]);
  if (backends.length === 0) {
    console.error('\nerror: no usable backend (no VISION_API_KEY and no free models requested)');
    process.exit(1);
  }
  console.log('');

  let sawRateLimit = false;
  for (const b of backends) {
    try {
      const res = await tryBackend(b, images, ask);
      if (res.ok) {
        let out = res.body;
        try {
          const j = JSON.parse(res.body);
          out = j.choices?.[0]?.message?.content || res.body;
        } catch { /* keep raw */ }
        console.log('model: ' + b.label + '   (' + res.ms + ' ms)');
        console.log('='.repeat(60));
        console.log(String(out).trim());
        // Let the event loop drain instead of process.exit(): an immediate
        // exit with live fetch handles trips a libuv assertion on Windows.
        process.exitCode = 0;
        return;
      }
      if (res.status === 429) {
        sawRateLimit = true;
        console.log('[' + b.label + '] rate limited (429), trying next...');
      } else {
        let detail = res.body.slice(0, 140).replace(/\s+/g, ' ');
        try {
          const j = JSON.parse(res.body);
          if (j.error) detail = JSON.stringify(j.error).slice(0, 140);
        } catch { /* raw */ }
        console.log('[' + b.label + '] HTTP ' + res.status + ': ' + detail);
      }
    } catch (e) {
      console.log('[' + b.label + '] ' + e.name + ': ' + e.message);
    }
  }

  console.error('');
  if (sawRateLimit) {
    console.error('All backends rate-limited. The OVH free tier is IP-throttled (~1 req/min).');
    console.error('Configure your own vision models in DSH Settings -> Vision Router.');
  } else {
    console.error('All vision backends failed. Check network / endpoint reachability.');
  }
  process.exitCode = 2;
})();

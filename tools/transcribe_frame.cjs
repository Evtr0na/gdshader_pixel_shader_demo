#!/usr/bin/env node
/**
 * transcribe_frame.cjs — OCR-style transcription of a screenshot via a vision model.
 *
 * look_at_frame.cjs caps max_tokens at 1200, which truncates any screenshot that
 * contains more than a screenful of code (and reasoning models spend the whole
 * budget on reasoning_content, returning empty content). This helper raises the
 * cap and falls back to reasoning_content when content comes back empty.
 *
 * Usage:
 *   node tools/transcribe_frame.cjs <image.png> [--models kimi-k3,minimax-m3]
 *                                   [--max-tokens 8000] [--ask "custom prompt"]
 *
 * Exit codes: 0 ok, 1 usage/IO error, 2 all backends failed.
 */

const fs = require('fs');
const path = require('path');

const ARK = 'https://ark.cn-beijing.volces.com/api/plan/v3/chat/completions';
const OVH = 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions';

const OWN_MODELS = ['kimi-k3', 'minimax-m3', 'doubao-seed-2.1-turbo'];
const FREE_MODELS = ['Qwen2.5-VL-72B-Instruct', 'Mistral-Small-3.2-24B-Instruct-2506'];

const DEFAULT_ASK =
  'Transcribe every piece of text and code visible in this screenshot, VERBATIM.\n' +
  'Rules:\n' +
  '- Output the code exactly as written: same identifiers, same punctuation, same order.\n' +
  '- Preserve line structure and indentation.\n' +
  '- Use a fenced code block. Do not summarise, do not explain, do not add commentary.\n' +
  '- If a region is genuinely unreadable or covered, write [unclear] on that line.\n' +
  '- Also transcribe any window titles, inspector labels, values, and filenames.';

function usage(msg) {
  if (msg) console.error('error: ' + msg);
  console.error('usage: node tools/transcribe_frame.cjs <image.png> [--models a,b] [--max-tokens N] [--ask "..."]');
  process.exit(1);
}

function parseArgs(argv) {
  let image = null;
  let ask = DEFAULT_ASK;
  let models = null;
  let maxTokens = 8000;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--ask') {
      ask = argv[++i];
      if (ask === undefined) usage('--ask needs a value');
    } else if (a === '--models') {
      const v = argv[++i];
      if (!v) usage('--models needs a value');
      models = v.split(',').map(s => s.trim()).filter(Boolean);
    } else if (a === '--max-tokens') {
      const v = argv[++i];
      if (!v) usage('--max-tokens needs a value');
      maxTokens = parseInt(v, 10);
    } else if (a === '-h' || a === '--help') {
      usage();
    } else if (image === null) {
      image = a;
    } else {
      usage('only one image is supported');
    }
  }
  return { image, ask, models, maxTokens };
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
  if (key) for (const m of ownNames) list.push({ label: m, url: ARK, model: m, key });
  const freeNames = requested ? requested.filter(m => !OWN_MODELS.includes(m)) : FREE_MODELS;
  for (const m of freeNames) list.push({ label: 'ovh/' + m, url: OVH, model: m, key: null });
  return list;
}

async function tryBackend(b, img, ask, maxTokens) {
  const content = [
    { type: 'text', text: ask },
    { type: 'image_url', image_url: { url: 'data:' + img.mime + ';base64,' + img.b64 } },
  ];
  const headers = { 'Content-Type': 'application/json' };
  if (b.key) headers.Authorization = 'Bearer ' + b.key;

  const t = Date.now();
  const r = await fetch(b.url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ model: b.model, max_tokens: maxTokens, messages: [{ role: 'user', content }] }),
    signal: AbortSignal.timeout(300000),
  });
  const txt = await r.text();
  return { ok: r.ok, status: r.status, ms: Date.now() - t, body: txt };
}

(async () => {
  const { image, ask, models, maxTokens } = parseArgs(process.argv.slice(2));
  if (!image) usage('need an image');
  const img = loadImage(image);
  const backends = buildBackends(models);
  if (backends.length === 0) {
    console.error('error: no usable backend (no VISION_API_KEY and no free models requested)');
    process.exit(1);
  }

  let sawRateLimit = false;
  for (const b of backends) {
    try {
      const res = await tryBackend(b, img, ask, maxTokens);
      if (res.ok) {
        let out = '';
        let truncated = false;
        try {
          const j = JSON.parse(res.body);
          const msg = j.choices?.[0]?.message || {};
          out = msg.content || '';
          // Reasoning models can spend the entire budget on reasoning_content and
          // return empty content; that text is still the transcription we want.
          if (!out.trim() && msg.reasoning_content) out = msg.reasoning_content;
          truncated = j.choices?.[0]?.finish_reason === 'length';
        } catch {
          out = res.body;
        }
        console.log('model: ' + b.label + '   (' + res.ms + ' ms)');
        if (truncated) console.log('WARNING: response hit the token limit and may be incomplete');
        console.log('='.repeat(60));
        console.log(String(out).trim());
        process.exitCode = 0;
        return;
      }
      if (res.status === 429) {
        sawRateLimit = true;
        console.log('[' + b.label + '] rate limited (429), trying next...');
      } else {
        let detail = res.body.slice(0, 200).replace(/\s+/g, ' ');
        console.log('[' + b.label + '] HTTP ' + res.status + ': ' + detail);
      }
    } catch (e) {
      console.log('[' + b.label + '] ' + e.name + ': ' + e.message);
    }
  }

  if (sawRateLimit) console.error('\nAll backends rate-limited (~1 req/min on the free tier).');
  else console.error('\nAll vision backends failed.');
  process.exitCode = 2;
})();

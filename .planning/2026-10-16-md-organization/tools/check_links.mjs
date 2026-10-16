
import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.argv[2] || 'D:/FPGA';
const EXCLUDE_DIRS = [
  '.git', '.agent-teams', '.dsh-progress', '.venv', 'venv', 'site-packages', 'node_modules',
  'third_party', 'install', 'lib', 'lib64', 'include', 'bin', 'Tools',
  'oss-cad-suite', 'rknn-toolkit2-v2.3.0', 'rknn23wsl', '资料', 'UniAD',
  'pcie_colorbar_pg2l100h_rk3568_20261014', 'dist', 'build', '__pycache__', '.pytest_cache'
];
const EXCLUDE_PATH_SUBSTR = [
  '/资料/', '/UniAD/', '/third_party/', '/install/', '/lib/', '/lib64/', '/include/', '/bin/', '/Tools/',
  '/.venv/', '/.pytest_cache/', '/_tmp/ocs/', '/tmp/rknn', '/node_modules/'
];

function shouldSkipDir(name, rel) {
  if (EXCLUDE_DIRS.includes(name)) return true;
  for (const s of EXCLUDE_PATH_SUBSTR) if ((rel + '/').includes(s)) return true;
  return false;
}

function walk(dir, rel, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const r = rel ? rel + '/' + e.name : e.name;
    if (e.isDirectory()) {
      if (shouldSkipDir(e.name, r)) continue;
      walk(path.join(dir, e.name), r, out);
    } else if (e.isFile() && /\.md$/i.test(e.name)) {
      if (shouldSkipDir('', r)) continue;
      out.push(r);
    }
  }
}
const files = [];
walk(ROOT, '', files);
files.sort();

const linkRe = /(!?)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const htmlRe = /(?:src|href)\s*=\s*["']([^"']+)["']/g;

const results = [];
for (const rel of files) {
  const abs = path.join(ROOT, rel);
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); } catch { continue; }
  const lines = text.split(/\r?\n/);
  const broken = [];
  let total = 0;
  lines.forEach((line, i) => {
    const targets = [];
    let m;
    linkRe.lastIndex = 0;
    while ((m = linkRe.exec(line))) targets.push({ target: m[2], kind: m[1] === '!' ? 'image' : 'link' });
    htmlRe.lastIndex = 0;
    while ((m = htmlRe.exec(line))) targets.push({ target: m[1], kind: 'html' });
    for (const t of targets) {
      let raw = t.target.trim();
      if (!raw || raw.startsWith('#') || /^[a-z][a-z0-9+.-]*:/i.test(raw)) continue;
      if (raw.startsWith('<') && raw.endsWith('>')) raw = raw.slice(1, -1);
      const noFrag = raw.split('#')[0].split('?')[0];
      if (!noFrag) continue;
      total++;
      let decoded = noFrag;
      try { decoded = decodeURIComponent(noFrag); } catch {}
      const base = decoded.startsWith('/') ? ROOT : path.join(path.dirname(abs), decoded);
      let exists = false;
      try { exists = fs.existsSync(base); } catch {}
      if (!exists) broken.push({ line: i + 1, kind: t.kind, target: raw, abs: base.replace(/\\/g, '/') });
    }
  });
  results.push({ file: rel, total, broken });
}
const summary = { generatedAt: new Date().toISOString(), root: ROOT, mdCount: files.length,
  filesWithBroken: results.filter(r => r.broken.length).length,
  brokenTotal: results.reduce((a, r) => a + r.broken.length, 0) };
console.log(JSON.stringify({ summary, results }, null, 1));

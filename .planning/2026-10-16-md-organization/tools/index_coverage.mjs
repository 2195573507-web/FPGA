
import fs from 'node:fs';
import path from 'node:path';
const ROOT = 'D:/FPGA';
const d = JSON.parse(fs.readFileSync('.planning/2026-10-16-md-organization/tools/linkcheck_before.json','utf8'));
const readme = fs.readFileSync(path.join(ROOT,'docs/README.md'),'utf8');
const linkRe = /\[[^\]]*\]\(([^)\s]+)\)/g;
const covered = new Set();
let m;
while ((m = linkRe.exec(readme))) {
  let raw = m[1].split('#')[0];
  if (!raw || /^[a-z][a-z0-9+.-]*:/i.test(raw)) continue;
  let dec = raw; try { dec = decodeURIComponent(raw); } catch {}
  const abs = path.resolve(path.dirname(path.join(ROOT,'docs/README.md')), dec);
  covered.add(path.relative(ROOT, abs).replace(/\\/g,'/'));
}
const coveredDirs = [...covered].filter(p => { try { return fs.statSync(path.join(ROOT,p)).isDirectory(); } catch { return false; } });
const all = d.results.map(r => r.file);
const uncovered = all.filter(f => {
  if (covered.has(f)) return false;
  for (const cd of coveredDirs) if (f.startsWith(cd + '/')) return false;
  return true;
});
console.log('dir targets:', JSON.stringify(coveredDirs));
console.log('total:', all.length, 'NOT covered by any README link:', uncovered.length);
console.log(uncovered.join('\n'));

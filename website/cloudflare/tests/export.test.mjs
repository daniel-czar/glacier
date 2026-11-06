import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { build, project } from '../scripts/build.mjs';

test('public export is closed over local references and contains no private experiment material', async () => {
  const temporary = await mkdtemp(path.join(tmpdir(), 'glacier-web-'));
  try {
    const report = await build(path.join(temporary, 'public'));
    const names = report.publicFiles.map(file => file.path);
    assert.ok(names.includes('index.html'));
    assert.ok(names.includes('media/recording-20261102/omni-mail-express.mp4'));
    assert.ok(!names.some(name => /(?:^|\/)(?:README|working-memory|backup|before|cyclone|receipts|reference|\.git)|assets\/real|\.md$/.test(name)));
    for (const name of names.filter(name => /\.(html|css)$/.test(name))) {
      const text = await readFile(path.join(temporary, 'public', name), 'utf8');
      const refs = [...text.matchAll(/(?:src|href|poster)="([^"]+)"|url\(["']?([^)'"\s]+)["']?\)/g)].map(m => m[1] || m[2]);
      for (const ref of refs) {
        if (/^(https?:|data:|#)/.test(ref)) continue;
        const file = path.posix.normalize(ref.startsWith('/') ? ref.slice(1) : path.posix.join(path.posix.dirname(name), ref.split(/[?#]/)[0]));
        assert.ok(names.includes(file || 'index.html') || file === '.', `${name} references missing ${ref}`);
      }
    }
    const html = await readFile(path.join(temporary, 'public/index.html'), 'utf8');
    assert.ok(html.includes('https://glacierformac.com/assets/social-card.jpg'));
    assert.ok(html.includes('aria-label="Glacier source on GitHub"'));
    assert.ok(html.includes('href="https://github.com/daniel-czar/glacier"'));
    assert.ok(html.includes('href="https://github.com/daniel-czar/glacier/archive/refs/heads/main.zip">Download source ZIP'));
    assert.ok(html.includes('The ZIP contains source code, not a ready-to-run app.'));
    assert.ok(html.includes('A signed Mac app download is coming soon.'));
    assert.ok(!html.includes('The repository is private for now'));
    assert.ok(!html.includes('open to inspect'));
    assert.ok(!html.includes('../shared/'));
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
    assert.equal(new Set(ids).size, ids.length);
    for (const [, id] of html.matchAll(/href="#([^"]+)"/g)) assert.ok(ids.includes(id), `missing #${id}`);
    for (const ext of ['mp4', 'webm']) {
      const source = await readFile(path.resolve(project, `../shared/recording-20261102/omni-mail-express.${ext}`));
      const output = await readFile(path.join(temporary, `public/media/recording-20261102/omni-mail-express.${ext}`));
      assert.deepEqual(output, source, 'Finished masked media must be unchanged');
    }
  } finally { await rm(temporary, { recursive: true, force: true }); }
});

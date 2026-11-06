import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { project } from './build.mjs';

const origin = new URL(process.argv[2] || 'http://127.0.0.1:8280');
assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(origin.hostname), 'This check only targets local preview');
const request = (pathname, options) => fetch(new URL(pathname, origin), options);
const checks = [];
const homepage = await request('/');
assert.equal(homepage.status, 200);
assert.match(await homepage.text(), /Your Mac toolkit/);
assert.match(homepage.headers.get('content-security-policy') || '', /script-src 'self'/);
checks.push('Root page, metadata and response headers');

const manifest = JSON.parse(await readFile(path.join(project, 'build-manifest.json'), 'utf8'));
for (const { path: file } of manifest.publicFiles) {
  if (file.startsWith('_')) continue; // Cloudflare configuration files are not public assets.
  const response = await request(`/${file}`, { method: 'HEAD' });
  assert.equal(response.status, 200, file);
}
checks.push('Every exported public asset resolves');
for (const excluded of ['/backup.zip', '/README.md', '/worker.mjs', '/package.json', '/receipts/private.json', '/before/', '/cyclone/', '/.git/config', '/assets/real/omni-real.mp4']) {
  assert.equal((await request(excluded)).status, 404, excluded);
}
checks.push('Excluded experiment, configuration and old media paths return 404');

for (const extension of ['mp4', 'webm']) {
  const file = `media/recording-20261102/omni-mail-express.${extension}`;
  const expected = await readFile(path.join(project, 'dist', file));
  const full = await request(`/${file}`);
  assert.equal(full.status, 200);
  assert.equal(full.headers.get('accept-ranges'), 'bytes');
  assert.deepEqual(Buffer.from(await full.arrayBuffer()), expected);
  for (const [header, start, end] of [
    ['bytes=0-1', 0, 1], ['bytes=128-255', 128, 255],
    ['bytes=-32', expected.length - 32, expected.length - 1],
    [`bytes=${expected.length - 16}-`, expected.length - 16, expected.length - 1],
  ]) {
    const response = await request(`/${file}`, { headers: { Range: header } });
    assert.equal(response.status, 206, header);
    assert.equal(response.headers.get('content-range'), `bytes ${start}-${end}/${expected.length}`);
    assert.equal(response.headers.get('content-length'), String(end - start + 1));
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), expected.subarray(start, end + 1));
  }
  const invalid = await request(`/${file}`, { headers: { Range: `bytes=${expected.length}-` } });
  assert.equal(invalid.status, 416);
  assert.equal(invalid.headers.get('content-range'), `bytes */${expected.length}`);
  const head = await request(`/${file}`, { method: 'HEAD', headers: { Range: 'bytes=0-1' } });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-length'), String(expected.length));
  const mismatched = await request(`/${file}`, { headers: { Range: 'bytes=0-1', 'If-Range': '"old"' } });
  assert.equal(mismatched.status, 200);
  await mismatched.arrayBuffer();
  checks.push(`${extension}: full bytes, Safari probe, middle/suffix/open ranges, 416, HEAD and If-Range`);
}
await mkdir(path.join(project, 'artifacts'), { recursive: true });
await writeFile(path.join(project, 'artifacts/http-checks.json'), JSON.stringify({ origin: origin.origin, passed: true, checks }, null, 2) + '\n');
console.log(JSON.stringify({ passed: true, checks }, null, 2));

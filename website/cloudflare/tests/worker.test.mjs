import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../worker.mjs';

const bytes = Uint8Array.from({ length: 256 }, (_, i) => i);
const video = 'https://glacierformac.com/media/recording-20261102/omni-mail-express.mp4';
function fixture(status = 200) {
  const requests = [];
  return { requests, ASSETS: { async fetch(request) {
    requests.push(request);
    return new Response(status === 304 || request.method === 'HEAD' ? null : bytes, { status,
      headers: { 'content-type': 'video/mp4', 'content-length': '256', etag: '"example"',
        'last-modified': 'Wed, 04 Nov 2026 09:00:00 GMT' } });
  } } };
}
for (const [range, start, end] of [
  ['bytes=0-1', 0, 1], ['bytes=128-', 128, 255], ['bytes=-4', 252, 255],
  ['bytes=250-999999999999999999999', 250, 255], ['bytes=-999', 0, 255],
]) test(`serves exact bytes for ${range}`, async () => {
  const env = fixture(); const result = await worker.fetch(new Request(video, { headers: { Range: range } }), env);
  assert.equal(result.status, 206);
  assert.equal(result.headers.get('content-range'), `bytes ${start}-${end}/256`);
  assert.equal(result.headers.get('content-length'), String(end - start + 1));
  assert.equal(result.headers.get('accept-ranges'), 'bytes');
  assert.deepEqual(new Uint8Array(await result.arrayBuffer()), bytes.slice(start, end + 1));
  assert.equal(env.requests[0].headers.get('range'), null);
});
for (const range of ['bytes=256-', 'bytes=10-5', 'bytes=-0', 'bytes=999999999999999999999-']) {
  test(`rejects unsatisfiable range ${range}`, async () => {
    const result = await worker.fetch(new Request(video, { headers: { Range: range } }), fixture());
    assert.equal(result.status, 416); assert.equal(result.headers.get('content-range'), 'bytes */256');
    assert.equal((await result.arrayBuffer()).byteLength, 0);
  });
}
for (const range of ['items=0-1', 'bytes=0-1,4-5', 'bytes=-', 'nonsense']) {
  test(`ignores unsupported range ${range}`, async () => {
    const result = await worker.fetch(new Request(video, { headers: { Range: range } }), fixture());
    assert.equal(result.status, 200); assert.deepEqual(new Uint8Array(await result.arrayBuffer()), bytes);
  });
}
test('HEAD ignores Range and returns full metadata without a body', async () => {
  const result = await worker.fetch(new Request(video, { method: 'HEAD', headers: { Range: 'bytes=0-1' } }), fixture());
  assert.equal(result.status, 200); assert.equal(result.headers.get('content-length'), '256');
  assert.equal(await result.text(), '');
});
test('If-Range only permits a matching strong validator or sufficiently new date', async () => {
  for (const [validator, status] of [['"example"', 206], ['"old"', 200], ['W/"example"', 200],
    ['Wed, 04 Nov 2026 10:00:00 GMT', 206], ['Tue, 03 Nov 2026 10:00:00 GMT', 200]]) {
    const result = await worker.fetch(new Request(video, { headers: { Range: 'bytes=0-1', 'If-Range': validator } }), fixture());
    assert.equal(result.status, status, validator);
  }
});
test('preserves conditional 304 responses and non-video assets', async () => {
  const conditional = await worker.fetch(new Request(video, { headers: { Range: 'bytes=0-1', 'If-None-Match': '"example"' } }), fixture(304));
  assert.equal(conditional.status, 304);
  const env = fixture(); const request = new Request('https://glacierformac.com/missing');
  await worker.fetch(request, env); assert.equal(env.requests[0], request);
});
test('video mutations are rejected', async () => {
  const env = fixture(); const result = await worker.fetch(new Request(video, { method: 'POST' }), env);
  assert.equal(result.status, 405); assert.equal(env.requests.length, 0);
});

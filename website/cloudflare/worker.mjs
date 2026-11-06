// Only the two small walkthrough files need a Worker. All other assets use
// Cloudflare's static asset service. Never fetch an external origin here.
const videos = new Set([
  '/media/recording-20261102/omni-mail-express.mp4',
  '/media/recording-20261102/omni-mail-express.webm',
]);

function byteRange(value, length) {
  // Unsupported units/multiple ranges are ignored, returning the full file.
  if (!value || value.length > 128) return null;
  const match = /^bytes=(\d*)-(\d*)$/i.exec(value.trim());
  if (!match || (!match[1] && !match[2])) return null;
  const size = BigInt(length);
  if (!length) return false;
  if (!match[1]) {
    const suffix = BigInt(match[2]);
    if (suffix === 0n) return false;
    return [Number(suffix >= size ? 0n : size - suffix), length - 1];
  }
  const start = BigInt(match[1]);
  const end = match[2] ? BigInt(match[2]) : size - 1n;
  if (start >= size || end < start) return false;
  return [Number(start), Number(end < size ? end : size - 1n)];
}

function ifRangeMatches(value, headers) {
  if (!value) return true;
  if (value.startsWith('"')) return value === headers.get('etag');
  if (value.startsWith('W/')) return false;
  const date = Date.parse(value);
  const modified = Date.parse(headers.get('last-modified') || '');
  return Number.isFinite(date) && Number.isFinite(modified) && modified <= date;
}

export default {
  async fetch(request, env) {
    if (!videos.has(new URL(request.url).pathname)) return env.ASSETS.fetch(request);
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    const requestHeaders = new Headers(request.headers);
    requestHeaders.delete('range');
    requestHeaders.delete('if-range');
    requestHeaders.set('accept-encoding', 'identity');
    // The asset service may omit Content-Length on HEAD. Fetch GET metadata and
    // discard its body below so media clients receive useful HEAD information.
    const full = await env.ASSETS.fetch(new Request(request, { method: 'GET', headers: requestHeaders }));
    // Preserve conditional responses (304), errors and redirects from the asset service.
    if (full.status !== 200) return full;
    const headers = new Headers(full.headers);
    headers.set('accept-ranges', 'bytes');
    if (request.method === 'HEAD') {
      if (!headers.has('content-length')) headers.set('content-length', String((await full.arrayBuffer()).byteLength));
      else await full.body?.cancel();
      return new Response(null, { status: 200, headers });
    }
    const rangeHeader = request.headers.get('range');
    if (!rangeHeader || !ifRangeMatches(request.headers.get('if-range'), headers)) {
      return new Response(full.body, { status: 200, headers });
    }
    // These allowlisted files are ~2 MB and ~1 MB, bounded by the export check.
    const bytes = await full.arrayBuffer();
    const range = byteRange(rangeHeader, bytes.byteLength);
    headers.delete('content-encoding');
    if (range === null) {
      headers.set('content-length', String(bytes.byteLength));
      return new Response(bytes, { status: 200, headers });
    }
    if (range === false) {
      headers.set('content-range', `bytes */${bytes.byteLength}`);
      headers.set('content-length', '0');
      return new Response(null, { status: 416, headers });
    }
    const [start, end] = range;
    headers.set('content-range', `bytes ${start}-${end}/${bytes.byteLength}`);
    headers.set('content-length', String(end - start + 1));
    return new Response(bytes.slice(start, end + 1), { status: 206, headers });
  },
};

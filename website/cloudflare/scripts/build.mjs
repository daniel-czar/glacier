import { readFile, writeFile, mkdir, copyFile, rm, lstat, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const project = fileURLToPath(new URL('../', import.meta.url));
const repo = path.resolve(project, '..');
const siteFiles = [
  'index.html', 'site.css', 'theme.css', 'landing.css', 'utility.css',
  'visual-showcase.css', 'site.js', 'visual-showcase.js',
  'assets/theme-icon.webp', 'assets/theme-wallpaper.webp', 'assets/alpine-wallpaper.webp',
  'assets/favicon.png', 'assets/apple-touch-icon.png', 'assets/social-card.jpg',
  'assets/onboarding-welcome.png',
  ...['cerebras.svg', 'openai.svg', 'anthropic.svg', 'openrouter.svg', 'ollama.svg',
    'github.svg', 'lobe-icons-LICENSE.txt', 'octicons-LICENSE.txt', 'simple-icons-LICENSE.txt']
    .map(name => `assets/providers/${name}`),
];
const mediaFiles = ['omni-mail-express.mp4', 'omni-mail-express.webm',
  'omni-mail-express-poster.jpg', 'recording.css'];

export async function listFiles(directory, prefix = '') {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = path.posix.join(prefix, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Symlink in public output: ${relative}`);
    if (entry.isDirectory()) files.push(...await listFiles(path.join(directory, entry.name), relative));
    else if (entry.isFile()) files.push(relative);
    else throw new Error(`Unsupported public entry: ${relative}`);
  }
  return files.sort();
}

export async function build(destination = path.join(project, 'dist')) {
  // This fixed deployment allowlist is intentionally independent of directory contents.
  // Receipts, backups, old recordings and alternate studies cannot enter the export.
  const mappings = siteFiles.map(file => [path.join(repo, 'glacier', file), file]);
  mappings.push(...mediaFiles.map(file => [path.join(repo, 'shared/recording-20261102', file),
    `media/recording-20261102/${file}`]));
  for (const [source] of mappings) {
    const info = await lstat(source);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error(`Expected regular source file: ${source}`);
    if (info.size > 25 * 1024 * 1024) throw new Error(`Cloudflare asset exceeds 25 MiB: ${source}`);
  }
  await rm(destination, { recursive: true, force: true });
  await mkdir(destination, { recursive: true });
  for (const [source, relative] of mappings) {
    const target = path.join(destination, relative);
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(source, target);
  }
  const index = path.join(destination, 'index.html');
  const html = (await readFile(index, 'utf8')).replaceAll('../shared/recording-20261102/', 'media/recording-20261102/');
  await writeFile(index, html);
  await writeFile(path.join(destination, 'robots.txt'), 'User-agent: *\nAllow: /\nSitemap: https://glacierformac.com/sitemap.xml\n');
  await writeFile(path.join(destination, 'sitemap.xml'), '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://glacierformac.com/</loc></url></urlset>\n');
  await writeFile(path.join(destination, '_headers'), `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  X-Frame-Options: DENY
  Permissions-Policy: camera=(), microphone=(), geolocation=()
  Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'
`);
  await writeFile(path.join(destination, '404.html'), `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>Page not found · Glacier</title><link rel="stylesheet" href="/site.css"><link rel="stylesheet" href="/theme.css"></head><body><main class="sec"><div class="wrap"><p class="eyebrow">Glacier</p><h1 class="h2">This page isn’t here.</h1><p class="lede-sm">Return to Glacier to explore the toolkit.</p><a class="btn btn-primary" href="/">Back to Glacier</a></div></main></body></html>\n`);
  const files = await listFiles(destination);
  const manifest = [];
  for (const file of files) {
    const data = await readFile(path.join(destination, file));
    manifest.push({ path: file, bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') });
  }
  return { domain: 'glacierformac.com', publicFiles: manifest,
    pending: ['Cloudflare publication and live verification', 'Public source repository and signed download links'] };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await build();
  await writeFile(path.join(project, 'build-manifest.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(`Exported ${result.publicFiles.length} public files for ${result.domain}`);
}

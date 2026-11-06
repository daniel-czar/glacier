import { copyFile, cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import path from 'node:path';
import { build, project, listFiles } from './build.mjs';

const result = await build();
await writeFile(path.join(project, 'build-manifest.json'), JSON.stringify(result, null, 2) + '\n');
const artifacts = path.join(project, 'artifacts');
const bundle = path.join(artifacts, 'glacier-cloudflare');
await rm(bundle, { recursive: true, force: true });
await mkdir(bundle, { recursive: true });
await cp(path.join(project, 'dist'), path.join(bundle, 'dist'), { recursive: true });
for (const file of ['worker.mjs', 'wrangler.jsonc', 'package-lock.json', 'README.md', 'build-manifest.json']) {
  await copyFile(path.join(project, file), path.join(bundle, file));
}
// The deployable bundle needs no private source tree or export tooling.
const pkg = JSON.parse(await readFile(path.join(project, 'package.json'), 'utf8'));
pkg.scripts = { preview: pkg.scripts.preview, 'check:cloudflare': pkg.scripts['check:cloudflare'], deploy: pkg.scripts.deploy };
await writeFile(path.join(bundle, 'package.json'), JSON.stringify(pkg, null, 2) + '\n');
const archive = path.join(artifacts, 'glacier-cloudflare-LOCAL-READY.zip');
await rm(archive, { force: true });
// Web assets need neither resource forks nor Finder metadata. Plain extraction
// must yield the same allowlist, never AppleDouble ._ sidecar files.
execFileSync('ditto', ['-c', '-k', '--norsrc', '--noextattr', '--noacl', '--keepParent', bundle, archive]);
const entries = execFileSync('unzip', ['-Z1', archive], { encoding: 'utf8' })
  .trim().split('\n').filter(name => !name.endsWith('/'))
  .map(name => { assert.ok(name.startsWith('glacier-cloudflare/')); return name.slice('glacier-cloudflare/'.length); }).sort();
assert.deepEqual(entries, await listFiles(bundle), 'Archive must contain exactly the prepared deployment files');
const digest = createHash('sha256').update(await readFile(archive)).digest('hex');
await writeFile(`${archive}.sha256`, `${digest}  ${path.basename(archive)}\n`);
console.log(JSON.stringify({ archive, sha256: digest, files: result.publicFiles.length, published: false }, null, 2));

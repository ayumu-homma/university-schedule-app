import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'smol-toml';

const workspaceRoot = fileURLToPath(new URL('../../../', import.meta.url));
const configPath = path.join(workspaceRoot, 'supabase/config.toml');

try {
  const source = await readFile(configPath, 'utf8');
  const config = parse(source);
  assert.equal(config.auth?.site_url, 'http://127.0.0.1:3000');

  const deletionRedirects = (config.auth?.additional_redirect_urls ?? [])
    .filter((url) => url.includes('/account-deletion'))
    .sort();
  assert.deepEqual(deletionRedirects, [
    'http://127.0.0.1:3000/account-deletion',
    'http://localhost:3000/account-deletion',
  ]);
  console.log('Supabase TOML parsed; local account-deletion Auth redirects match.');
} catch {
  console.error('supabase/config.toml is invalid or its local account-deletion Auth redirects do not match.');
  process.exitCode = 1;
}

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { parse } from 'smol-toml';

const workspaceRoot = fileURLToPath(new URL('../../../', import.meta.url));

test('the actual Supabase TOML parses and contains exact local deletion redirects', async () => {
  const source = await readFile(path.join(workspaceRoot, 'supabase/config.toml'), 'utf8');
  const config = parse(source);

  assert.equal(config.auth.site_url, 'http://127.0.0.1:3000');
  assert.deepEqual(
    config.auth.additional_redirect_urls
      .filter((url) => url.includes('/account-deletion'))
      .sort(),
    [
      'http://127.0.0.1:3000/account-deletion',
      'http://localhost:3000/account-deletion',
    ],
  );
});

test('the parser rejects a malformed test-only TOML document', () => {
  assert.throws(() => parse('[auth\nsite_url = "http://127.0.0.1:3000"'));
});

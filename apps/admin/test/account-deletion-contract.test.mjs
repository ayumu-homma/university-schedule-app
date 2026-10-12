import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';

const workspaceRoot = fileURLToPath(new URL('../../../', import.meta.url));
const readProjectFile = (relativePath) =>
  readFile(path.join(workspaceRoot, relativePath), 'utf8');

test('web, mobile, and local Auth configuration share the account-deletion route', async () => {
  const [webRoute, webResolver, mobileConfig, supabaseConfig] = await Promise.all([
    readProjectFile('apps/admin/app/account-deletion/page.tsx'),
    readProjectFile('apps/admin/lib/account-deletion-url.mjs'),
    readProjectFile('apps/mobile/lib/core/config/app_config.dart'),
    readProjectFile('supabase/config.toml'),
  ]);

  assert.match(webRoute, /resolveAccountDeletionRedirectTo/);
  assert.match(webResolver, /const ACCOUNT_DELETION_PATH = '\/account-deletion';/);
  assert.match(mobileConfig, /APP_ACCOUNT_DELETION_URL/);
  assert.match(mobileConfig, /resolve\('\/account-deletion'\)/);
  assert.match(mobileConfig, /deletionUri\.path != '\/account-deletion'/);

  const localRedirects = [...supabaseConfig.matchAll(
    /^\s*"(http:\/\/(?:127\.0\.0\.1|localhost):3000\/account-deletion)"\s*,?\s*$/gm,
  )].map((match) => match[1]).sort();

  assert.deepEqual(localRedirects, [
    'http://127.0.0.1:3000/account-deletion',
    'http://localhost:3000/account-deletion',
  ]);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { validateAccountDeletionBuildConfig } from '../lib/account-deletion-build-config.mjs';

const publicUrl = (host) => `https://${host}/account-deletion`;

test('public build gate requires explicit valid HTTPS deletion URLs', () => {
  for (const environment of ['staging', 'production']) {
    assert.deepEqual(
      validateAccountDeletionBuildConfig({ appEnv: environment }),
      { valid: false, skipped: false },
    );
    assert.deepEqual(
      validateAccountDeletionBuildConfig({
        appEnv: environment,
        configuredUrl: 'http://release-check.university.edu/account-deletion',
      }),
      { valid: false, skipped: false },
    );
    assert.deepEqual(
      validateAccountDeletionBuildConfig({
        appEnv: environment,
        configuredUrl: publicUrl('release-check.university.edu/account'),
      }),
      { valid: false, skipped: false },
    );
    assert.deepEqual(
      validateAccountDeletionBuildConfig({
        appEnv: environment,
        configuredUrl: publicUrl('example.com'),
      }),
      { valid: false, skipped: false },
    );
  }
});

test('public build gate accepts environment-specific test-only HTTPS URLs', () => {
  for (const environment of ['staging', 'production']) {
    const configuredUrl = publicUrl(`${environment}-release-check.university.edu`);
    assert.deepEqual(
      validateAccountDeletionBuildConfig({ appEnv: environment, configuredUrl }),
      { valid: true, skipped: false, redirectTo: configuredUrl },
    );
  }
});

test('local and generic CI builds do not require public host configuration', () => {
  assert.deepEqual(validateAccountDeletionBuildConfig({ appEnv: 'local' }), {
    valid: true,
    skipped: true,
  });
  assert.deepEqual(validateAccountDeletionBuildConfig({}), {
    valid: true,
    skipped: true,
  });
});

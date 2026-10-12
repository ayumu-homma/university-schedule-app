import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveAccountDeletionRedirectTo } from '../lib/account-deletion-url.mjs';

const local = (overrides = {}) => resolveAccountDeletionRedirectTo({
  appEnv: 'local',
  nodeEnv: 'development',
  currentOrigin: 'http://127.0.0.1:3000',
  ...overrides,
});

test('local account deletion OTP returns to the canonical route on loopback HTTP', () => {
  assert.equal(local(), 'http://127.0.0.1:3000/account-deletion');
  assert.equal(
    local({ currentOrigin: 'http://localhost:3000' }),
    'http://localhost:3000/account-deletion',
  );
});

test('local HTTP exception rejects non-loopback origins and production builds', () => {
  assert.equal(local({ currentOrigin: 'http://schedule.example.edu' }), null);
  assert.equal(local({ nodeEnv: 'production' }), null);
});

test('staging and production require an explicit public HTTPS route on the active origin', () => {
  const options = {
    appEnv: 'staging',
    nodeEnv: 'production',
    currentOrigin: 'https://staging.schedule.university.edu',
  };
  assert.equal(resolveAccountDeletionRedirectTo(options), null);
  assert.equal(
    resolveAccountDeletionRedirectTo({
      ...options,
      configuredUrl: 'https://staging.schedule.university.edu/account-deletion',
    }),
    'https://staging.schedule.university.edu/account-deletion',
  );
  assert.equal(
    resolveAccountDeletionRedirectTo({
      ...options,
      configuredUrl: 'https://staging.schedule.university.edu/account-deletion',
      currentOrigin: 'https://wrong-host.example.edu',
    }),
    null,
  );
});

test('deployed redirect rejects HTTP, placeholder hosts, and noncanonical paths', () => {
  const options = {
    appEnv: 'production',
    nodeEnv: 'production',
    currentOrigin: 'https://schedule.university.edu',
  };
  for (const configuredUrl of [
    'http://schedule.university.edu/account-deletion',
    'https://schedule.university.edu/account/delete',
    'https://schedule.university.edu/account-deletion?next=https://evil.example',
  ]) {
    assert.equal(
      resolveAccountDeletionRedirectTo({ ...options, configuredUrl }),
      null,
      configuredUrl,
    );
  }
  assert.equal(
    resolveAccountDeletionRedirectTo({
      ...options,
      currentOrigin: 'https://example.com',
      configuredUrl: 'https://example.com/account-deletion',
    }),
    null,
  );
});

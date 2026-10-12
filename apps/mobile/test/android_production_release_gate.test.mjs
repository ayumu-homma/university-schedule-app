import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ReleaseGateError,
  validateProductionAndroidRelease,
} from '../tool/validate_android_production_release.mjs';

const validDefines = () => ({
  APP_ENV: 'production',
  APP_DEMO_MODE: 'false',
  APP_DEEP_LINK_SCHEME: 'unischedule',
  STAGING_SUPABASE_PROJECT_REF: 'abcdefghijklmnopqrst',
  PRODUCTION_SUPABASE_PROJECT_REF: 'uvwxyz0123456789abcd',
  SUPABASE_URL: 'https://uvwxyz0123456789abcd.supabase.co',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test_value',
  APP_WEB_BASE_URL: 'https://schedule.example.edu',
  APP_PRIVACY_POLICY_URL: 'https://policy.example.edu/privacy',
  APP_TERMS_URL: 'https://policy.example.edu/terms',
  APP_ACCOUNT_DELETION_URL: 'https://policy.example.edu/account-deletion',
  APP_SUPPORT_URL: 'https://support.example.edu/help',
  EMAIL_IMPORT_ENABLED: 'false',
  DOCUMENT_IMPORT_ENABLED: 'false',
});

const assertCode = (defines, signingPropertiesPresent, code) => {
  assert.throws(
    () => validateProductionAndroidRelease(defines, { signingPropertiesPresent }),
    (error) => error instanceof ReleaseGateError && error.code === code,
  );
};

test('accepts complete production configuration with signing setup present', () => {
  assert.equal(
    validateProductionAndroidRelease(validDefines(), { signingPropertiesPresent: true }),
    true,
  );
});

test('rejects missing APP_ENV', () => {
  const defines = validDefines();
  delete defines.APP_ENV;
  assertCode(defines, true, 'APP_ENV_REQUIRED');
});

test('rejects a staging flavor contract at the production build entry', () => {
  const defines = { ...validDefines(), APP_ENV: 'staging' };
  assertCode(defines, true, 'APP_ENV_MUST_BE_PRODUCTION');
  assertCode({ ...validDefines(), APP_DEEP_LINK_SCHEME: 'unischedule-staging' }, true, 'PRODUCTION_SCHEME_MISMATCH');
});

test('rejects missing, HTTP, or wrong-path deletion URLs', () => {
  assertCode({ ...validDefines(), APP_ACCOUNT_DELETION_URL: '' }, true, 'APP_ACCOUNT_DELETION_URL_REQUIRED');
  assertCode({ ...validDefines(), APP_ACCOUNT_DELETION_URL: 'http://schedule.example.edu/account-deletion' }, true, 'APP_ACCOUNT_DELETION_URL_INVALID');
  assertCode({ ...validDefines(), APP_ACCOUNT_DELETION_URL: 'https://schedule.example.edu/account/delete' }, true, 'APP_ACCOUNT_DELETION_URL_INVALID');
});

test('rejects absent signing configuration without exposing any supplied value', () => {
  const defines = validDefines();
  defines.SUPABASE_PUBLISHABLE_KEY = 'private-value-must-not-appear-in-errors';
  assertCode(defines, false, 'SIGNING_CONFIG_MISSING');
});

test('rejects Supabase URL/project-ref mismatch', () => {
  assertCode({ ...validDefines(), SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co' }, true, 'SUPABASE_URL_PROJECT_MISMATCH');
});

test('rejects a server-side client key', () => {
  assertCode({ ...validDefines(), SUPABASE_PUBLISHABLE_KEY: 'sb_secret_test_value' }, true, 'PUBLIC_CLIENT_KEY_REQUIRED');
});

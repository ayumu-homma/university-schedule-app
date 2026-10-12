import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export class ReleaseGateError extends Error {
  constructor(code) {
    super(code);
    this.name = 'ReleaseGateError';
    this.code = code;
  }
}

const requiredString = (defines, name) => {
  const value = defines[name];
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new ReleaseGateError(`${name}_REQUIRED`);
  }
  return value.trim();
};

function parsePublicHttpsUrl(value, name, { exactPath } = {}) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new ReleaseGateError(`${name}_INVALID`);
  }
  if (
    url.protocol !== 'https:' ||
    !url.hostname ||
    url.username ||
    url.password ||
    url.port ||
    url.search ||
    url.hash ||
    isReservedHost(url.hostname)
  ) {
    throw new ReleaseGateError(`${name}_INVALID`);
  }
  if (exactPath !== undefined && url.pathname !== exactPath) {
    throw new ReleaseGateError(`${name}_INVALID`);
  }
  return url;
}

function isReservedHost(hostname) {
  const host = hostname.toLowerCase().replace(/\.+$/, '');
  return (
    host === 'localhost' ||
    host === 'example.com' ||
    host === 'example.net' ||
    host === 'example.org' ||
    host.endsWith('.local') ||
    host.endsWith('.localhost') ||
    host.endsWith('.example') ||
    host.endsWith('.invalid') ||
    host.endsWith('.test') ||
    host.endsWith('.example.com') ||
    host.endsWith('.example.net') ||
    host.endsWith('.example.org') ||
    /^\d+(?:\.\d+){3}$/.test(host) ||
    host.includes(':')
  );
}

function keyRole(value) {
  const segments = value.split('.');
  if (segments.length !== 3) return null;
  try {
    const payload = JSON.parse(Buffer.from(segments[1], 'base64url').toString('utf8'));
    return typeof payload.role === 'string' ? payload.role : null;
  } catch {
    return null;
  }
}

export function validateProductionAndroidRelease(
  defines,
  { signingPropertiesPresent },
) {
  if (!defines || typeof defines !== 'object' || Array.isArray(defines)) {
    throw new ReleaseGateError('CONFIG_INVALID');
  }
  if (!signingPropertiesPresent) {
    throw new ReleaseGateError('SIGNING_CONFIG_MISSING');
  }

  if (requiredString(defines, 'APP_ENV') !== 'production') {
    throw new ReleaseGateError('APP_ENV_MUST_BE_PRODUCTION');
  }
  if (defines.APP_DEMO_MODE !== 'false') {
    throw new ReleaseGateError('DEMO_MODE_MUST_BE_DISABLED');
  }
  if (requiredString(defines, 'APP_DEEP_LINK_SCHEME') !== 'unischedule') {
    throw new ReleaseGateError('PRODUCTION_SCHEME_MISMATCH');
  }

  const productionRef = requiredString(defines, 'PRODUCTION_SUPABASE_PROJECT_REF');
  if (!/^[a-z0-9]{20}$/.test(productionRef)) {
    throw new ReleaseGateError('PRODUCTION_PROJECT_REF_INVALID');
  }
  const stagingRef = defines.STAGING_SUPABASE_PROJECT_REF?.trim() ?? '';
  if (stagingRef && (!/^[a-z0-9]{20}$/.test(stagingRef) || stagingRef === productionRef)) {
    throw new ReleaseGateError('PROJECT_REFS_INVALID_OR_NOT_DISTINCT');
  }

  let supabaseUrl;
  try {
    supabaseUrl = new URL(requiredString(defines, 'SUPABASE_URL'));
  } catch {
    throw new ReleaseGateError('SUPABASE_URL_INVALID');
  }
  if (
    supabaseUrl.protocol !== 'https:' ||
    supabaseUrl.hostname !== `${productionRef}.supabase.co` ||
    (supabaseUrl.pathname !== '/' && supabaseUrl.pathname !== '') ||
    supabaseUrl.port ||
    supabaseUrl.username ||
    supabaseUrl.password ||
    supabaseUrl.search ||
    supabaseUrl.hash
  ) {
    throw new ReleaseGateError('SUPABASE_URL_PROJECT_MISMATCH');
  }

  const publishableKey = defines.SUPABASE_PUBLISHABLE_KEY?.trim() ?? '';
  const legacyAnonKey = defines.SUPABASE_ANON_KEY?.trim() ?? '';
  if (publishableKey && legacyAnonKey && publishableKey !== legacyAnonKey) {
    throw new ReleaseGateError('CLIENT_KEYS_CONFLICT');
  }
  const clientKey = publishableKey || legacyAnonKey;
  if (!clientKey || clientKey.toLowerCase().startsWith('sb_secret_')) {
    throw new ReleaseGateError('PUBLIC_CLIENT_KEY_REQUIRED');
  }
  const publishable = /^sb_publishable_[A-Za-z0-9_-]+$/.test(clientKey) && clientKey.length <= 4096;
  if (!publishable && keyRole(clientKey) !== 'anon') {
    throw new ReleaseGateError('PUBLIC_CLIENT_KEY_INVALID');
  }

  parsePublicHttpsUrl(requiredString(defines, 'APP_WEB_BASE_URL'), 'APP_WEB_BASE_URL');
  parsePublicHttpsUrl(requiredString(defines, 'APP_PRIVACY_POLICY_URL'), 'APP_PRIVACY_POLICY_URL');
  parsePublicHttpsUrl(requiredString(defines, 'APP_TERMS_URL'), 'APP_TERMS_URL');
  parsePublicHttpsUrl(
    requiredString(defines, 'APP_ACCOUNT_DELETION_URL'),
    'APP_ACCOUNT_DELETION_URL',
    { exactPath: '/account-deletion' },
  );
  parsePublicHttpsUrl(requiredString(defines, 'APP_SUPPORT_URL'), 'APP_SUPPORT_URL');

  for (const flag of ['EMAIL_IMPORT_ENABLED', 'DOCUMENT_IMPORT_ENABLED']) {
    if (defines[flag] !== undefined && defines[flag] !== 'true' && defines[flag] !== 'false') {
      throw new ReleaseGateError(`${flag}_INVALID`);
    }
  }

  return true;
}

function option(args, name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const configPath = option(process.argv.slice(2), '--config-file');
  if (!configPath) {
    console.error('Release preflight rejected: CONFIG_FILE_REQUIRED. Values were not displayed.');
    process.exitCode = 64;
  } else {
    try {
      const defines = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      validateProductionAndroidRelease(defines, {
        signingPropertiesPresent: fs.existsSync(path.resolve('android/key.properties')),
      });
      console.log('Android production release preflight passed. Values were not displayed.');
    } catch (error) {
      const code = error instanceof ReleaseGateError ? error.code : 'CONFIG_INVALID_OR_INCOMPLETE';
      console.error(`Release preflight rejected: ${code}. Values were not displayed.`);
      process.exitCode = 2;
    }
  }
}

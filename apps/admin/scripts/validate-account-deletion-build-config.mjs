import { validateAccountDeletionBuildConfig } from '../lib/account-deletion-build-config.mjs';

const result = validateAccountDeletionBuildConfig({
  appEnv: process.env.NEXT_PUBLIC_APP_ENV,
  configuredUrl: process.env.NEXT_PUBLIC_ACCOUNT_DELETION_URL,
});

if (!result.valid) {
  console.error(
    'Staging/production builds require NEXT_PUBLIC_ACCOUNT_DELETION_URL to be an approved HTTPS /account-deletion URL.',
  );
  process.exitCode = 1;
} else if (result.skipped) {
  console.log('Account-deletion public URL build check skipped for local/unspecified environment.');
} else {
  console.log('Account-deletion public URL build check passed.');
}

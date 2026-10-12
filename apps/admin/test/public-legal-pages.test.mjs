import assert from 'node:assert/strict';
import test from 'node:test';

import { resolvePublicLegalPage } from '../lib/public-legal-pages.mjs';

const pages = [
  ['privacy', 'APPROVED_PRIVACY_POLICY_TEXT'],
  ['terms', 'APPROVED_TERMS_OF_SERVICE_TEXT'],
  ['support', 'APPROVED_SUPPORT_CONTACT'],
];

test('all public policy/contact routes stay unpublished by default', () => {
  for (const [page] of pages) {
    assert.equal(resolvePublicLegalPage(page, {}), null, `${page} must be closed`);
  }
});

test('each page requires explicit publication and its own approved content', () => {
  for (const [page, contentKey] of pages) {
    assert.equal(
      resolvePublicLegalPage(page, {
        PUBLIC_LEGAL_PAGES_ENABLED: 'true',
        [contentKey]: 'Synthetic approved content for tests',
      }),
      'Synthetic approved content for tests',
      `${page} should expose only its supplied content`,
    );

    assert.equal(
      resolvePublicLegalPage(page, {
        PUBLIC_LEGAL_PAGES_ENABLED: 'false',
        [contentKey]: 'Synthetic approved content for tests',
      }),
      null,
      `${page} must remain closed when the shared publish switch is off`,
    );
    assert.equal(
      resolvePublicLegalPage(page, {
        PUBLIC_LEGAL_PAGES_ENABLED: 'true',
        [contentKey]: ' \n ',
      }),
      null,
      `${page} must remain closed when its content is blank`,
    );
  }
});

test('unknown routes and non-exact publish values fail closed', () => {
  assert.equal(
    resolvePublicLegalPage('unknown', {
      PUBLIC_LEGAL_PAGES_ENABLED: 'true',
      APPROVED_PRIVACY_POLICY_TEXT: 'Synthetic content',
    }),
    null,
  );
  assert.equal(
    resolvePublicLegalPage('privacy', {
      PUBLIC_LEGAL_PAGES_ENABLED: 'TRUE',
      APPROVED_PRIVACY_POLICY_TEXT: 'Synthetic content',
    }),
    null,
  );
});

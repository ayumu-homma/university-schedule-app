const pageContentEnvironmentKeys = Object.freeze({
  privacy: 'APPROVED_PRIVACY_POLICY_TEXT',
  terms: 'APPROVED_TERMS_OF_SERVICE_TEXT',
  support: 'APPROVED_SUPPORT_CONTACT',
});

/**
 * Returns approved server-side content for a public page, or null while it is
 * unpublished. The shared opt-in and page-specific content must both exist.
 */
export function resolvePublicLegalPage(page, environment = process.env) {
  const contentKey = pageContentEnvironmentKeys[page];
  if (!contentKey || environment.PUBLIC_LEGAL_PAGES_ENABLED !== 'true') {
    return null;
  }

  const content = environment[contentKey];
  return typeof content === 'string' && content.trim().length > 0
    ? content.trim()
    : null;
}

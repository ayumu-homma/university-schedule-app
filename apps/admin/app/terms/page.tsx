import { notFound } from 'next/navigation';
import { resolvePublicLegalPage } from '../../lib/public-legal-pages.mjs';

export const dynamic = 'force-dynamic';

export default function TermsPage() {
  const content = resolvePublicLegalPage('terms');
  if (content === null) notFound();

  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '32px 24px' }}>
      <h1>利用規約</h1>
      <p style={{ whiteSpace: 'pre-wrap' }}>{content}</p>
    </main>
  );
}

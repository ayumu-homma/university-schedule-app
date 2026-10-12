import { notFound } from 'next/navigation';
import { resolvePublicLegalPage } from '../../lib/public-legal-pages.mjs';

export const dynamic = 'force-dynamic';

export default function PrivacyPage() {
  const content = resolvePublicLegalPage('privacy');
  if (content === null) notFound();

  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '32px 24px' }}>
      <h1>プライバシーポリシー</h1>
      <p style={{ whiteSpace: 'pre-wrap' }}>{content}</p>
    </main>
  );
}

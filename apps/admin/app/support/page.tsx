import { notFound } from 'next/navigation';
import { resolvePublicLegalPage } from '../../lib/public-legal-pages.mjs';

export const dynamic = 'force-dynamic';

export default function SupportPage() {
  const contact = resolvePublicLegalPage('support');
  if (contact === null) notFound();

  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '32px 24px' }}>
      <h1>管理者へのお問い合わせ</h1>
      <p style={{ whiteSpace: 'pre-wrap' }}>{contact}</p>
    </main>
  );
}

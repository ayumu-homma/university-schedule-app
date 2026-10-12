import './globals.css';

export const metadata = {
  title: 'University Schedule Admin',
  description: 'MVP admin foundation for university requests, reports, and course templates',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ja">
      <body>{children}</body>
    </html>
  );
}

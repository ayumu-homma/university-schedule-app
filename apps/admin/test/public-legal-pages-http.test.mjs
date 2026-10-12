import assert from 'node:assert/strict';
import test from 'node:test';

const baseUrl = process.env.P47_PUBLIC_ROUTES_BASE_URL ?? 'http://127.0.0.1:3219';
const routes = [
  {
    path: '/privacy',
    expected: 'P47 synthetic privacy',
    escaped: 'P47 synthetic privacy &lt;script&gt;window.__p47=1&lt;/script&gt; body',
    raw: '<script>window.__p47=1</script>',
    other: ['P47 synthetic terms', 'P47 synthetic support'],
  },
  {
    path: '/terms',
    expected: 'P47 synthetic terms body',
    other: ['P47 synthetic privacy', 'P47 synthetic support'],
  },
  {
    path: '/support',
    expected: 'P47 synthetic support contact',
    other: ['P47 synthetic privacy', 'P47 synthetic terms'],
  },
];

test('configured routes serve only their own synthetic content over HTTP', async () => {
  for (const route of routes) {
    const response = await fetch(new URL(route.path, baseUrl));
    const html = await response.text();

    assert.equal(response.status, 200, `${route.path} should be configured in the local test server`);
    assert.ok(html.includes(route.expected), `${route.path} should render its expected test content`);
    for (const otherContent of route.other) {
      assert.ok(!html.includes(otherContent), `${route.path} must not include another page's content`);
    }
    if (route.escaped) {
      assert.ok(html.includes(route.escaped), 'HTML-sensitive test text should be escaped');
      assert.ok(!html.includes(route.raw), 'raw script markup must not appear');
    }
  }
});

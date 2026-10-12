import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { readdir } from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const adminRoot = fileURLToPath(new URL('../', import.meta.url));
const httpTest = 'public-legal-pages-http.test.mjs';
const unitTests = (await readdir(path.join(adminRoot, 'test')))
  .filter((name) => name.endsWith('.test.mjs') && name !== httpTest)
  .sort().map((name) => path.join('test', name));

async function runTests(files, environment) {
  const child = spawn(process.execPath, ['--test', ...files], {
    cwd: adminRoot, env: environment, stdio: 'inherit', windowsHide: true,
  });
  const [code] = await once(child, 'exit');
  if (code !== 0) throw new Error(`Admin tests failed (${code}).`);
}

await runTests(unitTests, process.env);
const probe = net.createServer();
probe.listen(0, '127.0.0.1');
await once(probe, 'listening');
const port = probe.address().port;
await new Promise((resolve) => probe.close(resolve));
const environment = {
  ...process.env,
  NEXT_TELEMETRY_DISABLED: '1',
  PUBLIC_LEGAL_PAGES_ENABLED: 'true',
  APPROVED_PRIVACY_POLICY_TEXT: 'P47 synthetic privacy <script>window.__p47=1</script> body',
  APPROVED_TERMS_OF_SERVICE_TEXT: 'P47 synthetic terms body',
  APPROVED_SUPPORT_CONTACT: 'P47 synthetic support contact',
  P47_PUBLIC_ROUTES_BASE_URL: `http://127.0.0.1:${port}`,
};
const server = spawn(process.execPath, [
  'node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', String(port),
], { cwd: adminRoot, env: environment, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
server.stdout.pipe(process.stdout);
server.stderr.pipe(process.stderr);
try {
  let ready = false;
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline && server.exitCode === null) {
    try {
      const response = await fetch(`${environment.P47_PUBLIC_ROUTES_BASE_URL}/privacy`, {
        signal: AbortSignal.timeout(1000),
      });
      await response.arrayBuffer();
      if (response.status === 200) { ready = true; break; }
    } catch { /* Only this disposable loopback server is probed. */ }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  if (!ready) throw new Error('Disposable synthetic admin server did not become ready.');
  await runTests([path.join('test', httpTest)], environment);
} finally {
  if (server.exitCode === null) {
    server.kill();
    await once(server, 'exit');
  }
}

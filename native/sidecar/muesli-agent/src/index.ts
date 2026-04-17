// libsql's native .node addon ships on disk next to the compiled binary
// because Bun's --compile cannot embed .node files. The libsql package itself
// is patched (see patches/libsql@*.patch) to look for the addon at
// `<execDir>/native_modules/@libsql/<target>/index.node` before falling back
// to its normal resolution. build.sh copies the addon into place.

import { generateToken } from './auth.ts';
import { createApp } from './server.ts';
import { SIDECAR_VERSION } from './types.ts';

const token = generateToken();
const app = createApp({ token });

const server = Bun.serve({
  port: 0,
  hostname: '127.0.0.1',
  // Coach turns can take 30+ seconds for a long generation. Bun's default
  // 10s idle timeout was killing in-flight SSE streams, which caused AI SDK
  // to retry and duplicate assistant messages in memory. 240s gives plenty
  // of headroom for any plausible single-turn coach response.
  idleTimeout: 240,
  fetch: app.fetch,
});

process.stdout.write(
  JSON.stringify({ port: server.port, token, version: SIDECAR_VERSION }) + '\n',
);

const shutdown = () => {
  server.stop(true);
  process.exit(0);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// Force the bundler to embed the libsql native addon so it ships inside the
// compiled binary. libsql uses dynamic require() to pick a platform-specific
// target at runtime, which Bun's static analyzer can't resolve on its own.
// Importing it here keeps it in the bundle graph. We currently only embed the
// arm64 addon; x64 support would need a separate universal build.
// @ts-expect-error — purely for bundler side-effect, not used
import * as _libsqlDarwinArm64 from '@libsql/darwin-arm64';
void _libsqlDarwinArm64;

import { generateToken } from './auth.ts';
import { createApp } from './server.ts';
import { SIDECAR_VERSION } from './types.ts';

const token = generateToken();
const app = createApp({ token });

const server = Bun.serve({
  port: 0,
  hostname: '127.0.0.1',
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

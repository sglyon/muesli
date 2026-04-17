import { Hono } from 'hono';
import { bearerAuth } from './auth.ts';
import { coachRoute } from './routes/coach.ts';
import { threadRoute } from './routes/thread.ts';
import { SIDECAR_VERSION } from './types.ts';

export interface AppOptions {
  token: string;
}

export function createApp(options: AppOptions): Hono {
  const app = new Hono();

  app.get('/health', (c) => c.json({ status: 'ok', version: SIDECAR_VERSION }));

  app.use('*', bearerAuth(options.token));
  app.route('/coach', coachRoute);
  app.route('/', threadRoute);

  return app;
}

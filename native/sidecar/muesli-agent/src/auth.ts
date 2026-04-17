import type { MiddlewareHandler } from 'hono';

export function bearerAuth(expected: string): MiddlewareHandler {
  const expectedHeader = `Bearer ${expected}`;
  return async (c, next) => {
    const got = c.req.header('Authorization');
    if (got !== expectedHeader) {
      return c.json({ error: 'unauthorized' }, 401);
    }
    await next();
  };
}

export function generateToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

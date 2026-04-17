import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// Set MUESLI_DATA_DIR BEFORE importing any modules that read it at load time.
const DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'muesli-coach-test-'));
process.env.MUESLI_DATA_DIR = DATA_DIR;

const { createApp } = await import('../src/server.ts');
const { setTestModelOverride } = await import('../src/agent/factory.ts');
const { deleteResource } = await import('../src/memory/store.ts');
const { MockLanguageModelV3, simulateReadableStream } = await import('ai/test');

const TOKEN = 'test-token-xyz';
const app = createApp({ token: TOKEN });

function authHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return { Authorization: `Bearer ${TOKEN}`, ...extra };
}

async function readSSE(resp: Response): Promise<Array<{ event: string; data: string }>> {
  expect(resp.body).not.toBeNull();
  const reader = resp.body!.pipeThrough(new TextDecoderStream()).getReader();
  const events: Array<{ event: string; data: string }> = [];
  let buf = '';
  let curEvent: string | undefined;
  let curData: string[] = [];
  const flush = () => {
    if (curEvent === undefined) return;
    events.push({ event: curEvent, data: curData.join('\n') });
    curEvent = undefined;
    curData = [];
  };
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += value;
    let nl = buf.indexOf('\n');
    while (nl !== -1) {
      const line = buf.slice(0, nl).replace(/\r$/, '');
      buf = buf.slice(nl + 1);
      nl = buf.indexOf('\n');
      if (line === '') {
        flush();
      } else if (line.startsWith('event:')) {
        curEvent = line.slice(6).trim();
      } else if (line.startsWith('data:')) {
        curData.push(line.slice(5).trimStart());
      }
    }
  }
  flush();
  return events;
}

function mockStreamingModel(chunks: string[]) {
  const joined = chunks.join('');
  return new MockLanguageModelV3({
    doGenerate: async () => ({
      content: [{ type: 'text' as const, text: 'Mock Thread Title' }],
      finishReason: { unified: 'stop', raw: 'stop' },
      usage: {
        inputTokens: { total: 1, noCache: 1, cacheRead: undefined, cacheWrite: undefined },
        outputTokens: { total: 1, text: 1, reasoning: undefined },
      },
      warnings: [],
    }),
    doStream: async () => ({
      stream: simulateReadableStream({
        chunks: [
          { type: 'stream-start', warnings: [] },
          { type: 'text-start', id: 't1' },
          ...chunks.map((c) => ({ type: 'text-delta' as const, id: 't1', delta: c })),
          { type: 'text-end', id: 't1' },
          {
            type: 'finish',
            finishReason: { unified: 'stop', raw: 'stop' },
            usage: {
              inputTokens: { total: 10, noCache: 10, cacheRead: undefined, cacheWrite: undefined },
              outputTokens: { total: joined.length, text: joined.length, reasoning: undefined },
            },
          },
        ],
      }),
    }),
  });
}

function turnRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    threadId: 'test-thread',
    resourceId: 'test-resource',
    provider: 'anthropic',
    model: 'mock-model',
    credentials: { apiKey: 'mock-key' },
    systemPrompt: 'You are a helpful coach.',
    turn: { kind: 'userMessage', content: '<user_message>hi</user_message>' },
    ...overrides,
  };
}

beforeAll(() => {
  fs.mkdirSync(DATA_DIR, { recursive: true });
});

afterAll(() => {
  setTestModelOverride(undefined);
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
});

beforeEach(async () => {
  setTestModelOverride(undefined);
  await deleteResource('test-resource').catch(() => {});
});

describe('auth', () => {
  test('rejects requests without bearer token', async () => {
    const resp = await app.fetch(new Request('http://test/coach/turn', { method: 'POST', body: '{}' }));
    expect(resp.status).toBe(401);
  });

  test('accepts health without auth', async () => {
    const resp = await app.fetch(new Request('http://test/health'));
    expect(resp.status).toBe(200);
    expect(await resp.json()).toEqual({ status: 'ok', version: expect.any(String) });
  });
});

describe('/coach/turn', () => {
  test('streams deltas and terminates with done', async () => {
    setTestModelOverride(mockStreamingModel(['Hello, ', 'coach ', 'here.']));

    const resp = await app.fetch(
      new Request('http://test/coach/turn', {
        method: 'POST',
        headers: authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(turnRequest()),
      }),
    );
    expect(resp.status).toBe(200);
    const events = await readSSE(resp);
    const deltas = events.filter((e) => e.event === 'delta').map((e) => e.data);
    expect(deltas.join('')).toBe('Hello, coach here.');
    expect(events.at(-1)?.event).toBe('done');
  });

  test('rejects bad body with 400', async () => {
    const resp = await app.fetch(
      new Request('http://test/coach/turn', {
        method: 'POST',
        headers: authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({ provider: 'anthropic' }),
      }),
    );
    expect(resp.status).toBe(400);
  });
});

describe('thread persistence', () => {
  test('two turns with same threadId persist and reload', async () => {
    setTestModelOverride(mockStreamingModel(['First turn reply.']));

    const first = await app.fetch(
      new Request('http://test/coach/turn', {
        method: 'POST',
        headers: authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(turnRequest({ threadId: 'persist-thread' })),
      }),
    );
    await readSSE(first);

    setTestModelOverride(mockStreamingModel(['Second turn reply.']));

    const second = await app.fetch(
      new Request('http://test/coach/turn', {
        method: 'POST',
        headers: authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(
          turnRequest({
            threadId: 'persist-thread',
            turn: { kind: 'userMessage', content: '<user_message>follow up</user_message>' },
          }),
        ),
      }),
    );
    await readSSE(second);

    const history = await app.fetch(
      new Request('http://test/thread/persist-thread', { headers: authHeaders() }),
    );
    expect(history.status).toBe(200);
    const body = (await history.json()) as { messages: Array<{ role: string; content: string }> };
    // Expect 4 messages: 2 user + 2 assistant.
    expect(body.messages.length).toBeGreaterThanOrEqual(4);
    const userContents = body.messages.filter((m) => m.role === 'user').map((m) => m.content);
    expect(userContents.some((c) => c.includes('hi'))).toBe(true);
    expect(userContents.some((c) => c.includes('follow up'))).toBe(true);
  });

  test('DELETE /thread/:id wipes the thread', async () => {
    setTestModelOverride(mockStreamingModel(['one shot']));

    const first = await app.fetch(
      new Request('http://test/coach/turn', {
        method: 'POST',
        headers: authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(turnRequest({ threadId: 'deletable' })),
      }),
    );
    await readSSE(first);

    const del = await app.fetch(
      new Request('http://test/thread/deletable', { method: 'DELETE', headers: authHeaders() }),
    );
    expect(del.status).toBe(200);

    const history = await app.fetch(
      new Request('http://test/thread/deletable', { headers: authHeaders() }),
    );
    const body = (await history.json()) as { messages: unknown[] };
    expect(body.messages).toEqual([]);
  });

  test('DELETE /resource/:id wipes all threads for a resource', async () => {
    setTestModelOverride(mockStreamingModel(['ok']));

    for (const id of ['t-alpha', 't-beta']) {
      const r = await app.fetch(
        new Request('http://test/coach/turn', {
          method: 'POST',
          headers: authHeaders({ 'Content-Type': 'application/json' }),
          body: JSON.stringify(turnRequest({ threadId: id, resourceId: 'wipe-me' })),
        }),
      );
      await readSSE(r);
    }

    const del = await app.fetch(
      new Request('http://test/resource/wipe-me', { method: 'DELETE', headers: authHeaders() }),
    );
    expect(del.status).toBe(200);

    for (const id of ['t-alpha', 't-beta']) {
      const history = await app.fetch(
        new Request(`http://test/thread/${id}`, { headers: authHeaders() }),
      );
      const body = (await history.json()) as { messages: unknown[] };
      expect(body.messages).toEqual([]);
    }
  });
});

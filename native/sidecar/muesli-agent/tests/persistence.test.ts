import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { LibSQLStore } from '@mastra/libsql';
import { Memory } from '@mastra/memory';

// Use a dedicated tmp dir for this suite so it doesn't collide with the
// route-level test suite which uses its own.
const DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'muesli-coach-persist-'));
process.env.MUESLI_DATA_DIR = DATA_DIR;

// Import AFTER MUESLI_DATA_DIR is set — the store reads it at module load.
const { createApp } = await import('../src/server.ts');
const { setTestModelOverride } = await import('../src/agent/factory.ts');
const { deleteResource } = await import('../src/memory/store.ts');
const { MockLanguageModelV3, simulateReadableStream } = await import('ai/test');

const TOKEN = 'persist-test-token';
const app = createApp({ token: TOKEN });

function authHeaders(): Record<string, string> {
  return { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };
}

async function drain(resp: Response): Promise<void> {
  await resp.text();
}

function mockModel(reply: string) {
  return new MockLanguageModelV3({
    doGenerate: async () => ({
      content: [{ type: 'text' as const, text: 'Mock title' }],
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
          { type: 'text-start', id: 't' },
          { type: 'text-delta', id: 't', delta: reply },
          { type: 'text-end', id: 't' },
          {
            type: 'finish',
            finishReason: { unified: 'stop', raw: 'stop' },
            usage: {
              inputTokens: { total: 1, noCache: 1, cacheRead: undefined, cacheWrite: undefined },
              outputTokens: { total: reply.length, text: reply.length, reasoning: undefined },
            },
          },
        ],
      }),
    }),
  });
}

function turn(threadId: string, content: string, resourceId = 'persist-resource'): Record<string, unknown> {
  return {
    threadId,
    resourceId,
    provider: 'anthropic',
    model: 'mock-model',
    credentials: { apiKey: 'mock-key' },
    systemPrompt: 'You are a coach.',
    turn: { kind: 'userMessage', content },
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
  // Wipe everything between tests so each starts from a clean state.
  await deleteResource('persist-resource').catch(() => {});
  await deleteResource('other-resource').catch(() => {});
});

describe('LibSQL on-disk persistence', () => {
  test('messages survive a fresh Memory instance pointing at the same DB', async () => {
    setTestModelOverride(mockModel('hello back'));

    // First turn through the served HTTP path (writes via the cached Memory).
    await drain(
      await app.fetch(
        new Request('http://t/coach/turn', {
          method: 'POST',
          headers: authHeaders(),
          body: JSON.stringify(turn('persist-1', '<user_message>hello</user_message>')),
        }),
      ),
    );

    // Now construct a brand-new Memory pointing at the same on-disk file —
    // this simulates what would happen after the sidecar process restarts.
    const freshStorage = new LibSQLStore({
      id: 'verify-storage',
      url: `file:${path.join(DATA_DIR, 'coach.db')}`,
    });
    const freshMemory = new Memory({ storage: freshStorage, options: { lastMessages: 50 } });
    const result = await freshMemory.recall({ threadId: 'persist-1', perPage: false });

    expect(result.messages.length).toBeGreaterThanOrEqual(2);
    const roles = result.messages.map((m) => m.role).sort();
    expect(roles).toContain('user');
    expect(roles).toContain('assistant');

    const userText = result.messages
      .filter((m) => m.role === 'user')
      .map((m) => flattenContent(m.content))
      .join(' ');
    expect(userText).toContain('hello');
  });

  test('thread IDs are isolated within the same resource', async () => {
    setTestModelOverride(mockModel('reply A'));
    await drain(
      await app.fetch(
        new Request('http://t/coach/turn', {
          method: 'POST',
          headers: authHeaders(),
          body: JSON.stringify(turn('thread-A', '<user_message>about apples</user_message>')),
        }),
      ),
    );

    setTestModelOverride(mockModel('reply B'));
    await drain(
      await app.fetch(
        new Request('http://t/coach/turn', {
          method: 'POST',
          headers: authHeaders(),
          body: JSON.stringify(turn('thread-B', '<user_message>about bananas</user_message>')),
        }),
      ),
    );

    const a = await (await app.fetch(new Request('http://t/thread/thread-A', { headers: authHeaders() }))).json() as { messages: Array<{ content: string }> };
    const b = await (await app.fetch(new Request('http://t/thread/thread-B', { headers: authHeaders() }))).json() as { messages: Array<{ content: string }> };

    expect(a.messages.some((m) => m.content.includes('apples'))).toBe(true);
    expect(a.messages.some((m) => m.content.includes('bananas'))).toBe(false);
    expect(b.messages.some((m) => m.content.includes('bananas'))).toBe(true);
    expect(b.messages.some((m) => m.content.includes('apples'))).toBe(false);
  });

  test('DELETE /thread/:id leaves sibling threads under same resource intact', async () => {
    setTestModelOverride(mockModel('one'));
    for (const id of ['victim-thread', 'survivor-thread']) {
      await drain(
        await app.fetch(
          new Request('http://t/coach/turn', {
            method: 'POST',
            headers: authHeaders(),
            body: JSON.stringify(turn(id, `<user_message>turn for ${id}</user_message>`)),
          }),
        ),
      );
    }

    const del = await app.fetch(
      new Request('http://t/thread/victim-thread', { method: 'DELETE', headers: authHeaders() }),
    );
    expect(del.status).toBe(200);

    const victim = await (await app.fetch(new Request('http://t/thread/victim-thread', { headers: authHeaders() }))).json() as { messages: unknown[] };
    expect(victim.messages).toEqual([]);

    const survivor = await (await app.fetch(new Request('http://t/thread/survivor-thread', { headers: authHeaders() }))).json() as { messages: Array<{ content: string }> };
    expect(survivor.messages.length).toBeGreaterThan(0);
    expect(survivor.messages.some((m) => m.content.includes('survivor-thread'))).toBe(true);
  });

  test('DELETE /resource/:id only wipes that resource', async () => {
    setTestModelOverride(mockModel('ok'));
    await drain(
      await app.fetch(
        new Request('http://t/coach/turn', {
          method: 'POST',
          headers: authHeaders(),
          body: JSON.stringify(turn('isolated-thread', '<user_message>victim message</user_message>', 'persist-resource')),
        }),
      ),
    );
    await drain(
      await app.fetch(
        new Request('http://t/coach/turn', {
          method: 'POST',
          headers: authHeaders(),
          body: JSON.stringify(turn('other-thread', '<user_message>other message</user_message>', 'other-resource')),
        }),
      ),
    );

    const del = await app.fetch(
      new Request('http://t/resource/persist-resource', { method: 'DELETE', headers: authHeaders() }),
    );
    expect(del.status).toBe(200);

    const wiped = await (await app.fetch(new Request('http://t/thread/isolated-thread', { headers: authHeaders() }))).json() as { messages: unknown[] };
    expect(wiped.messages).toEqual([]);

    const survivor = await (await app.fetch(new Request('http://t/thread/other-thread', { headers: authHeaders() }))).json() as { messages: Array<{ content: string }> };
    expect(survivor.messages.length).toBeGreaterThan(0);
  });

  test('two turns on the same thread produce a 4-message history (user/assistant x2)', async () => {
    setTestModelOverride(mockModel('first reply'));
    await drain(
      await app.fetch(
        new Request('http://t/coach/turn', {
          method: 'POST',
          headers: authHeaders(),
          body: JSON.stringify(turn('multi-turn', '<user_message>first question</user_message>')),
        }),
      ),
    );

    setTestModelOverride(mockModel('second reply'));
    await drain(
      await app.fetch(
        new Request('http://t/coach/turn', {
          method: 'POST',
          headers: authHeaders(),
          body: JSON.stringify(turn('multi-turn', '<user_message>second question</user_message>')),
        }),
      ),
    );

    const history = await (await app.fetch(new Request('http://t/thread/multi-turn', { headers: authHeaders() }))).json() as { messages: Array<{ role: string; content: string }> };
    expect(history.messages.length).toBe(4);
    const roles = history.messages.map((m) => m.role);
    // Order should be user, assistant, user, assistant.
    expect(roles).toEqual(['user', 'assistant', 'user', 'assistant']);
    expect(history.messages[0].content).toContain('first question');
    expect(history.messages[1].content).toContain('first reply');
    expect(history.messages[2].content).toContain('second question');
    expect(history.messages[3].content).toContain('second reply');
  });
});

function flattenContent(raw: unknown): string {
  if (typeof raw === 'string') return raw;
  if (raw && typeof raw === 'object') {
    const r = raw as any;
    if (typeof r.content === 'string') return r.content;
    if (Array.isArray(r.parts)) {
      return r.parts.filter((p: any) => p?.type === 'text').map((p: any) => p.text).join('');
    }
  }
  return '';
}

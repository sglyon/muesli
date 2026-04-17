import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import type { LanguageModelV3CallOptions, LanguageModelV3StreamPart } from '@ai-sdk/provider';
import { createWHAM } from '../src/providers/wham.ts';

const realFetch = globalThis.fetch;

interface CapturedRequest {
  url: string;
  method?: string;
  headers: Record<string, string>;
  body: any;
}

let captured: CapturedRequest | undefined;

function installFetchStub(response: { status: number; sseLines?: string[]; rawBody?: string }) {
  globalThis.fetch = (async (input: any, init?: any) => {
    captured = {
      url: typeof input === 'string' ? input : input.url,
      method: init?.method,
      headers: extractHeaders(init?.headers),
      body: init?.body ? JSON.parse(init.body as string) : undefined,
    };
    if (response.status !== 200) {
      return new Response(response.rawBody ?? '', { status: response.status });
    }
    const sseBody = (response.sseLines ?? []).map((l) => l + '\n').join('') + '\n';
    return new Response(sseBody, {
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
    });
  }) as unknown as typeof fetch;
}

function extractHeaders(raw: HeadersInit | undefined): Record<string, string> {
  if (!raw) return {};
  if (raw instanceof Headers) {
    const out: Record<string, string> = {};
    raw.forEach((v, k) => { out[k] = v; });
    return out;
  }
  if (Array.isArray(raw)) {
    return Object.fromEntries(raw);
  }
  return raw as Record<string, string>;
}

function basicCallOptions(extra?: Partial<LanguageModelV3CallOptions>): LanguageModelV3CallOptions {
  return {
    prompt: [
      { role: 'system', content: 'You are a coach.' } as any,
      { role: 'user', content: 'Hello there' } as any,
    ],
    ...extra,
  } as LanguageModelV3CallOptions;
}

async function collectStream(
  stream: ReadableStream<LanguageModelV3StreamPart>,
): Promise<LanguageModelV3StreamPart[]> {
  const out: LanguageModelV3StreamPart[] = [];
  const reader = stream.getReader();
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    out.push(value);
  }
  return out;
}

beforeEach(() => {
  captured = undefined;
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe('WHAM provider — request shape', () => {
  test('POSTs to WHAM URL with bearer + account-id headers', async () => {
    installFetchStub({
      status: 200,
      sseLines: [
        'data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}',
        'data: [DONE]',
      ],
    });
    const provider = createWHAM({ bearer: 'tok-123', accountId: 'acct-456' });
    const model = provider('gpt-5.4-mini');
    const { stream } = await model.doStream(basicCallOptions());
    await collectStream(stream);

    expect(captured?.url).toBe('https://chatgpt.com/backend-api/wham/responses');
    expect(captured?.method).toBe('POST');
    expect(captured?.headers['Authorization']).toBe('Bearer tok-123');
    expect(captured?.headers['ChatGPT-Account-Id']).toBe('acct-456');
    expect(captured?.headers['Content-Type']).toBe('application/json');
  });

  test('omits ChatGPT-Account-Id header when accountId is empty', async () => {
    installFetchStub({
      status: 200,
      sseLines: ['data: {"type":"response.completed","response":{}}', 'data: [DONE]'],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    const { stream } = await provider('gpt-5.4-mini').doStream(basicCallOptions());
    await collectStream(stream);
    expect(captured?.headers['ChatGPT-Account-Id']).toBeUndefined();
  });

  test('converts system messages into instructions and other roles into input array', async () => {
    installFetchStub({
      status: 200,
      sseLines: ['data: {"type":"response.completed","response":{}}', 'data: [DONE]'],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: 'acct' });
    const opts = {
      prompt: [
        { role: 'system', content: 'sys-1' },
        { role: 'system', content: 'sys-2' },
        { role: 'user', content: 'hi' },
        { role: 'assistant', content: 'hello back' },
      ],
    } as unknown as LanguageModelV3CallOptions;
    const { stream } = await provider('m').doStream(opts);
    await collectStream(stream);

    expect(captured?.body.instructions).toBe('sys-1\n\nsys-2');
    expect(captured?.body.input).toHaveLength(2);
    expect(captured?.body.input[0]).toEqual({
      role: 'user',
      content: [{ type: 'input_text', text: 'hi' }],
    });
    expect(captured?.body.input[1]).toEqual({
      role: 'assistant',
      content: [{ type: 'input_text', text: 'hello back' }],
    });
    expect(captured?.body.model).toBe('m');
    expect(captured?.body.stream).toBe(true);
    expect(captured?.body.store).toBe(false);
  });

  test('extracts text from array-shaped content parts', async () => {
    installFetchStub({
      status: 200,
      sseLines: ['data: {"type":"response.completed","response":{}}', 'data: [DONE]'],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    const opts = {
      prompt: [
        { role: 'user', content: [{ type: 'text', text: 'first' }, { type: 'text', text: ' part' }] },
      ],
    } as unknown as LanguageModelV3CallOptions;
    await collectStream((await provider('m').doStream(opts)).stream);
    expect(captured?.body.input[0].content[0].text).toBe('first part');
  });
});

describe('WHAM provider — stream parsing', () => {
  test('translates response.output_text.delta events into text-start/delta/end parts', async () => {
    installFetchStub({
      status: 200,
      sseLines: [
        'data: {"type":"response.output_text.delta","delta":"Hello"}',
        'data: {"type":"response.output_text.delta","delta":", coach"}',
        'data: {"type":"response.output_text.delta","delta":"!"}',
        'data: {"type":"response.completed","response":{"usage":{"input_tokens":7,"output_tokens":3}}}',
        'data: [DONE]',
      ],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    const { stream } = await provider('gpt-5.4-mini').doStream(basicCallOptions());
    const events = await collectStream(stream);

    const types = events.map((e) => e.type);
    expect(types[0]).toBe('stream-start');
    expect(types).toContain('text-start');
    expect(types).toContain('text-delta');
    expect(types).toContain('text-end');
    expect(types[types.length - 1]).toBe('finish');

    const deltas = events.filter((e): e is Extract<LanguageModelV3StreamPart, { type: 'text-delta' }> => e.type === 'text-delta');
    expect(deltas.map((d) => d.delta).join('')).toBe('Hello, coach!');

    const finish = events[events.length - 1] as Extract<LanguageModelV3StreamPart, { type: 'finish' }>;
    expect(finish.finishReason.unified).toBe('stop');
    expect(finish.usage.inputTokens.total).toBe(7);
    expect(finish.usage.outputTokens.total).toBe(3);
  });

  test('handles full-text via response.output_text.done when no deltas were emitted', async () => {
    installFetchStub({
      status: 200,
      sseLines: [
        'data: {"type":"response.output_text.done","text":"complete reply"}',
        'data: {"type":"response.completed","response":{}}',
        'data: [DONE]',
      ],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    const { stream } = await provider('m').doStream(basicCallOptions());
    const events = await collectStream(stream);
    const deltaText = events
      .filter((e): e is Extract<LanguageModelV3StreamPart, { type: 'text-delta' }> => e.type === 'text-delta')
      .map((e) => e.delta)
      .join('');
    expect(deltaText).toBe('complete reply');
  });

  test('maps response.error to a finish with error reason', async () => {
    installFetchStub({
      status: 200,
      sseLines: [
        'data: {"type":"response.output_text.delta","delta":"partial"}',
        'data: {"type":"response.error","message":"boom"}',
        'data: [DONE]',
      ],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    const { stream } = await provider('m').doStream(basicCallOptions());
    const events = await collectStream(stream);
    const finish = events[events.length - 1] as Extract<LanguageModelV3StreamPart, { type: 'finish' }>;
    expect(finish.type).toBe('finish');
    expect(finish.finishReason.unified).toBe('error');
  });

  test('throws when WHAM returns a non-200 status', async () => {
    installFetchStub({ status: 401, rawBody: 'auth failed' });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    await expect(async () => {
      await provider('m').doStream(basicCallOptions());
    }).toThrow();
  });

  test('skips malformed SSE payloads without crashing', async () => {
    installFetchStub({
      status: 200,
      sseLines: [
        'data: {not json',
        'data: {"type":"response.output_text.delta","delta":"survived"}',
        'data: {"type":"response.completed","response":{}}',
        'data: [DONE]',
      ],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    const events = await collectStream((await provider('m').doStream(basicCallOptions())).stream);
    const text = events
      .filter((e): e is Extract<LanguageModelV3StreamPart, { type: 'text-delta' }> => e.type === 'text-delta')
      .map((e) => e.delta)
      .join('');
    expect(text).toBe('survived');
  });
});

describe('WHAM provider — doGenerate', () => {
  test('collects all stream deltas into a single text result', async () => {
    installFetchStub({
      status: 200,
      sseLines: [
        'data: {"type":"response.output_text.delta","delta":"a"}',
        'data: {"type":"response.output_text.delta","delta":"b"}',
        'data: {"type":"response.output_text.delta","delta":"c"}',
        'data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":3}}}',
        'data: [DONE]',
      ],
    });
    const provider = createWHAM({ bearer: 'tok', accountId: '' });
    const result = await provider('m').doGenerate(basicCallOptions());
    expect(result.content).toEqual([{ type: 'text', text: 'abc' }]);
    expect(result.finishReason.unified).toBe('stop');
    expect(result.usage.inputTokens.total).toBe(2);
    expect(result.usage.outputTokens.total).toBe(3);
  });
});

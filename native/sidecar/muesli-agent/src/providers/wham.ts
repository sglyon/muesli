import type {
  LanguageModelV3,
  LanguageModelV3CallOptions,
  LanguageModelV3FinishReason,
  LanguageModelV3StreamPart,
  LanguageModelV3Usage,
} from '@ai-sdk/provider';

/**
 * Custom LanguageModel that adapts the ChatGPT WHAM streaming endpoint
 * (https://chatgpt.com/backend-api/wham/responses) to the AI SDK v6
 * LanguageModelV3 interface so Mastra can use ChatGPT OAuth uniformly
 * alongside Anthropic and OpenAI.
 *
 * The bearer + account ID are passed per-request from the Swift host,
 * which refreshes them via its existing ChatGPTAuthManager.
 */

const WHAM_URL = 'https://chatgpt.com/backend-api/wham/responses';

interface WHAMConfig {
  bearer: string;
  accountId: string;
}

function emptyUsage(
  inputTotal?: number,
  outputTotal?: number,
): LanguageModelV3Usage {
  return {
    inputTokens: {
      total: inputTotal,
      noCache: inputTotal,
      cacheRead: undefined,
      cacheWrite: undefined,
    },
    outputTokens: {
      total: outputTotal,
      text: outputTotal,
      reasoning: undefined,
    },
  };
}

const STOP_REASON: LanguageModelV3FinishReason = { unified: 'stop', raw: undefined };
const ERROR_REASON: LanguageModelV3FinishReason = { unified: 'error', raw: undefined };

function convertPrompt(prompt: LanguageModelV3CallOptions['prompt']): {
  instructions: string;
  input: Array<{ role: string; content: Array<{ type: string; text: string }> }>;
} {
  const systemParts: string[] = [];
  const input: Array<{ role: string; content: Array<{ type: string; text: string }> }> = [];

  for (const msg of prompt) {
    if (msg.role === 'system') {
      systemParts.push(extractText(msg.content));
      continue;
    }
    input.push({
      role: msg.role,
      content: [{ type: 'input_text', text: extractText(msg.content) }],
    });
  }
  return { instructions: systemParts.join('\n\n'), input };
}

function extractText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((part: any) => {
        if (typeof part === 'string') return part;
        if (part?.type === 'text') return part.text ?? '';
        return '';
      })
      .join('');
  }
  return '';
}

function headersToRecord(headers: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  headers.forEach((value, key) => {
    out[key] = value;
  });
  return out;
}

class WHAMLanguageModel implements LanguageModelV3 {
  readonly specificationVersion = 'v3' as const;
  readonly provider = 'chatgpt-wham';
  readonly modelId: string;
  readonly supportedUrls = {};

  constructor(modelId: string, private readonly config: WHAMConfig) {
    this.modelId = modelId;
  }

  async doGenerate(options: LanguageModelV3CallOptions) {
    let collected = '';
    let finishReason: LanguageModelV3FinishReason = STOP_REASON;
    let usage: LanguageModelV3Usage = emptyUsage();

    const { stream } = await this.doStream(options);
    const reader = stream.getReader();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value.type === 'text-delta') collected += value.delta;
      if (value.type === 'finish') {
        finishReason = value.finishReason;
        usage = value.usage;
      }
    }

    return {
      content: [{ type: 'text' as const, text: collected }],
      finishReason,
      usage,
      warnings: [],
      request: {},
      response: {},
    };
  }

  async doStream(options: LanguageModelV3CallOptions) {
    const { instructions, input } = convertPrompt(options.prompt);

    const body: Record<string, unknown> = {
      model: this.modelId,
      store: false,
      stream: true,
      instructions,
      input,
    };

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${this.config.bearer}`,
    };
    if (this.config.accountId) headers['ChatGPT-Account-Id'] = this.config.accountId;

    const response = await fetch(WHAM_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: options.abortSignal,
    });

    if (!response.ok || !response.body) {
      const text = await response.text().catch(() => '');
      throw new Error(`WHAM request failed: HTTP ${response.status} ${text.slice(0, 300)}`);
    }

    const textId = crypto.randomUUID();
    const source = response.body.pipeThrough(new TextDecoderStream()).getReader();

    const stream = new ReadableStream<LanguageModelV3StreamPart>({
      async start(controller) {
        controller.enqueue({ type: 'stream-start', warnings: [] });

        let startedText = false;
        let endedText = false;
        let finished = false;
        let inputTokens: number | undefined;
        let outputTokens: number | undefined;
        let finishReason: LanguageModelV3FinishReason = STOP_REASON;
        let buffer = '';

        try {
          for (;;) {
            const { value, done } = await source.read();
            if (done) break;
            buffer += value;
            let idx = buffer.indexOf('\n');
            while (idx !== -1) {
              const line = buffer.slice(0, idx).trim();
              buffer = buffer.slice(idx + 1);
              idx = buffer.indexOf('\n');
              if (!line.startsWith('data:')) continue;
              const payload = line.slice(5).trim();
              if (payload === '[DONE]') {
                finished = true;
                break;
              }
              let event: any;
              try {
                event = JSON.parse(payload);
              } catch {
                continue;
              }
              const type = event.type as string | undefined;
              if (type === 'response.output_text.delta' && typeof event.delta === 'string') {
                if (!startedText) {
                  controller.enqueue({ type: 'text-start', id: textId });
                  startedText = true;
                }
                controller.enqueue({ type: 'text-delta', id: textId, delta: event.delta });
              } else if (
                type === 'response.output_text.done' &&
                typeof event.text === 'string' &&
                !startedText
              ) {
                controller.enqueue({ type: 'text-start', id: textId });
                startedText = true;
                controller.enqueue({ type: 'text-delta', id: textId, delta: event.text });
              } else if (type === 'response.completed') {
                if (event.response?.usage) {
                  inputTokens = event.response.usage.input_tokens;
                  outputTokens = event.response.usage.output_tokens;
                }
                finished = true;
              } else if (type === 'response.error') {
                finishReason = ERROR_REASON;
                finished = true;
              }
            }
            if (finished) break;
          }
        } finally {
          if (startedText && !endedText) {
            controller.enqueue({ type: 'text-end', id: textId });
            endedText = true;
          }
          controller.enqueue({
            type: 'finish',
            finishReason,
            usage: emptyUsage(inputTokens, outputTokens),
          });
          controller.close();
        }
      },
    });

    return {
      stream,
      request: { body },
      response: { headers: headersToRecord(response.headers) },
    };
  }
}

export function createWHAM(config: WHAMConfig) {
  return function (modelId: string): LanguageModelV3 {
    return new WHAMLanguageModel(modelId, config);
  };
}

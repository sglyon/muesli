import { Hono } from 'hono';
import { streamSSE } from 'hono/streaming';
import { z } from 'zod';
import { buildCoachAgent, SUPPORTED_PROVIDERS } from '../agent/factory.ts';
import type { CoachTurnRequest } from '../types.ts';

const CredentialsSchema = z.object({
  apiKey: z.string().optional(),
  bearer: z.string().optional(),
  accountId: z.string().optional(),
  embedderAPIKey: z.string().optional(),
});

const CoachTurnSchema = z.object({
  threadId: z.string().min(1),
  resourceId: z.string().min(1),
  provider: z.enum(SUPPORTED_PROVIDERS as [string, ...string[]]),
  model: z.string().min(1),
  credentials: CredentialsSchema,
  systemPrompt: z.string().min(1),
  agentInstructions: z.string().optional(),
  workingMemoryTemplate: z.string().optional(),
  turn: z.object({
    kind: z.enum(['transcriptUpdate', 'userMessage']),
    content: z.string().min(1),
  }),
});

export const coachRoute = new Hono();

coachRoute.post('/turn', async (c) => {
  let parsed: CoachTurnRequest;
  try {
    parsed = CoachTurnSchema.parse(await c.req.json()) as CoachTurnRequest;
  } catch (err) {
    return c.json({ error: 'invalid_request', detail: String(err) }, 400);
  }

  return streamSSE(c, async (stream) => {
    const closeWithError = async (message: string) => {
      await stream.writeSSE({ event: 'error', data: JSON.stringify({ message }) });
      await stream.writeSSE({ event: 'done', data: '{}' });
    };

    let agent;
    try {
      agent = buildCoachAgent(parsed);
    } catch (err) {
      await closeWithError((err as Error).message);
      return;
    }

    try {
      const result = await agent.stream([{ role: 'user', content: parsed.turn.content }], {
        memory: {
          thread: { id: parsed.threadId },
          resource: parsed.resourceId,
        },
      });

      for await (const chunk of result.textStream) {
        await stream.writeSSE({ event: 'delta', data: chunk });
      }

      const usage = await result.usage.catch(() => undefined);
      if (usage) {
        await stream.writeSSE({
          event: 'usage',
          data: JSON.stringify({
            input: (usage as any).inputTokens ?? (usage as any).promptTokens,
            output: (usage as any).outputTokens ?? (usage as any).completionTokens,
          }),
        });
      }
    } catch (err) {
      await closeWithError((err as Error).message ?? 'unknown error');
      return;
    }

    await stream.writeSSE({ event: 'done', data: '{}' });
  });
});

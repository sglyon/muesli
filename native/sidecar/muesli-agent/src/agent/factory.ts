import { Agent } from '@mastra/core/agent';
import type { LanguageModelV3 } from '@ai-sdk/provider';
import { createAnthropic } from '@ai-sdk/anthropic';
import { createOpenAI } from '@ai-sdk/openai';
import { createWHAM } from '../providers/wham.ts';
import { getMemory } from '../memory/store.ts';
import type { CoachTurnRequest, ProviderId } from '../types.ts';

let testModelOverride: LanguageModelV3 | undefined;
/** Test hook: when set, buildCoachAgent ignores provider config and uses this. */
export function setTestModelOverride(model: LanguageModelV3 | undefined): void {
  testModelOverride = model;
}

function buildInstructions(req: CoachTurnRequest): string {
  const extra = req.agentInstructions?.trim();
  return extra ? `${req.systemPrompt}\n\n${extra}` : req.systemPrompt;
}

function buildModel(req: CoachTurnRequest) {
  const { provider, model, credentials } = req;
  switch (provider) {
    case 'anthropic': {
      if (!credentials.apiKey) throw new Error('Anthropic provider requires credentials.apiKey');
      return createAnthropic({ apiKey: credentials.apiKey })(model);
    }
    case 'openai': {
      if (!credentials.apiKey) throw new Error('OpenAI provider requires credentials.apiKey');
      return createOpenAI({ apiKey: credentials.apiKey })(model);
    }
    case 'chatgpt': {
      if (!credentials.bearer) {
        throw new Error('ChatGPT provider requires credentials.bearer');
      }
      return createWHAM({ bearer: credentials.bearer, accountId: credentials.accountId ?? '' })(model);
    }
    default: {
      const exhaustive: never = provider;
      throw new Error(`Unknown provider: ${exhaustive}`);
    }
  }
}

export function buildCoachAgent(req: CoachTurnRequest): Agent {
  return new Agent({
    id: 'live-coach',
    name: 'Live Coach',
    instructions: buildInstructions(req),
    model: testModelOverride ?? buildModel(req),
    memory: getMemory(req.credentials.embedderAPIKey),
  });
}

export const SUPPORTED_PROVIDERS: ProviderId[] = ['anthropic', 'openai', 'chatgpt'];

export type ProviderId = 'anthropic' | 'openai' | 'chatgpt';

export interface CoachCredentials {
  /** Anthropic or OpenAI chat key; absent for ChatGPT. */
  apiKey?: string;
  /** ChatGPT OAuth bearer (short-lived, refreshed by host on every call). */
  bearer?: string;
  /** ChatGPT-Account-Id header value. */
  accountId?: string;
  /** OpenAI key used ONLY for semantic-recall embeddings. */
  embedderAPIKey?: string;
}

export type CoachTurnKind = 'transcriptUpdate' | 'userMessage';

export interface CoachTurnRequest {
  threadId: string;
  resourceId: string;
  provider: ProviderId;
  model: string;
  credentials: CoachCredentials;
  systemPrompt: string;
  agentInstructions?: string;
  turn: {
    kind: CoachTurnKind;
    content: string;
  };
}

export const SIDECAR_VERSION = '0.1.0';

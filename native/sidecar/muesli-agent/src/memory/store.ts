import path from 'node:path';
import fs from 'node:fs';
import { Memory } from '@mastra/memory';
import { LibSQLStore, LibSQLVector } from '@mastra/libsql';
import { createOpenAI } from '@ai-sdk/openai';

const SALES_COACH_TEMPLATE = `
# Muesli User Profile

## About
- Name:
- Company / offering: (default: Spencer Lyon @ Arete Intelligence — data engineering, data science, AI transformation for mid-market companies)
- Common buyer personas:

## Pitch Patterns
- Strengths observed:
- Recurring weaknesses / tells:
- Go-to discovery questions that have worked:

## Prospect Intel (most-recent-first)
- [Prospect / company] — [date] — key concerns, stage, next step:

## Objection Library
- [Objection] → [best response seen so far]
`.trim();

function resolveDataDir(): string {
  const dir = process.env.MUESLI_DATA_DIR;
  if (!dir) {
    throw new Error('MUESLI_DATA_DIR env var is required');
  }
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

const dataDir = resolveDataDir();
const messagesDbUrl = `file:${path.join(dataDir, 'coach.db')}`;
const vectorsDbUrl = `file:${path.join(dataDir, 'coach-vectors.db')}`;

const storage = new LibSQLStore({ id: 'muesli-coach-storage', url: messagesDbUrl });
const vector = new LibSQLVector({ id: 'muesli-coach-vector', url: vectorsDbUrl });

/**
 * Cache of Memory instances keyed by embedder-key fingerprint so we only
 * rebuild when the OpenAI embedder key changes. The underlying LibSQL
 * storage + vector are shared across all Memory instances.
 */
const memoryCache = new Map<string, Memory>();

function embedderFingerprint(embedderKey: string | undefined): string {
  if (!embedderKey) return 'no-embedder';
  return `openai:${embedderKey.slice(-8)}`;
}

export function getMemory(embedderKey?: string): Memory {
  const fp = embedderFingerprint(embedderKey);
  const cached = memoryCache.get(fp);
  if (cached) return cached;

  const semanticOn = Boolean(embedderKey);
  const embedder = semanticOn
    ? createOpenAI({ apiKey: embedderKey }).textEmbeddingModel('text-embedding-3-small')
    : undefined;

  const memory = new Memory({
    storage,
    vector: semanticOn ? vector : undefined,
    embedder,
    options: {
      lastMessages: 20,
      semanticRecall: semanticOn
        ? { topK: 4, messageRange: { before: 2, after: 1 }, scope: 'resource' }
        : false,
      workingMemory: { enabled: true, template: SALES_COACH_TEMPLATE, scope: 'resource' },
      generateTitle: true,
    },
  });
  memoryCache.set(fp, memory);
  return memory;
}

export async function deleteThread(threadId: string): Promise<void> {
  await getMemory(undefined).deleteThread(threadId);
}

export async function deleteResource(resourceId: string): Promise<void> {
  const memory = getMemory(undefined);
  const result = await memory.listThreads({ filter: { resourceId } });
  for (const thread of result.threads) {
    await memory.deleteThread(thread.id);
  }
}

export interface HistoricalMessage {
  id: string;
  role: string;
  content: string;
  createdAt: string | null;
}

export async function getThreadMessages(threadId: string): Promise<HistoricalMessage[]> {
  const memory = getMemory(undefined);
  const { messages } = await memory.recall({ threadId, perPage: false });
  return messages.map((m) => ({
    id: m.id,
    role: m.role,
    content: flattenContent((m as any).content),
    createdAt: (m as any).createdAt ? new Date((m as any).createdAt).toISOString() : null,
  }));
}

function flattenContent(raw: unknown): string {
  if (typeof raw === 'string') return raw;
  if (!raw || typeof raw !== 'object') return '';
  const anyRaw = raw as any;
  // MastraDBMessage content shape: { format, parts: [{type:'text', text}], content?: string }
  if (typeof anyRaw.content === 'string') return anyRaw.content;
  if (Array.isArray(anyRaw.parts)) {
    return anyRaw.parts
      .filter((p: any) => p?.type === 'text' && typeof p?.text === 'string')
      .map((p: any) => p.text)
      .join('');
  }
  if (Array.isArray(anyRaw)) {
    return anyRaw.map((p) => (typeof p === 'string' ? p : p?.text ?? '')).join('');
  }
  if (typeof anyRaw.text === 'string') return anyRaw.text;
  return '';
}

export const MEMORY_DATA_DIR = dataDir;

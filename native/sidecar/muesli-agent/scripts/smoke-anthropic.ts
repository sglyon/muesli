#!/usr/bin/env bun
/**
 * Live Anthropic smoke test that simulates a realistic Arete Intelligence
 * sales call. We feed the sidecar a sequence of:
 *   - `transcriptUpdate` turns (what the meeting transcript pipeline would
 *     send proactively after each VAD-driven chunk finalizes)
 *   - `userMessage` turns (questions the user types into the coach panel
 *     mid-meeting)
 *
 * For each event we print the exact XML payload that goes on the wire and
 * stream Anthropic's reply back so you can read the conversation top to
 * bottom and judge the coach's quality.
 *
 * Requires:
 *   - ANTHROPIC_API_KEY in env
 *   - dist/muesli-agent built (`./build.sh`)
 *
 * Usage:
 *   ANTHROPIC_API_KEY=sk-ant-... bun run scripts/smoke-anthropic.ts
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const BINARY = path.resolve(import.meta.dir, '..', 'dist', 'muesli-agent');
const MODEL = process.env.MUESLI_SMOKE_MODEL ?? 'claude-sonnet-4-6';
const KEY = process.env.ANTHROPIC_API_KEY;
const THREAD_ID = process.env.MUESLI_SMOKE_THREAD ?? `smoke-${Date.now()}`;

if (!KEY) {
  console.error('ANTHROPIC_API_KEY not set in env — refusing to run.');
  process.exit(2);
}
if (!fs.existsSync(BINARY)) {
  console.error(`Sidecar binary not found at ${BINARY}. Run ./build.sh first.`);
  process.exit(2);
}

// ANSI dim/colour helpers — fall back to plain text if NO_COLOR is set.
const useColor = !process.env.NO_COLOR && process.stdout.isTTY;
const c = (code: string, s: string) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : s);
const dim = (s: string) => c('2', s);
const bold = (s: string) => c('1', s);
const cyan = (s: string) => c('36', s);
const yellow = (s: string) => c('33', s);
const green = (s: string) => c('32', s);
const magenta = (s: string) => c('35', s);

const SYSTEM_PROMPT = [
  'You are a real-time sales coach for Spencer Lyon at Arete Intelligence',
  '(data engineering, data science, and AI transformation for mid-market companies).',
  'When you receive a <transcript_update>, give 1-3 short, actionable coaching tips:',
  'tone, the next question to ask, an objection to anticipate, or a discovery thread',
  'to pull on. When you receive a <user_message>, answer it directly. Keep replies',
  'tight (under 120 words). Plain text only — no markdown.',
].join(' ');

interface TranscriptLine {
  time: string;       // "HH:MM:SS"
  speaker: string;    // "You" or "Speaker N"
  text: string;
}

type Event =
  | { label: string; kind: 'transcriptUpdate'; since: string; until: string; lines: TranscriptLine[] }
  | { label: string; kind: 'userMessage'; question: string };

const EVENTS: Event[] = [
  {
    label: 'Opening exchange',
    kind: 'transcriptUpdate',
    since: '00:00:00',
    until: '00:00:25',
    lines: [
      { time: '00:00:05', speaker: 'You', text: "Hey Marcus, thanks for taking the time. I'm Spencer with Arete Intelligence." },
      { time: '00:00:14', speaker: 'Speaker 1', text: "Sure. Before you go too deep — what is it you actually do? We get a lot of these calls." },
    ],
  },
  {
    label: 'Pitch + first objection',
    kind: 'transcriptUpdate',
    since: '00:00:25',
    until: '00:01:10',
    lines: [
      { time: '00:00:30', speaker: 'You', text: "Fair question. Short version: we run data engineering, data science, and AI transformation projects for mid-market companies — usually around 100 to 500 people." },
      { time: '00:00:55', speaker: 'Speaker 1', text: "Look, we got burned by an AI vendor last year. Six months over budget and the model honestly just sat there." },
    ],
  },
  {
    label: 'Your question to the coach',
    kind: 'userMessage',
    question: 'Should I name a specific case study now or stay in discovery and ask more about that failed project?',
  },
  {
    label: 'Prospect surfaces real pain',
    kind: 'transcriptUpdate',
    since: '00:01:10',
    until: '00:02:05',
    lines: [
      { time: '00:01:20', speaker: 'You', text: "That sounds painful. What hurt the most about it?" },
      { time: '00:01:35', speaker: 'Speaker 1', text: "Honestly? Nobody on our team actually understood what got delivered. The vendor disappeared and we were left with a Jupyter notebook nobody could maintain." },
      { time: '00:01:55', speaker: 'You', text: "Yeah, that handoff problem is super common." },
    ],
  },
  {
    label: 'Mid-call check-in',
    kind: 'userMessage',
    question: 'I want to pivot toward how we do enablement differently. Give me one sentence I can use to bridge.',
  },
  {
    label: 'Closing momentum',
    kind: 'transcriptUpdate',
    since: '00:02:05',
    until: '00:03:00',
    lines: [
      { time: '00:02:10', speaker: 'You', text: "One thing we do differently — every project includes a hand-off plan and pairing sessions with your team so they own the system at the end." },
      { time: '00:02:40', speaker: 'Speaker 1', text: "That's actually the missing piece for us. Who would I need to get on a follow-up call to talk scope?" },
    ],
  },
];

// Spawn sidecar
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'muesli-smoke-'));
console.error(dim(`[setup] data dir: ${dataDir}`));
console.error(dim(`[setup] thread:   ${THREAD_ID}`));

const child = spawn(BINARY, [], {
  env: { ...process.env, MUESLI_DATA_DIR: dataDir },
  stdio: ['ignore', 'pipe', 'pipe'],
});
child.stderr?.on('data', (d) => process.stderr.write(dim(`[sidecar] ${d}`)));

const handshake = await new Promise<{ port: number; token: string }>((resolve, reject) => {
  let buf = '';
  child.stdout?.on('data', (chunk: Buffer) => {
    buf += chunk.toString();
    const nl = buf.indexOf('\n');
    if (nl === -1) return;
    try {
      resolve(JSON.parse(buf.slice(0, nl).trim()));
    } catch (err) {
      reject(new Error(`Unparseable handshake: ${buf.slice(0, nl)}`));
    }
  });
  setTimeout(() => reject(new Error('handshake timeout')), 5_000);
});

console.error(dim(`[setup] sidecar listening on :${handshake.port}\n`));

// Helpers
function formatTranscript(lines: TranscriptLine[]): string {
  return lines.map((l) => `[${l.time}] ${l.speaker}: ${l.text}`).join('\n');
}
function escapeXml(s: string): string {
  return s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}
function buildPayload(event: Event): string {
  if (event.kind === 'transcriptUpdate') {
    const body = escapeXml(formatTranscript(event.lines));
    return `<transcript_update since="${event.since}" until="${event.until}">\n${body}\n</transcript_update>`;
  }
  return `<user_message>${escapeXml(event.question)}</user_message>`;
}

async function streamTurn(event: Event): Promise<{ reply: string; usage?: { input?: number; output?: number } }> {
  const url = `http://127.0.0.1:${handshake.port}/coach/turn`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${handshake.token}`,
      Accept: 'text/event-stream',
    },
    body: JSON.stringify({
      threadId: THREAD_ID,
      resourceId: 'smoke-resource',
      provider: 'anthropic',
      model: MODEL,
      credentials: { apiKey: KEY },
      systemPrompt: SYSTEM_PROMPT,
      turn: { kind: event.kind, content: buildPayload(event) },
    }),
  });

  if (resp.status !== 200) {
    throw new Error(`HTTP ${resp.status}: ${(await resp.text()).slice(0, 300)}`);
  }

  const reader = resp.body!.pipeThrough(new TextDecoderStream()).getReader();
  let buf = '';
  let evType: string | undefined;
  let dataLines: string[] = [];
  let collected = '';
  let usage: { input?: number; output?: number } | undefined;
  let errorMsg: string | undefined;

  const flush = () => {
    const data = dataLines.join('\n');
    if (evType === 'delta') {
      collected += data;
      process.stdout.write(data);  // live-stream so the user sees it appear
    } else if (evType === 'usage') {
      try { usage = JSON.parse(data); } catch { /* ignore */ }
    } else if (evType === 'error') {
      errorMsg = data;
    }
    evType = undefined;
    dataLines = [];
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
      if (line === '') { flush(); }
      else if (line.startsWith('event:')) { evType = line.slice(6).trim(); }
      else if (line.startsWith('data:')) { dataLines.push(line.slice(5).replace(/^ /, '')); }
    }
  }
  flush();

  if (errorMsg) throw new Error(`stream error: ${errorMsg}`);
  return { reply: collected, usage };
}

function printEventInput(idx: number, event: Event): void {
  const header = bold(`━━━ Event ${idx + 1}: ${event.label} ━━━`);
  console.log(`\n${header}`);
  if (event.kind === 'transcriptUpdate') {
    console.log(yellow(`[transcript ${event.since} → ${event.until}]`));
    for (const line of event.lines) {
      const speakerColor = line.speaker === 'You' ? green : magenta;
      console.log(`  ${dim(line.time)}  ${speakerColor(line.speaker)}: ${line.text}`);
    }
  } else {
    console.log(yellow('[user message to coach]'));
    console.log(`  ${cyan('▸')} ${event.question}`);
  }
  console.log(yellow('[coach reply]'));
  process.stdout.write('  ');
}

let exitCode = 0;
try {
  for (const [i, event] of EVENTS.entries()) {
    printEventInput(i, event);
    const start = Date.now();
    const { reply, usage } = await streamTurn(event);
    const dur = ((Date.now() - start) / 1000).toFixed(1);
    if (!reply.trim()) throw new Error(`empty reply for event ${i + 1}`);
    const tokInfo = usage ? `, ${usage.input ?? '?'} in / ${usage.output ?? '?'} out tokens` : '';
    console.log(`\n  ${dim(`(${dur}s${tokInfo})`)}`);
  }

  // Verify thread persistence at the end.
  console.log(`\n${bold('━━━ Persisted thread history ━━━')}`);
  const histResp = await fetch(`http://127.0.0.1:${handshake.port}/thread/${encodeURIComponent(THREAD_ID)}`, {
    headers: { Authorization: `Bearer ${handshake.token}` },
  });
  const hist = (await histResp.json()) as { messages: Array<{ role: string; content: string }> };
  console.log(dim(`(${hist.messages.length} messages — ${EVENTS.length} user + ${EVENTS.length} assistant expected)`));
  if (hist.messages.length !== EVENTS.length * 2) {
    throw new Error(`expected ${EVENTS.length * 2} messages, got ${hist.messages.length}`);
  }

  console.log(`\n${green('✅ Anthropic smoke test passed')}`);
} catch (err) {
  console.error(`\n${c('31', '❌ Smoke test failed:')} ${(err as Error).message}`);
  exitCode = 1;
} finally {
  child.kill('SIGTERM');
  fs.rmSync(dataDir, { recursive: true, force: true });
}

process.exit(exitCode);

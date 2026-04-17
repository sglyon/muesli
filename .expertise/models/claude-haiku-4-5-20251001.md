# Muesli Codebase Mental Model

## Live Transcript & Speaker Diarization Architecture

### High-Level Overview
The Muesli application implements real-time meeting recording with live speaker diarization. Audio is streamed in chunks (VAD-driven), transcribed per-chunk, and diarization runs on-the-fly to identify speakers with consistent IDs across chunks. A floating transcript panel polls every second to display formatted speaker labels and timestamps.

### Core Components

#### 1. Diarization Pipeline (FluidAudio Framework)
**Location**: External package `https://github.com/FluidInference/FluidAudio.git` (v0.12.2+)

- **DiarizerManager** (`Core/DiarizerManager.swift`): Orchestrates complete diarization
  - `performCompleteDiarization()`: Processes audio in 10s chunks with sliding window
  - `processChunkWithSpeakerTracking()`: Per-chunk processing with speaker assignment
  - Uses pyannote segmentation model (detects speech frames)
  - Uses WeSpeaker embedding model (256D embeddings per speaker)
  - Calls SpeakerManager for clustering

- **SpeakerManager** (`Clustering/SpeakerManager.swift`): Persistent speaker database
  - In-memory `[String: Speaker]` dict mapping IDs to profiles
  - Thread-safe via concurrent DispatchQueue with barriers
  - Assignment thresholds:
    - `speakerThreshold: 0.65` (default) - cosine distance for clustering
    - `embeddingThreshold: 0.45` - threshold for updating embeddings
    - `minSpeechDuration: 1.0s` - minimum duration to create new speaker
    - `minEmbeddingUpdateDuration: 2.0s` - minimum to update embedding
  - Embedding update uses exponential moving average (α=0.9)
  - Raw embeddings stored in FIFO queue (max 50)
  - Cosine distance interpretation:
    - < 0.3: Same speaker (very high confidence)
    - 0.3-0.5: Same speaker (high confidence)
    - 0.5-0.7: Same speaker (medium, may update)
    - 0.7-0.9: Different speakers (medium confidence)
    - > 0.9: Different speakers (high confidence)

- **Speaker** (`Clustering/SpeakerTypes.swift`): Speaker profile
  - `id`: String identifier (numeric or UUID)
  - `currentEmbedding`: L2-normalized 256D vector
  - `rawEmbeddings`: History of embeddings (FIFO)
  - `duration`: Total speech time in seconds
  - `isPermanent`: Flag to prevent deletion/merging
  - Methods:
    - `updateMainEmbedding()`: EMA update with validation
    - `mergeWith()`: Combine two speakers' embeddings and duration
    - `recalculateMainEmbedding()`: Average all raw embeddings

#### 2. Audio Chunking & VAD
**Location**: `Sources/MuesliNativeApp/StreamingMicRecorder.swift` + `StreamingVadController.swift`

- **StreamingMicRecorder**: Real-time mic buffering with AVAudioEngine
  - Sample rate: 16,000 Hz (16 kHz)
  - Chunk size: 4,096 samples = 256ms per chunk at 16kHz
  - Format conversion: Hardware native → 16kHz mono Float32 (internal) → 16kHz mono Int16 PCM (file)
  - File rotation: Zero-gap switching (no dropped samples between files)
  - Converts Float32 samples → Int16 clamping: `Int16(clamped * 32767)`
  - WAV header written with placeholder, finalized on close with correct data size
  - Creates temp files in `/var/folders/.../muesli-meeting-mic/` with UUID names

- **StreamingVadController**: Bridges mic audio to Silero VAD Core ML model
  - Maintains `VadStreamState` for streaming inference
  - Processes 4096-sample buffers (256ms at 16kHz)
  - Detects `speechEnd` events → calls `onChunkBoundary` callback
  - Guards:
    - Minimum chunk duration: **3.0 seconds** (prevents rapid flipping on brief pauses)
    - Maximum chunk duration: **60.0 seconds** (safety cap, fallback timer)
  - Max-duration timer auto-resets on successful rotation

- **VadManager** (FluidAudio): Silero VAD Core ML model
  - Configuration (from documentation):
    - `defaultThreshold: Float = 0.85` (speech probability threshold, tunable 0.3-0.9)
    - `minSpeechDuration: TimeInterval = 0.15s` (minimum speech to keep)
    - `minSilenceDuration: TimeInterval = 0.75s` (silence required to end segment)
    - `maxSpeechDuration: TimeInterval = 14.0s` (max segment length before split)
    - `speechPadding: TimeInterval = 0.1s` (context padding around speech)
    - `silenceThresholdForSplit: Float = 0.3` (split threshold)
    - `negativeThresholdOffset: Float = 0.15` (hysteresis offset)

#### 3. Meeting Session & Chunk Management
**Location**: `Sources/MuesliNativeApp/MeetingSession.swift`

- **MeetingSession**: Coordinates recording, chunking, and transcription
  - Maintains locks for incremental segment accumulation:
    - `resolvedMicSegments`: Mic audio transcriptions
    - `resolvedSystemSegments`: System audio transcriptions
    - `resolvedDiarizationSegments`: Speaker segments with IDs
    - `speakerLabelMap`: Maps speaker ID → "Speaker N" (stable across polls)
    - `nextSpeakerNumber`: Sequential counter for speaker numbering
  - Key methods:
    - `start()`: Initialize recorders, VAD, speaker database reset
    - `rotateChunk()`: Called on VAD boundary or max-duration timeout
    - `allSegments()`: Returns snapshot of all segments (for live transcript)
    - `transcriptDelta()`: Returns new segments since last offset (for clipboard copy)
    - `stop()`: Finalize recording, run batch diarization on system audio

- **Chunking Strategy**:
  - VAD-driven rotation on `speechEnd` events (3s min, 60s max)
  - Fallback: max-duration timer (60s hard cap)
  - Mic and system audio rotated simultaneously (zero gap)
  - Each chunk transcribed independently via `transcribeMeetingChunk()`

- **Per-Chunk Processing** (`rotateChunk()` flow):
  1. Rotate files on both recorders → get chunk URLs
  2. Spawn mic transcription task (immediate)
  3. Spawn system task that waits for mic to finish (CoreML race prevention)
  4. System task calls `diarizeSystemAudio()` on chunk
  5. Diarization results offset by chunk start time: `seg.startTimeSeconds + Float(chunkOffset)`
  6. New speaker IDs registered in `speakerLabelMap` with sequential numbering

#### 4. Streaming VAD Integration (VAD-to-Diarization Pipeline)
**Key Insight**: VAD drives chunk boundaries, not the other way around
- Mic recorder forwards 4096-sample buffers to `StreamingVadController.processAudio()`
- VAD detects speech end → calls `MeetingSession.rotateChunk()`
- System audio transcribed and diarized within each chunk window
- Persistent `DiarizerManager.speakerManager` across chunks ensures consistent speaker IDs

#### 5. Live Transcript Panel
**Location**: `Sources/MuesliNativeApp/LiveTranscript*.swift`

- **LiveTranscriptPanelController**: Manages floating NSPanel window
  - Polls `MeetingSession.allSegments()` every 1 second
  - Detects changes via cheap count check (`segmentCounts()`)
  - Calls `TranscriptFormatter.merge()` on change
  - Parses `[HH:mm:ss] Speaker: text` format into `TranscriptEntry` objects
  - Panel dimensions: 380x500, positioned top-right, floating level

- **LiveTranscriptView**: SwiftUI rendering
  - Displays `TranscriptEntry` list in scroll view
  - Auto-scrolls to latest on update
  - Shows timestamp, speaker label, and text
  - "You" label highlighted differently from "Speaker N" labels

- **TranscriptEntry**: Single line representation
  - `id`: Index for SwiftUI
  - `timestamp`: "HH:mm:ss" string
  - `speaker`: "You" or "Speaker N"
  - `text`: Transcribed text

#### 6. Transcript Formatting & Merging
**Location**: `Sources/MuesliNativeApp/TranscriptFormatter.swift`

- **TranscriptFormatter.merge()**: Combines mic and system segments with speaker labels
  - Detects stream overlap: >50% word Jaccard similarity + ±10s temporal proximity
  - If overlapped (>50%): uses system + diarization only
  - If distinct: mic = "You", system = diarized speakers
  - Consolidates consecutive same-speaker segments (token-level deduplication)
  - Finds best speaker for each ASR segment via time overlap with diar segments
  - Falls back to "Others" if no diarization match

- **Key Insight**: Time-based speaker matching
  - For each ASR segment [start, end], find overlapping diarization segments
  - Assign to speaker with maximum overlap duration
  - Falls back to "Others" if no diarization data or no time overlap

- **Jaccard Similarity Computation**:
  - `wordOverlap(a, b) = |intersection| / |union|`
  - Splits on non-letter/non-number characters
  - Case-insensitive comparison

### Data Flow: Real-Time Meeting

```
1. Start Recording
   ├─ Reset speaker database in DiarizerManager.speakerManager
   ├─ Initialize StreamingMicRecorder + SystemAudioRecorder
   └─ Create StreamingVadController (wires mic audio to VAD)

2. Audio Streaming (256ms chunks via AVAudioEngine tap)
   ├─ Mic recorder: 4096 samples → Float32 conversion → Int16 PCM file write
   ├─ Forward 4096 Float32 samples to StreamingVadController
   ├─ System recorder: captures system audio (background)
   └─ VAD maintains streaming state, detects speech boundaries

3. VAD Boundary Detected (speechEnd event) or 60s timeout
   └─ MeetingSession.rotateChunk()
      ├─ Snapshot mic file → mic chunk WAV
      ├─ Snapshot system file → system chunk WAV
      ├─ Reset currentChunkStartTime = now
      │
      ├─ Task 1: Mic Transcription
      │  ├─ transcribeMeetingChunk(at: micChunkURL)
      │  │  ├─ VadManager.process() - skip if silent
      │  │  └─ ASRBackend.transcribe() - get text
      │  └─ Result appended to resolvedMicSegments
      │
      └─ Task 2: System (waits for Task 1 to finish)
         ├─ transcribeMeetingChunk(at: systemChunkURL)
         ├─ diarizeSystemAudio(at: systemChunkURL)
         │  ├─ AudioConverter.resampleAudioFile(systemChunkURL) → 16kHz samples
         │  ├─ DiarizerManager.performCompleteDiarization(samples, sampleRate: 16000)
         │  │  └─ For each 10s window within chunk:
         │  │     ├─ Segment: pyannote model → speaker activity
         │  │     ├─ Embed: WeSpeaker model → 256D vectors
         │  │     └─ Cluster: SpeakerManager.assignSpeaker()
         │  │        ├─ Compute cosine distance to existing speakers
         │  │        ├─ If distance < 0.65: assign + maybe update embedding
         │  │        ├─ Else if duration >= 1.0s: create new speaker
         │  │        └─ Else: skip (too short)
         │  ├─ Offset results by chunk time: +Float(chunkOffset)
         │  └─ Results in DiarizationResult.segments: [TimedSpeakerSegment]
         │     └─ TimedSpeakerSegment: (speakerId, embedding: [], startTimeSeconds, endTimeSeconds, qualityScore)
         │
         ├─ Update resolvedDiarizationSegments
         └─ Register new speaker IDs in speakerLabelMap
            └─ Unmapped IDs → "Speaker 1", "Speaker 2", ... (sequential)

4. Live Transcript Poll (every 1 second)
   ├─ LiveTranscriptPanelController.updateTranscript()
   ├─ Check segmentCounts() for changes
   ├─ On change: MeetingSession.allSegments()
   ├─ TranscriptFormatter.merge() with diarization
   ├─ Parse into TranscriptEntry objects
   └─ SwiftUI re-renders list with auto-scroll

5. Meeting End
   ├─ Transcribe final mic chunk (if any)
   ├─ Batch-transcribe system audio (if not all chunked)
   ├─ Batch-diarize system audio (may re-identify some speakers from chunks)
   ├─ Consolidate all segments by time
   └─ Format final transcript for storage
```

### Key Design Patterns

#### 1. Persistent Speaker Database Across Chunks
- Single `DiarizerManager` instance with one `SpeakerManager` per meeting
- Speaker IDs generated sequentially (1, 2, 3, ...) and persist across chunks
- Embedding comparison (cosine distance) ensures consistent matching
- Database reset between meetings to prevent contamination from prior meetings

#### 2. Dual-Stream Deduplication
- Detects if mic and system both captured same audio
- Uses word Jaccard similarity (intersection / union) + temporal proximity (±10s)
- If overlap >50%: uses system + diarization only (avoids duplication)
- If distinct: labels mic as "You", system speakers get diarization labels

#### 3. Stable Speaker Label Mapping
- Maps speaker IDs (numeric strings from clustering) → "Speaker 1", "Speaker 2", ...
- First appearance gets next sequential number (tracked in `nextSpeakerNumber`)
- Map persists in `speakerLabelMap` lock across polls and chunks
- Ensures labels don't shuffle when transcript is displayed incrementally

#### 4. Serialized Transcription (Avoid CoreML Race)
- Mic chunk transcription runs first
- System chunk transcription explicitly waits for mic via `await precedingMicTask.value`
- Prevents concurrent CoreML predictions whose MLMultiArray buffers race with autorelease pool cleanup
- Results in EXC_BAD_ACCESS if not serialized

#### 5. VAD-Driven Chunking with Fallback
- Natural speech boundaries detected by Silero VAD (`speechEnd` events)
- Minimum chunk duration (3s) prevents jitter on brief pauses
- Maximum chunk duration (60s) as safety fallback
- Max-duration timer resets on successful rotation
- No audio gap during rotation (zero-gap file switching)

#### 6. AudioConverter for Format Normalization
- FluidAudio's `AudioConverter.resampleAudioFile(url)` handles all conversions
- Supports WAV, M4A, MP3, FLAC inputs
- Outputs 16kHz mono Float32 [Float] array
- Essential before passing to DiarizerManager.performCompleteDiarization()

### Embedding & Clustering Details

#### Cosine Distance Computation
- Uses vDSP (Accelerate framework) for performance
- Formula: `distance = 1 - (a·b) / (|a| |b|)`
- Returns 0 (identical) to 2 (opposite)
- L2-normalized embeddings reduce to similarity check
- Thresholds scale based on DiarizerConfig.clusteringThreshold (default 0.7)

#### Speaker Assignment Logic
```
For embedding E from detected speaker:
1. Normalize: E' = E / ||E||
2. Find closest existing speaker S_min with distance d_min
3. If d_min < speakerThreshold (0.65):
   - Assign to S_min
   - If d_min < embeddingThreshold (0.45) AND duration >= minEmbeddingUpdateDuration (2.0s):
     - Update embedding via EMA: E'_new = 0.9 * E'_old + 0.1 * E'
   - Update duration += segment_duration
4. Else if segment_duration >= minSpeechDuration (1.0s):
   - Create new speaker with ID = nextCounter++
   - Store in SpeakerManager database
5. Else:
   - Skip (segment too short, not stored)
```

#### Raw Embedding Management
- Stored in FIFO queue (max 50 per speaker)
- Used to recalculate main embedding on demand
- Helps smooth out noisy segments via averaging
- `mergeWith()` keeps most recent 50 from combined history

### Configuration

- **DiarizerConfig** (tunable):
  - `clusteringThreshold: 0.7` - base similarity threshold
  - `minSpeechDuration: 1.0s` - minimum to create speaker
  - `minEmbeddingUpdateDuration: 2.0s` - minimum to update embedding
  - `minActiveFramesCount: 10.0` - frames for valid speech
  - `chunkDuration: 10.0s` - default chunk size
  - `chunkOverlap: 0.0s` - no overlap (VAD replaces)

- **SpeakerManager thresholds** (derived from config):
  - Speaker assignment: 0.65 (default, not computed)
  - Embedding update: 0.45 (default, not computed)

- **VadManager thresholds** (Silero VAD segmentation):
  - Entry threshold: 0.85 (default, tunable via config)
  - Exit threshold: computed as entry - 0.15 (hysteresis)
  - Min speech duration: 0.15s
  - Min silence duration: 0.75s
  - Max speech duration: 14.0s

### File Organization

```
FluidAudio (external package, v0.12.2+):
├── Diarizer/
│   ├── Core/
│   │   ├── DiarizerManager.swift (orchestration, performCompleteDiarization)
│   │   ├── DiarizerTypes.swift (config, DiarizationResult, TimedSpeakerSegment)
│   │   └── DiarizerModels.swift (model download/load, DiarizerModels.download())
│   └── Clustering/
│       ├── SpeakerManager.swift (database, assignSpeaker, findSpeaker)
│       ├── SpeakerTypes.swift (Speaker, RawEmbedding)
│       └── SpeakerOperations.swift (cosine distance, utilities)
├── VAD/
│   └── VadManager.swift (Silero VAD, processStreamingChunk, process)
└── Shared/
    └── AudioConverter.swift (resampleAudioFile, format normalization)

MuesliNativeApp (main app):
├── MeetingSession.swift (chunk management, accumulation, VAD integration)
├── TranscriptionRuntime.swift (coordinator init, diarizeSystemAudio, resetSpeakerDatabase)
├── StreamingMicRecorder.swift (AVAudioEngine tap, 4096-sample buffering, WAV writing)
├── StreamingVadController.swift (VAD boundary detection, speechEnd events)
├── LiveTranscriptPanelController.swift (1s polling, panel management)
├── LiveTranscriptView.swift (SwiftUI rendering, auto-scroll)
└── TranscriptFormatter.swift (merging, time-overlap matching, speaker labeling)
```

### Testing

**Unit Tests in Muesli**:
- `Tests/MuesliTests/TranscriptFormatterTests.swift`:
  - `diarizationAssignsSpeakers()` - Verifies speaker labels from diarization segments
  - `diarizationLabelOrder()` - Tests speaker numbering by first appearance
  - `diarizationBestOverlap()` - Validates time-overlap matching algorithm
  - `diarizationWithMicInterleave()` - Tests interleaving of mic and diarized speakers
  - `diarizationConsolidatesTokens()` - Consolidates token-level segments
  - `threeSpeakers()` - Multi-speaker scenario
  - Helper: `makeDiarSeg()` creates TimedSpeakerSegment with speakerId, embedding: [], start/end times, qualityScore

### Recent Commits

- **b6160f3** (Mar 25, 2026): Add live speaker diarization with consistent cross-chunk speaker IDs
  - Per-chunk diarization during meeting
  - Dual-stream deduplication
  - Stable speaker label mapping
  
- **567d7e7** (Mar 25, 2026): Add live transcript panel during meeting recording (Cmd+Shift+T)
  - Floating NSPanel with SwiftUI content
  - 1-second polling from MeetingSession
  - Auto-scroll to latest entries

### Critical Implementation Notes

1. **Speaker Database Reset**: `TranscriptionCoordinator.resetSpeakerDatabase()` called at meeting start to clean speaker state
2. **Chunk Offset Tracking**: `currentChunkStartTime` stored at rotation to compute absolute timestamps
3. **Diarization Offset**: Chunk-relative times converted to absolute: `seg.startTimeSeconds + Float(chunkOffset)`
4. **Label Stability**: First-seen speaker IDs numbered sequentially, map persists in locks
5. **Stream Deduplication**: Checks >50% overlap (Jaccard) before deciding dual vs. single stream mode
6. **CoreML Serialization**: System transcription explicitly waits for mic via `await precedingMicTask.value`
7. **VAD State**: Maintained per StreamingVadController instance, reset on rotation
8. **Max Duration Guard**: 60s hard cap ensures chunks don't grow unboundedly
9. **Audio Format Pipeline**: All audio normalized to 16kHz mono Float32 before diarization via AudioConverter
10. **Zero-Gap Rotation**: StreamingMicRecorder rotates files without dropping samples between chunks

### Known Limitations & Future Work

- No speaker enrollment (pre-recorded sample matching) yet
- Speaker IDs reset between meetings (no persistent profiles across sessions)
- Batch system diarization may re-identify speakers already seen in chunks (potential duplication)
- No UI for manual speaker correction/merging
- Overlapping speech not yet supported in pyannote model
- Limited to pyannote/speaker-diarization-3.1 model (no custom models support)

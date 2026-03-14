# Muesli

Local-first macOS app that combines **dictation** (WisprFlow replacement) and **meeting transcription** (Granola replacement). One on-device STT model serves both use cases. Native Swift/AppKit, not Electron.

## Project Thesis

Speech-to-text is the common modality. Dictation and meetings share the same audio capture, the same transcription engine, and the same storage layer. Muesli unifies them in one lightweight native app with zero cloud STT costs — all transcription runs on Apple Silicon (WhisperKit on CoreML/Neural Engine, or mlx-whisper as fallback).

## Repo Layout

```
.
├── native/MuesliNative/          # PRIMARY — Native Swift/AppKit app (SwiftPM package)
│   ├── Sources/MuesliNativeApp/  # Main app (24 Swift files)
│   └── Sources/MuesliSystemAudio/# Standalone system audio capture binary
├── bridge/                       # Python worker for Swift↔Python IPC (JSON over stdin/stdout)
│   ├── worker.py                 # Long-running subprocess spawned by Swift app
│   └── paste_text.py             # Legacy paste helper (superseded by PasteController.swift)
├── audio/                        # Python audio capture (mic via sounddevice, system via ScreenCaptureKit)
├── transcribe/                   # Python STT backends (mlx-whisper, Qwen) and engine singleton
├── dictation/                    # Python hotkey (pynput) and paste (pyperclip + pynput Cmd+V)
├── meeting/                      # Python meeting session, transcript merge, LLM summary
├── storage/                      # Python SQLite persistence and stats queries
├── cal_monitor/                  # Python EventKit calendar polling
├── ui/                           # Python PyObjC UI (legacy path, replaced by native Swift UI)
├── app.py                        # Python-only app entry (legacy path)
├── main.py                       # Python-only entry point (legacy path)
├── config.py                     # Shared JSON config at ~/Library/Application Support/Muesli/config.json
├── scripts/                      # Build, signing, notarization shell scripts
├── assets/                       # App icon, menu bar icon, bundled Inter fonts
├── research/                     # Competitive research (extracted Granola recipe prompts)
├── tests/                        # Python unit tests (33 tests, pytest)
├── Context/                      # Session handoff documents
└── setup.py                      # py2app packaging (legacy Python-only .app path)
```

## Active Branch

`coreml-swift` — the native Swift app with WhisperKit/CoreML transcription. This is the primary development branch. `main` has the older Python-only version.

## Building & Running

### Native Swift app (primary)
```bash
# Build and install to /Applications/Muesli.app
./scripts/build_native_app.sh

# Or build only (output in dist-native/)
swift build --package-path native/MuesliNative -c release --product MuesliNativeApp
swift build --package-path native/MuesliNative -c release --product MuesliSystemAudio
```

### Python legacy path
```bash
python main.py
```

### Tests
```bash
pytest tests/
```

## Architecture

### Native Swift App (`native/MuesliNative/Sources/MuesliNativeApp/`)

The Swift app is the primary target. Key files:

| File | Role |
|---|---|
| `MuesliController.swift` | Central orchestrator (`@MainActor`). Owns all subsystems. |
| `HotkeyMonitor.swift` | Left Cmd hold-to-record via `NSEvent` global/local monitors. Key code 55 = Left Cmd. |
| `MicrophoneRecorder.swift` | `AVAudioRecorder` wrapper. Records 16kHz/16-bit mono WAV to temp file. |
| `SystemAudioRecorder.swift` | Launches `MuesliSystemAudio` as subprocess, sends SIGINT to stop. |
| `TranscriptionRuntime.swift` | Routes to `WhisperKitSpeechBackend` (native) or `LegacyPythonSpeechBackend`. |
| `TranscriptionCoordinator` (in TranscriptionRuntime.swift) | Actor that manages backend lifecycle, preloading, and dispatch. |
| `PasteController.swift` | Clipboard + CGEvent Cmd+V simulation (no Python dependency). |
| `MeetingSession.swift` | Meeting lifecycle: start mic+system → stop → transcribe both → merge → summarize → store. |
| `MeetingSummaryClient.swift` | Async URLSession to OpenAI or OpenRouter for meeting notes. |
| `TranscriptFormatter.swift` | Merges mic ("You") + system ("Others") segments by timestamp. |
| `DictationStore.swift` | Direct SQLite3 C API bindings. Shared DB with Python side. |
| `ConfigStore.swift` | Reads/writes `~/Library/Application Support/Muesli/config.json`. |
| `Models.swift` | `BackendOption`, `TranscriptionRuntimeOption`, `MeetingSummaryBackendOption` enums. |
| `StatusBarController.swift` | NSStatusBar menu with all controls/submenus. |
| `RecentHistoryWindowController.swift` | Dashboard: Dictations tab (table) + Meetings tab (Notes-style split view). |
| `FloatingIndicatorController.swift` | Floating pill indicator with animated state transitions. |
| `PythonWorkerClient.swift` | Spawns `bridge/worker.py`, sends JSON requests over stdin, reads responses from stdout. |
| `RuntimePaths.swift` | Resolves Python venv, worker script, system audio binary at startup. |
| `AppFonts.swift` | Registers bundled Inter fonts from app resources. |

### MuesliSystemAudio (`native/MuesliNative/Sources/MuesliSystemAudio/main.swift`)

Separate binary. Uses `AudioHardwareCreateProcessTap` (macOS 14.2+) to capture all system audio. Writes 16kHz 16-bit mono PCM to a WAV file. Runs until SIGINT.

### Transcription Backends

| Backend | Runtime | Engine | Hardware | Config value |
|---|---|---|---|---|
| WhisperKit | Native Swift | CoreML | CPU+GPU+Neural Engine | `native` runtime, `whisper` backend |
| mlx-whisper | Python worker | MLX | CPU+GPU | `legacy_python` runtime, `whisper` backend |
| Qwen ASR | Python worker | MLX | CPU+GPU | `legacy_python` runtime, `qwen` backend |

Qwen has no native WhisperKit equivalent (`nativeModel: nil` in Models.swift), so it always falls back to the Python worker.

### Swift ↔ Python Bridge

`PythonWorkerClient.swift` spawns `bridge/worker.py` as a subprocess. Communication is newline-delimited JSON over stdin/stdout:

```
Swift→Python: {"id":"uuid","method":"transcribe_file","params":{"wav_path":"...","backend":"whisper"}}
Python→Swift: {"id":"uuid","ok":true,"result":{"text":"Hello world"}}
```

Methods: `ping`, `preload_backend`, `transcribe_file`, `shutdown`.

## End-to-End Flows

### Dictation (hold Left Cmd → text at cursor)

1. Left Cmd held 150ms → `HotkeyMonitor.onPrepare` → `MicrophoneRecorder.prepare()` (pre-arms recorder)
2. 250ms → `HotkeyMonitor.onStart` → `recorder.start()` → indicator turns red "Listening"
3. Left Cmd released → `HotkeyMonitor.onStop` → `recorder.stop()` → WAV URL
4. If duration < 0.3s → discard
5. `TranscriptionCoordinator.transcribeDictation(wavURL)` → WhisperKit or Python worker
6. `DictationStore.insertDictation(text, duration, ...)`
7. `PasteController.paste(text)` → clipboard + Cmd+V into previously active app

If another key is pressed while Cmd is held (e.g. Cmd+C), dictation is cancelled — it's a keyboard shortcut, not dictation.

### Meeting Transcription (manual start/stop → structured notes)

1. User clicks "Start Meeting Recording" in status bar menu
2. `MicrophoneRecorder.start()` → records "You" audio to temp WAV
3. `SystemAudioRecorder.start()` → spawns `MuesliSystemAudio` → records "Others" to WAV
4. User clicks "Stop" → mic stops, SIGINT sent to system audio process
5. Both WAVs transcribed via WhisperKit → timestamped segments
6. `TranscriptFormatter.merge()` → `[HH:MM:SS] You: ... / [HH:MM:SS] Others: ...`
7. `MeetingSummaryClient.summarize()` → POST to OpenAI/OpenRouter → markdown notes
8. Stored in SQLite `meetings` table, viewable in Notes-style UI

## Storage

SQLite at `~/Library/Application Support/Muesli/muesli.db` (WAL mode). Shared between Python and Swift.

- `dictations` table: timestamp, duration, raw_text, word_count, app_context
- `meetings` table: title, start/end time, raw_transcript, formatted_notes, audio paths, word_count

## Config

JSON at `~/Library/Application Support/Muesli/config.json`. Key fields:
- `stt_backend`: `"whisper"` | `"qwen"`
- `stt_model`: model repo string
- `transcription_runtime`: `"native"` | `"legacy_python"`
- `meeting_summary_backend`: `"openai"` | `"openrouter"`
- `openai_api_key`, `openrouter_api_key`, `openai_model`, `openrouter_model`
- `show_floating_indicator`, `open_dashboard_on_launch`, `auto_record_meetings`

## macOS Permissions Required

- **Microphone**: AVAudioRecorder (dictation + meeting mic)
- **Accessibility**: CGEvent paste simulation (Cmd+V into other apps)
- **Input Monitoring**: NSEvent global key monitors (hotkey detection)
- **Screen Recording**: AudioHardwareCreateProcessTap (system audio capture)
- **Calendar**: EKEventStore (auto-detect upcoming meetings)

## Signing & Distribution

- Developer ID: `Pranav Hari Guruvayurappan (58W55QJ567)`
- Bundle ID: `com.muesli.app`
- Canonical install path: `/Applications/Muesli.app`
- Notary profile in Keychain: `MuesliNotary`
- Notarization not yet passing — needs hardened runtime (`--options runtime`) and proper signing of nested `MuesliSystemAudio` binary

## Known Issues

- Notarization fails: main binary and `MuesliSystemAudio` need hardened runtime and secure timestamps. `MuesliSystemAudio` also has `com.apple.security.get-task-allow` (debug entitlement) that must be removed for release.
- Swift build warnings: `lastExternalApp` actor isolation in `MuesliController.swift`, deprecated `activateIgnoringOtherApps` in preferences/history windows.
- Status bar icon can intermittently not appear while the floating indicator is alive (AppKit status item flakiness).
- Qwen backend only works via Python worker (no WhisperKit equivalent).

## Development Notes

- **Do not create duplicate app bundles** with the same bundle ID. Only `/Applications/Muesli.app` should exist for testing. Multiple bundles cause TCC permission confusion.
- The Python side (`app.py`, `main.py`, `ui/`) is the legacy path. New feature work goes into the native Swift app.
- `bridge/worker.py` is still actively used when `transcription_runtime` is `legacy_python` or backend is `qwen`.
- WhisperKit model is downloaded on first use from `argmaxinc/whisperkit-coreml`. Model name configurable per `BackendOption.nativeModel`.
- The `research/granola-all-recipes.json` file contains 47 Granola recipe prompt templates — useful reference for improving meeting summary prompts.

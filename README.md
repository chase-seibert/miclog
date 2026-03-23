# miclog

Real-time microphone transcription tool for macOS using whisper.cpp. Never worry about whether you have authorization to record a meeting or enable AI summaries in your meeting app again!

## Prerequisites

### 1. Install Xcode Command Line Tools
```bash
xcode-select --install
```

### 2. Install whisper.cpp
```bash
brew install whisper-cpp
# This installs the whisper-cli executable
```

### 3. Download Whisper Large Model

```bash
# Create models directory
mkdir -p .whisper-models

# Download large model (~3GB)
curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin -o .whisper-models/ggml-large-v3.bin
```

The tool will search for the model at:
- `.whisper-models/ggml-large-v3.bin` (recommended - in project directory)
- `~/.whisper/models/ggml-large-v3.bin`
- `/opt/homebrew/share/whisper-cpp/models/ggml-large-v3.bin`
- `/usr/local/share/whisper-cpp/models/ggml-large-v3.bin`

## Build

```bash
make
```

## Usage

### Basic Usage (stdout)
```bash
# Transcribe to stdout until Ctrl+C
./miclog

# Transcribe for 30 seconds
./miclog --test 30

# Save to file (shell redirection)
./miclog > transcript.txt
```

### Examples

```bash
# Basic transcription to terminal
./miclog

# Save to file
./miclog >> daily_log.txt

# Test mode (exist after 5 seconds)
./miclog --test 5

# Output to both console AND file (live viewing while saving)
./miclog 2>&1 | tee -a ~/miclog.txt
```

### Example Output

```
[2026-03-09 15:05:03] Okay, I am now testing audio transcription.
[2026-03-09 15:05:08] I'm waiting for it to print something to the screen.
[2026-03-09 15:05:13] Oh my god, I cannot believe this is working.
```

Each line shows a timestamp followed by the transcribed text from that 5-second audio chunk.

## Use Case: Meeting Transcription

Here's a practical workflow for transcribing and summarizing meetings:

1. **Start transcription** before your meeting:
   ```bash
   ./miclog
   ```

2. **After the meeting ends**, select all transcript text in the terminal:
   - Press `Command + A` to select all
   - Press `Command + C` to copy to clipboard
   - Press `Command + K` to clear the terminal (ready for next meeting)

3. **Generate AI summary**:
   - Paste the transcript into ChatGPT (or Claude)
   - Ask: "Please summarize this meeting transcript"

This produces a very readable AI summary of your meeting with key points, action items, and decisions.

**Tip**: You can also redirect to a file and keep a daily log:
```bash
./miclog >> meetings_$(date +%Y-%m-%d).txt
```

## How It Works

1. Records audio in 5-second chunks (WAV format, 16kHz)
2. Transcribes each chunk with whisper.cpp (large model)
3. Streams transcription to stdout as chunks complete
4. ~5-10 second latency per chunk (recording + transcription time)
5. Temporary chunk files are automatically cleaned up

## Performance

- **Latency**: ~5-10 seconds per chunk (depends on CPU)
- **Accuracy**: High (large model)
- **Disk space**: Minimal (chunks deleted after transcription)
- **Memory**: ~1-2GB (model loaded in memory)

Large model transcription is CPU-intensive (~1x realtime on modern Macs). For faster results, consider using a smaller model by editing the `modelPath` search in `main.swift`.

## Troubleshooting

### "whisper-cli not found"
Install with: `brew install whisper-cpp` (this installs the `whisper-cli` executable)

Verify installation: `which whisper-cli` should show `/opt/homebrew/bin/whisper-cli`

### "Model not found"
Download the large model (see Prerequisites above). The tool searches multiple locations automatically.

### "Permission denied"
It should prompt for for this automatically on first run. Allow microphone access in **System Settings → Privacy & Security → Microphone**

### Slow transcription
The large model is slow but accurate. For faster results:
1. Download a smaller model (medium, small, or base)
2. Update the search paths in `main.swift` to use the smaller model
3. Or edit `findModelPath()` to return your preferred model path

### No output appearing
- Status messages go to stderr, transcription to stdout
- Redirect stderr to see status: `./miclog 2> status.log`
- Or combine: `./miclog > transcript.txt 2> status.log`

## Technical Details

- **Audio format**: 16kHz WAV, mono, 16-bit PCM
- **Chunk size**: 5 seconds (~800KB per chunk)
- **Chunk location**: `/tmp/miclog_chunk_*.wav`
- **Model**: Whisper large (~3GB)
- **Output**: Stdout (status messages to stderr)

## Development

See [CLAUDE.md](CLAUDE.md) for development commands and architecture details.

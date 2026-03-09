import Foundation
import AVFoundation

class ChunkedRecorder: NSObject, AVAudioRecorderDelegate {
    private var currentRecorder: AVAudioRecorder?
    private var chunkIndex = 0
    private var chunkTimer: Timer?
    private var testTimer: Timer?
    private let transcriptionQueue = DispatchQueue(label: "com.miclog.transcription")
    private var pendingChunks: [String] = []
    private var isRecording = false
    private var isTranscribing = false
    private let dateFormatter: DateFormatter
    private var startTime: Date?
    private let chunkDuration: TimeInterval = 5.0
    private let whisperPath: String?
    private let modelPath: String?

    override init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Find whisper-cpp executable
        self.whisperPath = ChunkedRecorder.findWhisperPath()

        // Find large model
        self.modelPath = ChunkedRecorder.findModelPath()

        super.init()
    }

    static func findWhisperPath() -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
            "/opt/homebrew/bin/main", // whisper.cpp compiled binary name
            "/usr/local/bin/main"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try using 'which' for whisper-cli first
        for binary in ["whisper-cli", "whisper-cpp"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [binary]

            let pipe = Pipe()
            process.standardOutput = pipe

            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    return path
                }
            }
        }

        return nil
    }

    static func findModelPath() -> String? {
        let currentDir = FileManager.default.currentDirectoryPath
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let possiblePaths = [
            "\(currentDir)/.whisper-models/ggml-large-v3.bin",
            "\(homeDir)/.whisper/models/ggml-large-v3.bin",
            "/opt/homebrew/share/whisper-cpp/models/ggml-large-v3.bin",
            "/usr/local/share/whisper-cpp/models/ggml-large-v3.bin"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    func checkPrerequisites() -> Bool {
        guard let _ = whisperPath else {
            print("Error: whisper-cli not found")
            print("")
            print("Install with: brew install whisper-cpp")
            print("(This installs the whisper-cli executable)")
            print("")
            print("Or build from source: https://github.com/ggerganov/whisper.cpp")
            return false
        }

        guard let _ = modelPath else {
            print("Error: Whisper large model not found")
            print("")
            print("Download with:")
            print("  mkdir -p .whisper-models")
            print("  curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin -o .whisper-models/ggml-large-v3.bin")
            print("")
            print("Or use whisper.cpp model downloader:")
            print("  bash /opt/homebrew/Cellar/whisper-cpp/*/models/download-ggml-model.sh large")
            return false
        }

        return true
    }

    func startRecording(duration: TimeInterval? = nil) -> Bool {
        guard checkPrerequisites() else {
            return false
        }

        isRecording = true
        isTranscribing = true
        startTime = Date()

        // Start first chunk
        if !startNewChunk() {
            return false
        }

        // Setup chunk rotation timer
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            self?.rotateChunk()
        }

        // Setup test mode timer if specified
        if let duration = duration {
            print("Recording for \(Int(duration)) seconds...", to: &standardError)
            testTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.stopRecording()
            }
        } else {
            print("Recording... (Press Ctrl+C to stop)", to: &standardError)
        }

        return true
    }

    private func startNewChunk() -> Bool {
        let chunkPath = "/tmp/miclog_chunk_\(chunkIndex).wav"
        let audioURL = URL(fileURLWithPath: chunkPath)

        // WAV format settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0, // 16kHz optimal for whisper
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            currentRecorder = try AVAudioRecorder(url: audioURL, settings: settings)
            currentRecorder?.delegate = self
            currentRecorder?.prepareToRecord()

            let success = currentRecorder?.record() ?? false
            if !success {
                print("Error: Failed to start recording chunk", to: &standardError)
                return false
            }

            return true
        } catch {
            print("Error starting chunk: \(error.localizedDescription)", to: &standardError)
            return false
        }
    }

    private func rotateChunk() {
        guard isRecording else { return }

        // Stop current recorder
        currentRecorder?.stop()

        // Add completed chunk to transcription queue
        let chunkPath = "/tmp/miclog_chunk_\(chunkIndex).wav"
        pendingChunks.append(chunkPath)

        // Process transcription in background
        transcriptionQueue.async { [weak self] in
            self?.processNextChunk()
        }

        // Start next chunk
        chunkIndex += 1
        _ = startNewChunk()
    }

    private func processNextChunk() {
        guard let chunkPath = pendingChunks.first else { return }
        pendingChunks.removeFirst()

        transcribeChunk(chunkPath)

        // Process next chunk if available
        if !pendingChunks.isEmpty {
            processNextChunk()
        } else if !isRecording {
            // All chunks processed and recording stopped
            DispatchQueue.main.async { [weak self] in
                self?.isTranscribing = false
                self?.printStats()
                exit(0)
            }
        }
    }

    private func transcribeChunk(_ path: String) {
        guard let whisperPath = whisperPath, let modelPath = modelPath else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", modelPath,
            "-np", // No prints (only output transcription)
            "-nt", // No timestamps in output
            path   // Input file
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let timestamp = dateFormatter.string(from: Date())
                        print("[\(timestamp)] \(trimmed)")
                        fflush(stdout)
                    }
                }
            }

            // Clean up chunk file
            try? FileManager.default.removeItem(atPath: path)
        } catch {
            print("Error transcribing chunk: \(error.localizedDescription)", to: &standardError)
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        chunkTimer?.invalidate()
        testTimer?.invalidate()

        // Stop current recorder and add final chunk
        currentRecorder?.stop()
        let finalChunkPath = "/tmp/miclog_chunk_\(chunkIndex).wav"
        pendingChunks.append(finalChunkPath)

        print("", to: &standardError)
        print("Recording stopped. Processing remaining chunks...", to: &standardError)

        // Process remaining chunks
        transcriptionQueue.async { [weak self] in
            self?.processNextChunk()
        }
    }

    private func printStats() {
        if let startTime = startTime {
            let duration = Date().timeIntervalSince(startTime)
            print("Duration: \(String(format: "%.1f", duration))s", to: &standardError)
        }
    }
}

// Utility to write to stderr
var standardError = FileHandle.standardError

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            self.write(data)
        }
    }
}

func printUsage() {
    print("Usage: miclog [--test SECONDS]", to: &standardError)
    print("", to: &standardError)
    print("Options:", to: &standardError)
    print("  --test SECONDS    Record for specified seconds and exit", to: &standardError)
    print("", to: &standardError)
    print("Output is written to stdout. Use shell redirection to save:", to: &standardError)
    print("  ./miclog > transcript.txt", to: &standardError)
    print("", to: &standardError)
    print("Examples:", to: &standardError)
    print("  ./miclog                    # Transcribe to stdout until Ctrl+C", to: &standardError)
    print("  ./miclog --test 30          # Transcribe for 30 seconds", to: &standardError)
    print("  ./miclog > output.txt       # Save transcript to file", to: &standardError)
}

// Parse command line arguments
var testDuration: TimeInterval? = nil
var args = Array(CommandLine.arguments.dropFirst())

if args.contains("--help") || args.contains("-h") {
    printUsage()
    exit(0)
}

if let testIndex = args.firstIndex(of: "--test") {
    let nextIndex = args.index(after: testIndex)
    guard nextIndex < args.endIndex else {
        print("Error: --test requires a duration in seconds", to: &standardError)
        printUsage()
        exit(1)
    }

    guard let seconds = TimeInterval(args[nextIndex]) else {
        print("Error: Invalid duration '\(args[nextIndex])'", to: &standardError)
        printUsage()
        exit(1)
    }

    testDuration = seconds
}

let recorder = ChunkedRecorder()

// Setup signal handler for Ctrl+C
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    recorder.stopRecording()
}
signal(SIGINT, SIG_IGN)
signalSource.resume()

// Start recording
if recorder.startRecording(duration: testDuration) {
    RunLoop.main.run()
} else {
    exit(1)
}

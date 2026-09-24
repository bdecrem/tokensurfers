import Foundation
import AVFoundation
import Speech
import Observation

/// Hold-to-talk dictation for the composer: press to open the mic, the words
/// stream into `transcript`, release to get the final text.
///
/// Built to feel instant. Permissions already granted cost nothing on the way
/// to the mic (no prompt, no hop; the prompts come once, on the first hold);
/// the recognizer runs on the phone when it can (the first words land a few
/// hundred ms in, and the final result comes right after release instead of
/// after a round trip to Apple); the recognition task is armed before the
/// engine starts, so the first word is never dropped. `[voice]` lines in the
/// console carry the timings.
@Observable
@MainActor
final class VoiceInput {
    private(set) var listening = false
    /// The finger is down but the mic isn't open yet (session switch, permissions).
    private(set) var opening = false
    private(set) var transcript = ""
    /// Set when the mic or speech permission is missing, for an alert.
    var problem: String?

    /// A fresh engine per hold: one that outlived a category flip kept a stale input format.
    private var engine: AVAudioEngine?
    /// Made on the first hold, not with the Studio, so opening a project can
    /// never be what asks for the speech permission.
    @ObservationIgnored private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var gotFinal = false
    /// The finger is still down. A release during the permission prompt stops right after start.
    private var wanted = false
    private var warmed = false
    private var onDevice = false

    /// While the Studio opens: a line in the console with the state of things.
    /// The permission prompts stay on the first hold of the mic (in context,
    /// once per install); after that a hold never waits on them. Nothing here
    /// touches the recognizer.
    func warmUp() {
        guard !warmed else { return }
        warmed = true
        let speech = ["not asked", "denied", "restricted", "authorized"][SFSpeechRecognizer.authorizationStatus().rawValue]
        let mic = AVAudioApplication.shared.recordPermission == .granted ? "granted" : AVAudioApplication.shared.recordPermission == .denied ? "denied" : "not asked"
        print("[voice] warm: speech \(speech), mic \(mic)")
    }

    func start() async {
        wanted = true
        guard !listening, !opening else { return }
        opening = true
        defer { opening = false }
        let t0 = Date()
        guard await Self.authorize() else {
            problem = "Token Surfers needs the microphone and speech recognition to hear you. Turn them on in Settings."
            wanted = false
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            wanted = false
            return
        }
        guard wanted else { return }

        onDevice = recognizer.supportsOnDeviceRecognition
        SurfAudio.shared.setRecording(true)
        let tSession = Date()
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.engine = nil
            SurfAudio.shared.setRecording(false)
            problem = "No microphone found."
            wanted = false
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if onDevice { req.requiresOnDeviceRecognition = true }
        request = req
        transcript = ""
        gotFinal = false
        // armed before any audio flows: buffers queue in the request, nothing is dropped
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty { self.transcript = text }
                if final || error != nil { self.gotFinal = true }
                if let error, !final { print("[voice] recognizer: \(error.localizedDescription)") }
            }
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            task?.cancel(); task = nil; request = nil
            self.engine = nil
            SurfAudio.shared.setRecording(false)
            problem = "The microphone didn't start: \(error.localizedDescription)"
            wanted = false
            return
        }
        listening = true
        print("[voice] open in \(Self.ms(since: t0)) ms (session \(Self.ms(since: t0, to: tSession)) ms, \(onDevice ? "on-device" : "server"))")
        if !wanted { _ = await stop() }
    }

    /// Close the mic and return what was said (waits a moment for the final result).
    func stop() async -> String {
        wanted = false
        guard listening else { return "" }
        let t0 = Date()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        request?.endAudio()
        // on the phone the final result lands within a couple hundred ms; the server takes longer
        let deadline = Date().addingTimeInterval(onDevice ? 0.9 : 1.5)
        while !gotFinal && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        task?.cancel()
        task = nil
        request = nil
        listening = false
        SurfAudio.shared.setRecording(false)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        print("[voice] closed in \(Self.ms(since: t0)) ms, final \(gotFinal), \(text.count) chars")
        return text
    }

    func cancel() async {
        _ = await stop()
    }

    /// Transcribe an audio file with the same recognizer (the simulator hook
    /// `TS_HEAR`, so the voice path can be checked without a finger on the mic).
    func transcribe(file url: URL) async -> String {
        guard await Self.authorizeSpeech(), let recognizer else {
            print("[voice] speech recognition not authorized (\(SFSpeechRecognizer.authorizationStatus().rawValue))")
            return ""
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.addsPunctuation = true
        return await withCheckedContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    print("[voice] recognizer error: \(error.localizedDescription)")
                    done = true
                    cont.resume(returning: "")
                }
            }
        }
    }

    private static func ms(since a: Date, to b: Date = Date()) -> Int { Int(b.timeIntervalSince(a) * 1000) }

    private static func authorizeSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Both permissions. Already granted (the usual case) costs nothing: no prompt, no hop.
    private static func authorize() async -> Bool {
        guard await authorizeSpeech() else { return false }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

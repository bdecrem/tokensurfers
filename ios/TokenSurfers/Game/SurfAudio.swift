import AVFoundation
import CoreAudio

/// Synthesized sound for Token Surfers: a chiptune loop (kick, snare, hats,
/// a square bass and a lead) whose tempo follows the run, plus one-shot
/// effects. One AVAudioSourceNode; everything is rendered in the callback.
final class SurfAudio {
    static let shared = SurfAudio()

    // MARK: one-shot voices

    private struct Voice {
        var freq: Double
        var freqEnd: Double
        var dur: Double
        var t: Double = 0          // negative = delayed start
        var gain: Double
        var noise: Double = 0      // 0 tone .. 1 noise
        var wave: Wave = .sine
        var lp: Double = 1         // one-pole lowpass coefficient (1 = off)
        var phase: Double = 0
        var lpState: Double = 0
        var attack: Double = 0.004
        var curve: Double = 2      // decay shape
    }
    enum Wave { case sine, square, saw, tri }

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private var voices: [Voice] = []
    private let lock = NSLock()
    private var sampleRate = 44100.0
    private var noiseState: UInt32 = 22222
    private var started = false
    private var coinStep = 0

    // MARK: music

    /// 0 = silent, 1 = full. Set by the screens (fades over ~0.4 s).
    var musicTarget = 0.0
    /// The mic is open (hold-to-talk): music drops way down.
    private(set) var listening = false
    /// 0..1 from the engine's speed; tempo runs 128..150 BPM.
    var pace = 0.0
    private var musicLevel = 0.0
    private var stepSamples = 0.0
    private var sampleInStep = 0.0
    private var step = 0
    private var bar = 0
    private var duck = 1.0
    private var kick = Voice(freq: 150, freqEnd: 42, dur: 0.26, gain: 0, wave: .sine, curve: 1.6)
    private var snare = Voice(freq: 190, freqEnd: 140, dur: 0.16, gain: 0, noise: 0.75, curve: 1.8)
    private var hat = Voice(freq: 8000, freqEnd: 8000, dur: 0.03, gain: 0, noise: 1, curve: 1.5)
    private var bass = Voice(freq: 110, freqEnd: 110, dur: 0.22, gain: 0, wave: .square, lp: 0.12, curve: 1.3)
    private var lead = Voice(freq: 440, freqEnd: 440, dur: 0.24, gain: 0, wave: .square, lp: 0.35, curve: 1.2)
    private var arp = Voice(freq: 880, freqEnd: 880, dur: 0.1, gain: 0, wave: .tri, lp: 0.5, curve: 1.2)

    // I–V–vi–IV in C, 16 steps a bar. Bass roots in MIDI, lead in semitones from C5.
    private static let roots: [Double] = [48, 43, 45, 41]
    private static let bassPattern: [Int?] = [0, nil, 12, 0, nil, 7, nil, 12, 0, nil, 12, 0, nil, 7, 12, nil]
    private static let leadBars: [[Int?]] = [
        [0, nil, 4, nil, 7, nil, 12, nil, 7, nil, 4, nil, 7, nil, nil, nil],
        [-1, nil, 2, nil, 7, nil, 11, nil, 7, nil, 2, nil, 7, nil, nil, nil],
        [-3, nil, 0, nil, 4, nil, 9, nil, 4, nil, 0, nil, 4, nil, 7, nil],
        [-7, nil, 0, nil, 5, nil, 9, nil, 12, nil, 9, nil, 5, nil, 0, nil],
    ]
    private static let arpNotes: [[Int]] = [[0, 4, 7], [-1, 2, 7], [-3, 0, 4], [-7, 0, 5]]

    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "muted") }
        set { UserDefaults.standard.set(newValue, forKey: "muted") }
    }
    var musicOn: Bool {
        get { UserDefaults.standard.object(forKey: "music") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "music") }
    }

    func start() {
        guard !started else { return }
        started = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44100 }
        stepSamples = sampleRate * 60 / (132 * 4)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(out, Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.6
        try? engine.start()
        // The category flip for hold-to-talk (and a phone call, or AirPods coming
        // and going) rebuilds the engine's graph and stops it; bring it back.
        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.resume()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.resume()
        }
    }

    private func resume() {
        guard started, !engine.isRunning else { return }
        try? engine.start()
    }

    /// Hold-to-talk needs the mic: switch the session to play-and-record (the
    /// game keeps playing, ducked) and back to ambient after.
    func setRecording(_ on: Bool) {
        listening = on
        let session = AVAudioSession.sharedInstance()
        if on {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        } else {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
        if started, !engine.isRunning { try? engine.start() }
    }

    // MARK: effects

    func play(_ s: SurfSound) {
        guard !muted else { return }
        if !started { start() }
        var add: [Voice] = []
        switch s {
        case .coin:
            coinStep = (coinStep + 1) % 8
            let base = 1046.5 * pow(2, Double([0, 2, 4, 5, 7, 9, 11, 12][coinStep]) / 12)
            add = [Voice(freq: base, freqEnd: base, dur: 0.07, gain: 0.14, wave: .square, lp: 0.6),
                   Voice(freq: base * 1.5, freqEnd: base * 1.5, dur: 0.14, t: -0.05, gain: 0.11, wave: .square, lp: 0.6)]
        case .jump:
            add = [Voice(freq: 240, freqEnd: 980, dur: 0.16, gain: 0.16, wave: .tri, curve: 1.2),
                   Voice(freq: 3000, freqEnd: 800, dur: 0.12, gain: 0.05, noise: 1, lp: 0.3)]
        case .land:
            add = [Voice(freq: 110, freqEnd: 50, dur: 0.08, gain: 0.22),
                   Voice(freq: 500, freqEnd: 200, dur: 0.05, gain: 0.05, noise: 1, lp: 0.2)]
        case .roofLand:
            add = [Voice(freq: 1200, freqEnd: 900, dur: 0.06, gain: 0.12, wave: .square, lp: 0.7),
                   Voice(freq: 2400, freqEnd: 2300, dur: 0.18, gain: 0.07, wave: .sine),
                   Voice(freq: 140, freqEnd: 60, dur: 0.1, gain: 0.2)]
        case .roll:
            add = [Voice(freq: 900, freqEnd: 200, dur: 0.16, gain: 0.09, noise: 0.85, lp: 0.25)]
        case .swipe:
            add = [Voice(freq: 1200, freqEnd: 600, dur: 0.06, gain: 0.05, noise: 0.9, lp: 0.3)]
        case .bump:
            add = [Voice(freq: 320, freqEnd: 110, dur: 0.16, gain: 0.22, wave: .square, lp: 0.3),
                   Voice(freq: 800, freqEnd: 300, dur: 0.12, gain: 0.12, noise: 1, lp: 0.3)]
        case .crash:
            add = [Voice(freq: 420, freqEnd: 60, dur: 0.5, gain: 0.3, wave: .saw, lp: 0.25, curve: 1.2),
                   Voice(freq: 1500, freqEnd: 300, dur: 0.35, gain: 0.25, noise: 1, lp: 0.2),
                   Voice(freq: 196, freqEnd: 196, dur: 0.3, t: -0.45, gain: 0.16, wave: .square, lp: 0.2, curve: 0.8),
                   Voice(freq: 185, freqEnd: 185, dur: 0.6, t: -0.8, gain: 0.16, wave: .square, lp: 0.2, curve: 0.8)]
        case .stomp:
            add = [Voice(freq: 520, freqEnd: 140, dur: 0.12, gain: 0.22, wave: .sine),
                   Voice(freq: 900, freqEnd: 400, dur: 0.08, gain: 0.1, noise: 1, lp: 0.3)]
        case .streak:
            add = [Voice(freq: 784, freqEnd: 784, dur: 0.09, gain: 0.14, wave: .square, lp: 0.5),
                   Voice(freq: 1175, freqEnd: 1175, dur: 0.16, t: -0.09, gain: 0.14, wave: .square, lp: 0.5)]
        case .celebrate:
            add = [0, 4, 7, 12, 16].enumerated().map { i, st in
                let f = 523.25 * pow(2, Double(st) / 12)
                return Voice(freq: f, freqEnd: f, dur: 0.2, t: -Double(i) * 0.08, gain: 0.13, wave: .square, lp: 0.5)
            }
        case .gameOver:
            add = [0, -1, -3, -5].enumerated().map { i, st in
                let f = 392 * pow(2, Double(st) / 12)
                return Voice(freq: f, freqEnd: f, dur: i == 3 ? 0.5 : 0.22, t: -Double(i) * 0.2, gain: 0.14, wave: .square, lp: 0.3, curve: 0.9)
            }
        case .tick:
            add = [Voice(freq: 2000, freqEnd: 2000, dur: 0.015, gain: 0.05)]
        }
        lock.lock()
        voices.append(contentsOf: add)
        if voices.count > 24 { voices.removeFirst(voices.count - 24) }
        lock.unlock()
    }

    // MARK: rendering

    private func noise() -> Double {
        noiseState = noiseState &* 1664525 &+ 1013904223
        return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
    }

    /// One sample of a voice; advances it.
    private func tick(_ v: inout Voice, dt: Double) -> Double {
        v.t += dt
        guard v.t >= 0, v.t < v.dur else { return 0 }
        let k = v.t / v.dur
        let f = v.freq * pow(v.freqEnd / v.freq, k)
        v.phase += f * dt
        if v.phase > 1 { v.phase -= 1 }
        let tone: Double
        switch v.wave {
        case .sine: tone = sin(v.phase * 2 * .pi)
        case .square: tone = (v.phase < 0.5 ? 1.0 : -1.0) * 0.5
        case .saw: tone = (v.phase * 2 - 1) * 0.6
        case .tri: tone = (abs(v.phase * 4 - 2) - 1) * 0.8
        }
        var s = tone * (1 - v.noise) + noise() * v.noise
        if v.lp < 1 {
            v.lpState += (s - v.lpState) * v.lp
            s = v.lpState
        }
        let env = min(1, v.t / v.attack) * pow(1 - k, v.curve)
        return s * env * v.gain
    }

    private func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        let dt = 1.0 / sampleRate
        let wantMusic = (musicOn && !muted ? musicTarget : 0) * (listening ? 0.12 : 1)
        let bpm = 128 + pace * 22
        stepSamples = sampleRate * 60 / (bpm * 4)

        for i in 0..<n {
            var mix = 0.0
            for v in voices.indices { mix += tick(&voices[v], dt: dt) }

            // music
            musicLevel += (wantMusic - musicLevel) * 0.00004
            if musicLevel > 0.002 {
                sampleInStep += 1
                if sampleInStep >= stepSamples {
                    sampleInStep -= stepSamples
                    step = (step + 1) % 16
                    if step == 0 { bar = (bar + 1) % 8 }
                    sequence()
                }
                duck += (1 - duck) * 0.0004
                var m = tick(&kick, dt: dt) * 1.4
                m += tick(&snare, dt: dt)
                m += tick(&hat, dt: dt)
                m += (tick(&bass, dt: dt) + tick(&lead, dt: dt) + tick(&arp, dt: dt)) * duck
                mix += m * musicLevel * 0.8
            }

            // soft clip
            let x = mix
            out[i] = Float(x < -1 ? -0.9 : (x > 1 ? 0.9 : x - x * x * x * 0.15))
        }
        voices.removeAll { $0.t >= $0.dur }
    }

    /// Fires the voices for the current step.
    private func sequence() {
        let chord = bar % 4
        func hit(_ v: inout Voice, freq: Double, gain: Double, dur: Double? = nil) {
            v.t = 0; v.phase = 0; v.lpState = 0
            v.freq = freq; v.freqEnd = v.wave == .sine && v.dur > 0.2 ? v.freqEnd : freq
            v.gain = gain
            if let dur { v.dur = dur }
        }
        if step % 4 == 0 {
            kick.t = 0; kick.phase = 0; kick.gain = 0.5; kick.freq = 150; kick.freqEnd = 42
            duck = 0.45
        }
        if step == 4 || step == 12 {
            snare.t = 0; snare.gain = 0.28; snare.freq = 190; snare.freqEnd = 140
        }
        let open = step % 4 == 2
        hat.t = 0; hat.gain = open ? 0.09 : (step % 2 == 0 ? 0.06 : 0.04); hat.dur = open ? 0.11 : 0.03

        if let b = Self.bassPattern[step] {
            let midi = Self.roots[chord] + Double(b)
            hit(&bass, freq: 440 * pow(2, (midi - 69) / 12), gain: 0.26, dur: b == 12 ? 0.14 : 0.22)
        }
        let leadBar = Self.leadBars[chord]
        if let l = leadBar[step] {
            let octave = bar >= 4 && chord >= 2 ? 12.0 : 0
            let midi = 72 + Double(l) + octave
            hit(&lead, freq: 440 * pow(2, (midi - 69) / 12), gain: 0.2, dur: 0.24)
        }
        if bar >= 4, step % 2 == 1 {
            let notes = Self.arpNotes[chord]
            let midi = 84 + Double(notes[(step / 2) % 3])
            hit(&arp, freq: 440 * pow(2, (midi - 69) / 12), gain: 0.08, dur: 0.1)
        }
    }
}

import AVFoundation
import Foundation

/// Receive-only camera audio playback engine (no microphone capture).
final class AudioStreamPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var started = false
    var isMuted: Bool = true

    func configure(sampleRate: Double = 8000) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        self.format = fmt
        if !self.started, let fmt {
            self.engine.attach(self.playerNode)
            self.engine.connect(self.playerNode, to: self.engine.mainMixerNode, format: fmt)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.engine.start()
            self.playerNode.play()
            self.started = true
        }
    }

    func enqueueSamples(_ samples: [Float]) {
        guard !self.isMuted, self.started, let fmt = self.format, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            for idx in samples.indices {
                channel[idx] = samples[idx]
            }
        }
        self.playerNode.scheduleBuffer(buffer)
    }

    func stop() {
        guard self.started else { return }
        self.playerNode.stop()
        self.engine.stop()
        self.started = false
    }
}

import AVFoundation
import Foundation

/// Receive-only camera audio playback engine (no microphone capture).
final class AudioStreamPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var attached = false
    private var started = false
    var isMuted: Bool = true

    func configure(sampleRate: Double = 8000) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        self.format = fmt
        guard !self.started, let fmt else { return }

        if !self.attached {
            self.engine.attach(self.playerNode)
            self.attached = true
        }
        self.engine.disconnectNodeOutput(self.playerNode)
        self.engine.connect(self.playerNode, to: self.engine.mainMixerNode, format: fmt)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            if !self.engine.isRunning {
                try self.engine.start()
            }
            if self.engine.isRunning {
                self.playerNode.play()
                self.started = true
            }
        } catch {
            self.started = false
        }
    }

    func enqueueSamples(_ samples: [Float]) {
        guard !self.isMuted, self.started, self.engine.isRunning, let fmt = self.format, !samples.isEmpty else { return }
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
        guard self.started || self.engine.isRunning else { return }
        self.playerNode.stop()
        self.engine.stop()
        self.started = false
    }
}

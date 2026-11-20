import AudioToolbox
import CoreVideo
import Foundation
import UserNotifications
import Vision

final class VisionAlertEngine {
    private let queue = DispatchQueue(label: "com.lessy.directcam.vision")
    private var lastAnalysisTime: Date = .distantPast
    private var lastAlertTime: Date = .distantPast
    private var inFlight = false

    func analyzeIfDue(
        pixelBuffer: CVPixelBuffer,
        settings: MonitorSettings,
        minInterval: TimeInterval = 0.4,
        completion: @escaping ([VisionDetectionBox], Bool, VisionTargetKind?, Float) -> Void
    ) {
        let now = Date()
        guard (settings.detectHumans || settings.detectPets),
              !self.inFlight,
              now.timeIntervalSince(self.lastAnalysisTime) >= minInterval else {
            return
        }
        self.inFlight = true
        self.lastAnalysisTime = now

        self.queue.async { [weak self] in
            defer { self?.inFlight = false }
            var boxes: [VisionDetectionBox] = []
            var requests: [VNRequest] = []

            let humanReq = VNDetectHumanRectanglesRequest()
            humanReq.upperBodyOnly = false
            if settings.detectHumans {
                requests.append(humanReq)
            }

            let animalReq = VNRecognizeAnimalsRequest()
            if settings.detectPets {
                requests.append(animalReq)
            }

            guard !requests.isEmpty else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform(requests)
            } catch {
                return
            }

            let threshold = Float(settings.minConfidence)
            if settings.detectHumans, let results = humanReq.results {
                for obs in results where obs.confidence >= threshold {
                    boxes.append(VisionDetectionBox(
                        kind: .human,
                        confidence: obs.confidence,
                        normalizedRectTopLeft: Self.convertVisionBoundingBoxToTopLeft(obs.boundingBox)
                    ))
                }
            }
            if settings.detectPets, let results = animalReq.results {
                for obs in results where obs.confidence >= threshold {
                    boxes.append(VisionDetectionBox(
                        kind: .pet,
                        confidence: obs.confidence,
                        normalizedRectTopLeft: Self.convertVisionBoundingBoxToTopLeft(obs.boundingBox)
                    ))
                }
            }

            let alertEvaluation = Self.evaluateAlert(
                detections: boxes,
                minConfidence: threshold,
                cooldownSeconds: settings.cooldownSeconds,
                lastAlertDate: self?.lastAlertTime ?? .distantPast,
                now: now
            )
            if alertEvaluation.shouldTrigger {
                self?.lastAlertTime = now
            }

            completion(boxes, alertEvaluation.shouldTrigger, alertEvaluation.primaryKind, alertEvaluation.bestConfidence)
        }
    }

    static func convertVisionBoundingBoxToTopLeft(_ bbox: CGRect) -> (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let x = max(0, min(1, bbox.origin.x))
        let w = max(0, min(1 - x, bbox.size.width))
        let yTop = max(0, min(1, 1.0 - bbox.origin.y - bbox.size.height))
        let h = max(0, min(1 - yTop, bbox.size.height))
        return (x, yTop, w, h)
    }

    static func evaluateAlert(
        detections: [VisionDetectionBox],
        minConfidence: Float,
        cooldownSeconds: Int,
        lastAlertDate: Date,
        now: Date
    ) -> (shouldTrigger: Bool, primaryKind: VisionTargetKind?, bestConfidence: Float) {
        let qualified = detections.filter { $0.confidence >= minConfidence }
        guard let top = qualified.max(by: { $0.confidence < $1.confidence }) else {
            return (false, nil, 0)
        }
        let elapsed = now.timeIntervalSince(lastAlertDate)
        guard elapsed >= TimeInterval(max(1, cooldownSeconds)) else {
            return (false, top.kind, top.confidence)
        }
        return (true, top.kind, top.confidence)
    }

    static func playAlertChime() {
        AudioServicesPlaySystemSound(1005)
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postLocalNotification(cameraName: String, kind: VisionTargetKind, confidence: Float) {
        let content = UNMutableNotificationContent()
        content.title = "\(kind.label) Detected — \(cameraName)"
        content.body = "On-device Vision confidence \(Int(confidence * 100))%"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

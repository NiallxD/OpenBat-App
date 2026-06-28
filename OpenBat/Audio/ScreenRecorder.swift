//
//  ScreenRecorder.swift
//  OpenBat
//
//  Whole-session screen capture via ReplayKit. Started/stopped together with the
//  armed audio recorder. Rather than ReplayKit's built-in writer (which uses a
//  very high default bitrate → huge files), we take the raw frames from
//  `startCapture` and re-encode with AVAssetWriter using HEVC at a capped bitrate,
//  which shrinks the output dramatically. Saved next to the WAV passes in
//  Documents/Recordings/<date>/screen-<time>.mp4 (video only — audio is the WAV).
//
//  NOT pulse-triggered: ReplayKit records continuously while armed.
//

import ReplayKit
import AVFoundation
import Observation

@Observable
final class ScreenRecorder: @unchecked Sendable {

    private(set) var isRecording = false
    private(set) var lastError: String?
    private(set) var lastSavedFilename: String?

    /// Target average video bitrate. ~2.5 Mbps keeps the spectrogram readable while
    /// being a fraction of ReplayKit's default (often 10–20+ Mbps).
    var averageBitrate = 2_500_000

    private let recorder = RPScreenRecorder.shared()
    private let writeQueue = DispatchQueue(label: "bat.ScreenRecorder.write")

    // writeQueue-only
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var startedSession = false
    private var outputURL: URL?

    var isAvailable: Bool { recorder.isAvailable }

    func start() {
        guard recorder.isAvailable, !recorder.isRecording else { return }
        let url = Self.makeURL()
        writeQueue.async { [weak self] in
            guard let self else { return }
            writer = try? AVAssetWriter(outputURL: url, fileType: .mp4)
            videoInput = nil
            startedSession = false
            outputURL = url
        }

        recorder.isMicrophoneEnabled = false
        recorder.startCapture { [weak self] sample, type, error in
            self?.append(sample, type: type, error: error)
        } completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.lastError = error.localizedDescription
                } else {
                    self?.lastError = nil
                    self?.isRecording = true
                }
            }
        }
    }

    func stop() {
        guard recorder.isRecording else { return }
        recorder.stopCapture { [weak self] error in
            guard let self else { return }
            if let error { DispatchQueue.main.async { self.lastError = error.localizedDescription } }
            writeQueue.async {
                guard let writer = self.writer else {
                    DispatchQueue.main.async { self.isRecording = false }
                    return
                }
                self.videoInput?.markAsFinished()
                if writer.status == .writing {
                    writer.finishWriting { [weak self] in
                        guard let self else { return }
                        let name = self.outputURL?.lastPathComponent
                        DispatchQueue.main.async {
                            self.isRecording = false
                            if writer.status == .completed { self.lastSavedFilename = name }
                            else if let e = writer.error { self.lastError = e.localizedDescription }
                        }
                        self.reset()
                    }
                } else {
                    DispatchQueue.main.async { self.isRecording = false }
                    self.reset()
                }
            }
        }
    }

    // MARK: - Frame handling (ReplayKit thread → writeQueue)

    private func append(_ sample: CMSampleBuffer, type: RPSampleBufferType, error: Error?) {
        guard error == nil, type == .video, CMSampleBufferDataIsReady(sample) else { return }
        writeQueue.async { [weak self] in
            guard let self, let writer = self.writer else { return }

            if videoInput == nil {
                configureVideoInput(from: sample, writer: writer)
            }
            guard let videoInput else { return }

            if writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                startedSession = true
            }
            if writer.status == .writing, videoInput.isReadyForMoreMediaData {
                videoInput.append(sample)
            }
        }
    }

    private func configureVideoInput(from sample: CMSampleBuffer, writer: AVAssetWriter) {
        guard let desc = CMSampleBufferGetFormatDescription(sample) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitrate,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) { writer.add(input) }
        videoInput = input
    }

    private func reset() {
        writer = nil
        videoInput = nil
        startedSession = false
        outputURL = nil
    }

    // MARK: - File location

    private static func makeURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let day = dayFormatter.string(from: Date())
        let stamp = stampFormatter.string(from: Date())
        let dir = docs.appendingPathComponent("Recordings/\(day)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screen-\(stamp).mp4")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH-mm-ss-SSS"; return f
    }()
}

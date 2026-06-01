import AVFoundation
import CoreImage
import QuartzCore
import SwiftUI
import UIKit

struct SymbolicCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = SymbolicCameraController()
    @State private var isRotatingFrontLine = false
    @State private var isRotatingBackLine = false
    @State private var overlayDate = Date()

    let glyphValue: String
    let glyphDepth: Int
    let onCapture: (Data) -> Void

    private let rotationTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private let dateTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        glyphValue: String,
        glyphDepth: Int,
        onCapture: @escaping (Data) -> Void
    ) {
        self.glyphValue = glyphValue
        self.glyphDepth = glyphDepth
        self.onCapture = onCapture
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Close camera")

                    Spacer()
                }
                .padding([.horizontal, .top])

                Spacer(minLength: 0)

                preview
                    .padding(.horizontal, 16)

                Spacer(minLength: 0)

                HStack(spacing: 30) {
                    holdToRotateButton(
                        primaryImage: "person.crop.circle",
                        directionImage: "arrow.clockwise",
                        isActive: isRotatingFrontLine,
                        accessibilityLabel: "Hold to rotate front mirror",
                        onChanged: { isRotatingFrontLine = true },
                        onEnded: { isRotatingFrontLine = false }
                    )

                    Button {
                        capture()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 5)
                                .frame(width: 78, height: 78)
                            Circle()
                                .fill(.white)
                                .frame(width: 62, height: 62)
                        }
                    }
                    .disabled(camera.previewImage == nil)
                    .accessibilityLabel("Capture symbolic photo")

                    holdToRotateButton(
                        primaryImage: "camera",
                        directionImage: "arrow.counterclockwise",
                        isActive: isRotatingBackLine,
                        accessibilityLabel: "Hold to rotate back mirror",
                        onChanged: { isRotatingBackLine = true },
                        onEnded: { isRotatingBackLine = false }
                    )
                }
                .padding(.bottom, 34)
            }
        }
        .task {
            await camera.start()
        }
        .onDisappear {
            camera.stop()
        }
        .onReceive(rotationTimer) { _ in
            if isRotatingFrontLine {
                camera.rotateFrontLine(by: 0.018)
            }
            if isRotatingBackLine {
                camera.rotateBackLine(by: -0.018)
            }
        }
        .onReceive(dateTimer) { date in
            overlayDate = date
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage = camera.previewImage {
            SymbolicCameraComposedImageView(
                baseImage: previewImage,
                glyphValue: glyphValue,
                glyphDepth: glyphDepth,
                date: overlayDate
            )
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.04))
                CameraPlaceholderView(state: camera.authorizationState, errorMessage: camera.errorMessage)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
    }

    private func holdToRotateButton(
        primaryImage: String,
        directionImage: String,
        isActive: Bool,
        accessibilityLabel: String,
        onChanged: @escaping () -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        Image(systemName: primaryImage)
            .symbolVariant(.none)
            .overlay {
                Image(systemName: directionImage)
                    .font(.caption.weight(.bold))
                    .offset(x: 14, y: -14)
            }
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(.ultraThinMaterial, in: Circle())
            .scaleEffect(isActive ? 1.08 : 1)
            .animation(.snappy(duration: 0.18), value: isActive)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        onChanged()
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
            .accessibilityLabel(accessibilityLabel)
    }

    @MainActor
    private func capture() {
        guard let baseImage = camera.captureBaseImage() else { return }

        let captureDate = Date()
        let renderer = ImageRenderer(
            content: SymbolicCameraComposedImageView(
                baseImage: baseImage,
                glyphValue: glyphValue,
                glyphDepth: glyphDepth,
                date: captureDate
            )
            .frame(width: 1600, height: 1600)
        )
        renderer.scale = 1

        guard let data = renderer.uiImage?.jpegData(compressionQuality: 0.94) else {
            return
        }

        onCapture(data)
        dismiss()
    }
}

private struct SymbolicCameraComposedImageView: View {
    let baseImage: UIImage
    let glyphValue: String
    let glyphDepth: Int
    let date: Date

    var body: some View {
        ZStack {
            Color.black
            Image(uiImage: baseImage)
                .resizable()
                .scaledToFill()

            VStack {
                Spacer()
                HStack(spacing: 10) {
                    OctalGlyph(value: glyphValue, depth: glyphDepth, color: .white)
                        .frame(width: 46, height: 46)
                    Text(JournalFormatters.dateTime.string(from: date))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .clipped()
    }
}

private struct CameraPlaceholderView: View {
    let state: CameraAuthorizationState
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var message: String {
        if let errorMessage {
            return errorMessage
        }

        switch state {
        case .notDetermined:
            return "Preparing camera"
        case .authorized:
            return "Opening viewfinder"
        case .denied:
            return "Camera access is disabled"
        case .unavailable:
            return "Camera unavailable"
        }
    }
}

enum CameraAuthorizationState {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

final class SymbolicCameraController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var authorizationState: CameraAuthorizationState = .notDetermined
    @Published private(set) var errorMessage: String?

    private let session: AVCaptureSession = AVCaptureMultiCamSession.isMultiCamSupported
        ? AVCaptureMultiCamSession()
        : AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "exeligmos.symbolic-camera.session")
    private let videoQueue = DispatchQueue(label: "exeligmos.symbolic-camera.video")
    private let ciOrientation: CGImagePropertyOrientation = .up

    private var frontOutput: AVCaptureVideoDataOutput?
    private var backOutput: AVCaptureVideoDataOutput?
    private var latestFrontImage: CIImage?
    private var latestBackImage: CIImage?
    private var latestBaseImage: UIImage?
    private var isConfigured = false
    private var lastFrameTime: CFTimeInterval = 0
    private var frontAngle: CGFloat = .pi / 2
    private var backAngle: CGFloat = .pi / 2

    func start() async {
        guard await requestAccessIfNeeded() else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.configureSessionIfNeeded()
                guard !self.session.isRunning else { return }
                self.session.startRunning()
            } catch {
                Task { @MainActor in
                    self.authorizationState = .unavailable
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func rotateFrontLine(by delta: CGFloat) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.frontAngle += delta
            self.renderLatestFrame(force: true)
        }
    }

    func rotateBackLine(by delta: CGFloat) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.backAngle += delta
            self.renderLatestFrame(force: true)
        }
    }

    @MainActor
    func captureBaseImage() -> UIImage? {
        latestBaseImage
    }

    private func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await MainActor.run {
                authorizationState = .authorized
            }
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            await MainActor.run {
                authorizationState = granted ? .authorized : .denied
            }
            return granted
        case .denied, .restricted:
            await MainActor.run {
                authorizationState = .denied
            }
            return false
        @unknown default:
            await MainActor.run {
                authorizationState = .unavailable
            }
            return false
        }
    }

    private func configureSessionIfNeeded() throws {
        if isConfigured { return }

        if let multiCamSession = session as? AVCaptureMultiCamSession {
            try configureMultiCamSession(multiCamSession)
        } else {
            try configureSingleCameraSession(session)
        }

        isConfigured = true
    }

    private func configureMultiCamSession(_ session: AVCaptureMultiCamSession) throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        try configureCamera(position: .front, in: session)
        try configureCamera(position: .back, in: session)
    }

    private func configureCamera(position: AVCaptureDevice.Position, in session: AVCaptureMultiCamSession) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw SymbolicCameraError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw SymbolicCameraError.cameraUnavailable
        }
        session.addInputWithNoConnections(input)

        let output = makeVideoOutput()
        guard session.canAddOutput(output) else {
            throw SymbolicCameraError.cameraUnavailable
        }
        session.addOutputWithNoConnections(output)

        guard let port = input.ports(
            for: .video,
            sourceDeviceType: device.deviceType,
            sourceDevicePosition: position
        ).first else {
            throw SymbolicCameraError.cameraUnavailable
        }

        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        configure(connection: connection)
        guard session.canAddConnection(connection) else {
            throw SymbolicCameraError.cameraUnavailable
        }
        session.addConnection(connection)

        if position == .front {
            frontOutput = output
        } else {
            backOutput = output
        }
    }

    private func configureSingleCameraSession(_ session: AVCaptureSession) throws {
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer {
            session.commitConfiguration()
        }

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            throw SymbolicCameraError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw SymbolicCameraError.cameraUnavailable
        }
        session.addInput(input)

        let output = makeVideoOutput()
        guard session.canAddOutput(output) else {
            throw SymbolicCameraError.cameraUnavailable
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            configure(connection: connection)
        }

        frontOutput = output
    }

    private func makeVideoOutput() -> AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        return output
    }

    private func configure(connection: AVCaptureConnection) {
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
    }

    private func renderLatestFrame(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastFrameTime >= 1.0 / 12.0 else { return }
        lastFrameTime = now

        guard let preview = SymbolicCameraImageComposer.compose(
            frontImage: latestFrontImage,
            backImage: latestBackImage,
            frontAngle: frontAngle,
            backAngle: backAngle,
            outputSize: 960
        ) else {
            return
        }

        Task { @MainActor in
            self.previewImage = preview
            self.latestBaseImage = preview
        }
    }
}

extension SymbolicCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let frame = CIImage(cvPixelBuffer: pixelBuffer).oriented(ciOrientation)
        if output === frontOutput {
            latestFrontImage = frame
        } else if output === backOutput {
            latestBackImage = frame
        }

        renderLatestFrame()
    }
}

enum SymbolicCameraImageComposer {
    static func compose(
        frontImage: CIImage?,
        backImage: CIImage?,
        frontAngle: CGFloat,
        backAngle: CGFloat,
        outputSize: CGFloat
    ) -> UIImage? {
        let tileSize = outputSize / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(
            size: CGSize(width: outputSize, height: outputSize),
            format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))

            drawTile(
                image: tileImage(source: frontImage, angle: frontAngle, side: .positive),
                in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize)
            )
            drawTile(
                image: tileImage(source: frontImage, angle: frontAngle, side: .negative),
                in: CGRect(x: tileSize, y: 0, width: tileSize, height: tileSize)
            )
            drawTile(
                image: tileImage(source: backImage, angle: backAngle, side: .positive),
                in: CGRect(x: 0, y: tileSize, width: tileSize, height: tileSize)
            )
            drawTile(
                image: tileImage(source: backImage, angle: backAngle, side: .negative),
                in: CGRect(x: tileSize, y: tileSize, width: tileSize, height: tileSize)
            )

            UIColor.white.withAlphaComponent(0.16).setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.move(to: CGPoint(x: tileSize, y: 0))
            context.cgContext.addLine(to: CGPoint(x: tileSize, y: outputSize))
            context.cgContext.move(to: CGPoint(x: 0, y: tileSize))
            context.cgContext.addLine(to: CGPoint(x: outputSize, y: tileSize))
            context.cgContext.strokePath()
        }
    }

    private static func tileImage(source: CIImage?, angle: CGFloat, side: MirrorReflectionSide) -> UIImage? {
        guard let source else { return nil }
        let square = squareImage(source)
        let edge = MirrorEdge(
            normalizedPoint: CGPoint(x: 0.5, y: 0.5),
            angleRadians: angle,
            reflectedSide: side
        )
        return MirrorReflectionProcessor.renderedImage(from: square, edges: [edge])
    }

    private static func squareImage(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let side = min(extent.width, extent.height)
        let crop = CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        )
        return image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    private static func drawTile(image: UIImage?, in rect: CGRect) {
        guard let image else {
            UIColor(white: 0.08, alpha: 1).setFill()
            UIBezierPath(rect: rect).fill()
            return
        }
        image.draw(in: rect)
    }
}

private enum SymbolicCameraError: LocalizedError {
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "Camera unavailable."
        }
    }
}

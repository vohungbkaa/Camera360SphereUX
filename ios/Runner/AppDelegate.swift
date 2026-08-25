import Flutter
import UIKit
import AVFoundation
import CoreMotion
import CoreImage
import ImageIO
import Vision
import SceneKit
import simd

private struct MotionPose {
  let monotonicTime: TimeInterval
  let yaw: Double
  let pitch: Double
  let roll: Double
  let rotationRate: Double
  let quaternion: CMQuaternion

  var dictionary: [String: Any] {
    [
      "monotonicTimestampSec": monotonicTime,
      "yaw": yaw,
      "pitch": pitch,
      "roll": roll,
      "rotationRate": rotationRate,
      "quaternion": ["w": quaternion.w, "x": quaternion.x, "y": quaternion.y, "z": quaternion.z]
    ]
  }
}

private final class MotionPoseStore {
  static let shared = MotionPoseStore()
  private let lock = NSLock()
  private var history: [MotionPose] = []

  func append(_ pose: MotionPose) {
    lock.lock()
    history.append(pose)
    if history.count > 240 { history.removeFirst(history.count - 240) }
    lock.unlock()
  }

  func nearest(to monotonicTime: TimeInterval) -> MotionPose? {
    lock.lock()
    defer { lock.unlock() }
    return history.min { abs($0.monotonicTime - monotonicTime) < abs($1.monotonicTime - monotonicTime) }
  }

  var latest: MotionPose? {
    lock.lock()
    defer { lock.unlock() }
    return history.last
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SphereCameraPlugin") {
      SphereCameraPlugin.register(with: registrar)
    }
  }
}

final class SphereCameraPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let motionManager = CMMotionManager()
  private var eventSink: FlutterEventSink?

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(SphereCameraViewFactory(), withId: "sphere-camera-preview")
    let channel = FlutterEventChannel(name: "sphere-camera/motion", binaryMessenger: registrar.messenger())
    let instance = SphereCameraPlugin()
    channel.setStreamHandler(instance)
    let methods = FlutterMethodChannel(name: "sphere-camera/methods", binaryMessenger: registrar.messenger())
    methods.setMethodCallHandler { call, result in
      guard let view = SphereCameraView.current else { result(FlutterError(code: "cameraUnavailable", message: "Camera preview chưa sẵn sàng.", details: nil)); return }
      if call.method == "getCameraInfo" {
        result(view.cameraInfo())
        return
      }
      if call.method == "undoLastPatch" {
        view.undoLastPatch()
        result(nil)
        return
      }
      guard call.method == "capturePhoto" else { result(FlutterMethodNotImplemented); return }
      let arguments = call.arguments as? [String: Any]
      let sessionId = arguments?["sessionId"] as? String ?? UUID().uuidString
      let targetId = arguments?["targetId"] as? Int ?? -1
      let expectedYaw = arguments?["expectedYaw"] as? Double ?? 0
      let expectedPitch = arguments?["expectedPitch"] as? Double ?? 0
      let allowImuFallback = arguments?["allowImuFallback"] as? Bool ?? false
      view.capturePhoto(
        sessionId: sessionId,
        targetId: targetId,
        expectedYaw: expectedYaw,
        expectedPitch: expectedPitch,
        allowImuFallback: allowImuFallback,
        result: result
      )
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    guard motionManager.isDeviceMotionAvailable else { events(["available": false]); return nil }
    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, _ in
      guard let self, let motion else { return }
      let matrix = motion.attitude.rotationMatrix
      // CoreMotion rotates the reference frame into device coordinates. The
      // rear camera looks down device -Z, so transpose the matrix to obtain its
      // optical axis in the gravity-aligned reference frame.
      let forwardX = -matrix.m31
      let forwardY = -matrix.m32
      let forwardZ = -matrix.m33
      let yaw = atan2(forwardX, forwardY) * 180.0 / .pi
      let pitch = asin(max(-1.0, min(1.0, forwardZ))) * 180.0 / .pi
      let rate = sqrt(pow(motion.rotationRate.x, 2) + pow(motion.rotationRate.y, 2) + pow(motion.rotationRate.z, 2))
      let pose = MotionPose(
        monotonicTime: motion.timestamp,
        yaw: yaw,
        pitch: pitch,
        roll: motion.attitude.roll * 180.0 / .pi,
        rotationRate: rate,
        quaternion: motion.attitude.quaternion
      )
      MotionPoseStore.shared.append(pose)
      self.eventSink?([
        "available": true,
        "w": motion.attitude.quaternion.w,
        "x": motion.attitude.quaternion.x,
        "y": motion.attitude.quaternion.y,
        "z": motion.attitude.quaternion.z,
        "yaw": pose.yaw,
        "pitch": pose.pitch,
        "roll": pose.roll,
        "rotationRate": pose.rotationRate,
        "monotonicTimestampSec": pose.monotonicTime
      ])
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? { motionManager.stopDeviceMotionUpdates(); eventSink = nil; return nil }
}

final class SphereCameraViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView { SphereCameraView(frame: frame) }
}

private struct VisualReference {
  let yaw: Double
  let pitch: Double
  let image: CGImage
}

private final class MosaicSphereRenderer: NSObject, SCNSceneRendererDelegate {
  let view: SCNView
  private let cameraNode = SCNNode()
  private var patchNodes: [SCNNode] = []
  private var originPose: MotionPose?

  override init() {
    view = SCNView(
      frame: .zero,
      options: [
        SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
      ]
    )
    super.init()
    let scene = SCNScene()
    let camera = SCNCamera()
    camera.zNear = 0.01
    camera.zFar = 20
    camera.fieldOfView = 72
    cameraNode.camera = camera
    scene.rootNode.addChildNode(cameraNode)
    view.scene = scene
    view.pointOfView = cameraNode
    // An unfinished Photo Sphere is a canvas, not a second translucent camera
    // preview.  Keeping uncovered directions black makes coverage and seams
    // readable and matches the capture model used by Street View.
    view.backgroundColor = .black
    view.isOpaque = true
    view.isUserInteractionEnabled = false
    view.antialiasingMode = .multisampling4X
    view.delegate = self
    view.rendersContinuously = true
  }

  func setVerticalFieldOfView(_ degrees: Double) {
    cameraNode.camera?.fieldOfView = CGFloat(max(45, min(100, degrees)))
  }

  func addPatch(
    image: CGImage,
    pose: MotionPose?,
    fallbackYaw: Double,
    fallbackPitch: Double,
    horizontalFov: Double,
    verticalFov: Double
  ) {
    let relativeYaw: Double
    let relativePitch: Double
    if let pose, let originPose {
      relativeYaw = Self.wrapDegrees(pose.yaw - originPose.yaw)
      relativePitch = pose.pitch - originPose.pitch
    } else {
      relativeYaw = fallbackYaw
      relativePitch = fallbackPitch
    }
    let geometry = makePatchGeometry(
      centerYaw: relativeYaw,
      centerPitch: relativePitch,
      horizontalFov: horizontalFov,
      verticalFov: verticalFov
    )
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = image
    material.diffuse.wrapS = .clamp
    material.diffuse.wrapT = .clamp
    material.diffuse.magnificationFilter = .linear
    material.diffuse.minificationFilter = .linear
    material.diffuse.mipFilter = .linear
    material.diffuse.maxAnisotropy = 8
    material.isDoubleSided = true
    material.transparency = 1.0
    material.blendMode = .replace
    material.readsFromDepthBuffer = false
    material.writesToDepthBuffer = false
    geometry.materials = [material]
    let node = SCNNode(geometry: geometry)
    node.renderingOrder = patchNodes.count
    view.scene?.rootNode.addChildNode(node)
    patchNodes.append(node)
  }

  func undoLastPatch() {
    patchNodes.popLast()?.removeFromParentNode()
  }

  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    guard let pose = MotionPoseStore.shared.latest else { return }
    if originPose == nil { originPose = pose }
    guard let originPose else { return }
    let yaw = Self.wrapDegrees(pose.yaw - originPose.yaw) * .pi / 180.0
    let pitch = (pose.pitch - originPose.pitch) * .pi / 180.0
    // Roll from CoreMotion's Euler decomposition becomes unstable near the
    // zenith/nadir and made all patches appear to twist into a single point.
    // The capture guide is horizon-stabilized, so render only yaw and pitch.
    cameraNode.eulerAngles = SCNVector3(Float(pitch), Float(-yaw), 0)
  }

  private func makePatchGeometry(
    centerYaw: Double,
    centerPitch: Double,
    horizontalFov: Double,
    verticalFov: Double
  ) -> SCNGeometry {
    let columns = 16
    let rows = 20
    let radius = 3.0
    var vertices: [SCNVector3] = []
    var textureCoordinates: [CGPoint] = []
    var indices: [Int32] = []
    let yaw = centerYaw * .pi / 180.0
    let pitch = max(-89.5, min(89.5, centerPitch)) * .pi / 180.0
    let halfWidth = tan(horizontalFov * .pi / 360.0)
    let halfHeight = tan(verticalFov * .pi / 360.0)
    let forward = SIMD3<Double>(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    let right = SIMD3<Double>(cos(yaw), 0, sin(yaw))
    let up = SIMD3<Double>(-sin(yaw) * sin(pitch), cos(pitch), cos(yaw) * sin(pitch))
    for row in 0...rows {
      let v = Double(row) / Double(rows)
      for column in 0...columns {
        let u = Double(column) / Double(columns)
        // A camera image is rectilinear. Cast a ray through every subdivided
        // image-plane point, then intersect that ray with the sphere. Linear
        // yaw/pitch interpolation bends straight edges and pinches near poles.
        let imageX = (2.0 * u - 1.0) * halfWidth
        let imageY = (1.0 - 2.0 * v) * halfHeight
        let ray = simd_normalize(forward + imageX * right + imageY * up)
        vertices.append(SCNVector3(Float(radius * ray.x), Float(radius * ray.y), Float(radius * ray.z)))
        // Core Image has already baked EXIF orientation 6 into this portrait
        // CGImage. SceneKit needs only the vertical texture convention
        // adjustment here; flipping U mirrors left/right capture directions.
        textureCoordinates.append(CGPoint(x: u, y: v))
      }
    }
    let stride = columns + 1
    for row in 0..<rows {
      for column in 0..<columns {
        let topLeft = Int32(row * stride + column)
        let topRight = topLeft + 1
        let bottomLeft = Int32((row + 1) * stride + column)
        let bottomRight = bottomLeft + 1
        indices.append(contentsOf: [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight])
      }
    }
    let vertexSource = SCNGeometrySource(vertices: vertices)
    let textureSource = SCNGeometrySource(textureCoordinates: textureCoordinates)
    let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
    return SCNGeometry(sources: [vertexSource, textureSource], elements: [element])
  }

  private static func wrapDegrees(_ value: Double) -> Double {
    var wrapped = value.truncatingRemainder(dividingBy: 360.0)
    if wrapped > 180 { wrapped -= 360 }
    if wrapped < -180 { wrapped += 360 }
    return wrapped
  }
}

final class SphereCameraView: NSObject, FlutterPlatformView {
  static weak var current: SphereCameraView?
  private let previewView: PreviewView
  private let session = AVCaptureSession()
  private let photoOutput = AVCapturePhotoOutput()
  private let mosaicRenderer = MosaicSphereRenderer()
  private let sessionQueue = DispatchQueue(label: "camera360.sphere.capture", qos: .userInitiated)
  private var camera: AVCaptureDevice?
  private var acceptedPhotoCount = 0
  private var photoProcessors: [Int64: PhotoCaptureProcessor] = [:]
  private var visualReferences: [VisualReference] = []

  init(frame: CGRect) {
    previewView = PreviewView(frame: frame)
    super.init()
    previewView.previewLayer.session = session
    previewView.previewLayer.videoGravity = .resizeAspectFill
    mosaicRenderer.view.frame = previewView.bounds
    mosaicRenderer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    previewView.addSubview(mosaicRenderer.view)
    SphereCameraView.current = self
    configureCamera()
  }
  func view() -> UIView { previewView }

  private func configureCamera() {
    session.beginConfiguration()
    session.sessionPreset = .photo
    guard
      let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: camera),
      session.canAddInput(input)
    else {
      session.commitConfiguration()
      return
    }
    self.camera = camera
    session.addInput(input)
    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
      photoOutput.isHighResolutionCaptureEnabled = true
      photoOutput.maxPhotoQualityPrioritization = .quality
    }
    session.commitConfiguration()
    configureContinuousCameraControls(camera)
    if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      sessionQueue.async { self.session.startRunning() }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard granted, let self else { return }
        self.sessionQueue.async { self.session.startRunning() }
      }
    default: break
    }
  }

  private func configureContinuousCameraControls(_ device: AVCaptureDevice) {
    do {
      try device.lockForConfiguration()
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
      }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
      }
      if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
        device.whiteBalanceMode = .continuousAutoWhiteBalance
      }
      device.isSubjectAreaChangeMonitoringEnabled = true
      device.unlockForConfiguration()
    } catch { }
  }

  private func lockWhiteBalanceAfterFirstAcceptedPhoto() {
    guard acceptedPhotoCount == 1, let camera, camera.isWhiteBalanceModeSupported(.locked) else { return }
    do {
      try camera.lockForConfiguration()
      camera.whiteBalanceMode = .locked
      camera.unlockForConfiguration()
    } catch { }
  }

  func cameraInfo() -> [String: Any] {
    guard let camera else {
      return ["available": false]
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
    let landscapeHorizontalFov = Double(camera.activeFormat.videoFieldOfView)
    let aspect = max(1.0, Double(dimensions.width) / Double(max(1, dimensions.height)))
    let landscapeVerticalFov = 2.0 * atan(tan(landscapeHorizontalFov * .pi / 360.0) / aspect) * 180.0 / .pi
    mosaicRenderer.setVerticalFieldOfView(landscapeHorizontalFov)
    var minimumFocusDistanceMeters = -1.0
    if #available(iOS 15.0, *), camera.minimumFocusDistance > 0 {
      minimumFocusDistanceMeters = Double(camera.minimumFocusDistance) / 1000.0
    }
    return [
      "available": true,
      "deviceType": camera.deviceType.rawValue,
      "uniqueId": camera.uniqueID,
      "sensorPixelWidth": Int(dimensions.width),
      "sensorPixelHeight": Int(dimensions.height),
      "horizontalFovDegrees": landscapeVerticalFov,
      "verticalFovDegrees": landscapeHorizontalFov,
      "minFocusDistanceMeters": minimumFocusDistanceMeters,
      "supportsDepth": photoOutput.isDepthDataDeliverySupported,
      "qualityPrioritization": "quality",
      "exposureLockUsed": false,
      "whiteBalanceLockAfterFirstFrame": true
    ]
  }

  private func nearestVisualReference(yaw: Double, pitch: Double) -> CGImage? {
    let pitchA = pitch * .pi / 180.0
    let nearest = visualReferences.min { lhs, rhs in
      func distance(_ reference: VisualReference) -> Double {
        let pitchB = reference.pitch * .pi / 180.0
        var deltaYaw = abs(yaw - reference.yaw).truncatingRemainder(dividingBy: 360.0)
        if deltaYaw > 180.0 { deltaYaw = 360.0 - deltaYaw }
        let cosine = sin(pitchA) * sin(pitchB) + cos(pitchA) * cos(pitchB) * cos(deltaYaw * .pi / 180.0)
        return acos(max(-1.0, min(1.0, cosine))) * 180.0 / .pi
      }
      return distance(lhs) < distance(rhs)
    }
    guard let nearest else { return nil }
    let pitchB = nearest.pitch * .pi / 180.0
    var deltaYaw = abs(yaw - nearest.yaw).truncatingRemainder(dividingBy: 360.0)
    if deltaYaw > 180.0 { deltaYaw = 360.0 - deltaYaw }
    let cosine = sin(pitchA) * sin(pitchB) + cos(pitchA) * cos(pitchB) * cos(deltaYaw * .pi / 180.0)
    let distance = acos(max(-1.0, min(1.0, cosine))) * 180.0 / .pi
    return distance <= 65.0 ? nearest.image : nil
  }

  func capturePhoto(
    sessionId: String,
    targetId: Int,
    expectedYaw: Double,
    expectedPitch: Double,
    allowImuFallback: Bool,
    result: @escaping FlutterResult
  ) {
    guard session.isRunning else { result(FlutterError(code: "cameraNotRunning", message: "Camera chưa chạy.", details: nil)); return }
    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
    settings.flashMode = .off
    settings.photoQualityPrioritization = .quality
    settings.isHighResolutionPhotoEnabled = photoOutput.isHighResolutionCaptureEnabled
    settings.isAutoStillImageStabilizationEnabled = true
    let requestPose = MotionPoseStore.shared.latest
    let processor = PhotoCaptureProcessor(
      sessionId: sessionId,
      targetId: targetId,
      cameraInfo: cameraInfo(),
      requestPose: requestPose,
      visualReference: nearestVisualReference(yaw: expectedYaw, pitch: expectedPitch),
      allowImuFallback: allowImuFallback,
      result: result
    ) { [weak self] uniqueId, accepted, registrationImage, mosaicImage, capturePose in
      guard let self else { return }
      self.photoProcessors.removeValue(forKey: uniqueId)
      if accepted {
        self.acceptedPhotoCount += 1
        if let registrationImage, let mosaicImage {
          self.visualReferences.append(
            VisualReference(yaw: expectedYaw, pitch: expectedPitch, image: registrationImage)
          )
          let info = self.cameraInfo()
          let horizontalFov = info["horizontalFovDegrees"] as? Double ?? 55
          let verticalFov = info["verticalFovDegrees"] as? Double ?? 72
          DispatchQueue.main.async {
            self.mosaicRenderer.addPatch(
              image: mosaicImage,
              pose: capturePose,
              fallbackYaw: expectedYaw,
              fallbackPitch: expectedPitch,
              horizontalFov: horizontalFov,
              verticalFov: verticalFov
            )
          }
        }
        self.lockWhiteBalanceAfterFirstAcceptedPhoto()
      }
    }
    photoProcessors[settings.uniqueID] = processor
    photoOutput.capturePhoto(with: settings, delegate: processor)
  }

  func undoLastPatch() {
    DispatchQueue.main.async { self.mosaicRenderer.undoLastPatch() }
    if !visualReferences.isEmpty { visualReferences.removeLast() }
  }
}

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
  let sessionId: String
  let targetId: Int
  let cameraInfo: [String: Any]
  let requestPose: MotionPose?
  let visualReference: CGImage?
  let allowImuFallback: Bool
  let result: FlutterResult
  let completion: (Int64, Bool, CGImage?, CGImage?, MotionPose?) -> Void
  private var uniqueId: Int64 = -1

  init(
    sessionId: String,
    targetId: Int,
    cameraInfo: [String: Any],
    requestPose: MotionPose?,
    visualReference: CGImage?,
    allowImuFallback: Bool,
    result: @escaping FlutterResult,
    completion: @escaping (Int64, Bool, CGImage?, CGImage?, MotionPose?) -> Void
  ) {
    self.sessionId = sessionId
    self.targetId = targetId
    self.cameraInfo = cameraInfo
    self.requestPose = requestPose
    self.visualReference = visualReference
    self.allowImuFallback = allowImuFallback
    self.result = result
    self.completion = completion
  }

  func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
    uniqueId = resolvedSettings.uniqueID
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    if let error {
      result(FlutterError(code: "captureFailed", message: error.localizedDescription, details: nil))
      completion(uniqueId, false, nil, nil, nil)
      return
    }
    guard let data = photo.fileDataRepresentation() else {
      result(FlutterError(code: "captureFailed", message: "Không lấy được dữ liệu ảnh.", details: nil))
      completion(uniqueId, false, nil, nil, nil)
      return
    }
    let exposureMonotonicTime = photo.timestamp.isValid ? photo.timestamp.seconds : ProcessInfo.processInfo.systemUptime
    let pose = MotionPoseStore.shared.nearest(to: exposureMonotonicTime) ?? requestPose
    let capturedAtMs = Int((Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - exposureMonotonicTime)) * 1000.0)
    let quality = FrameQualityAnalyzer.analyze(data: data, visualReference: visualReference)
    guard quality.accepted || (allowImuFallback && quality.canUseImuFallback) else {
      result(FlutterError(
        code: "qualityRejected",
        message: quality.message,
        details: quality.dictionary
      ))
      completion(uniqueId, false, nil, nil, pose)
      return
    }
    do {
      let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let directory = root.appendingPathComponent("SphereCapture").appendingPathComponent(sessionId).appendingPathComponent("frames")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let path = directory.appendingPathComponent("frame-\(targetId)-\(capturedAtMs).jpg")
      try data.write(to: path, options: .atomic)
      let metadata = buildMetadata(
        photo: photo,
        data: data,
        pose: pose,
        capturedAtMs: capturedAtMs,
        quality: quality,
        usedImuFallback: !quality.accepted
      )
      let sidecar = path.deletingPathExtension().appendingPathExtension("json")
      let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
      try jsonData.write(to: sidecar, options: .atomic)
      var response = metadata
      response["path"] = path.path
      response["metadataPath"] = sidecar.path
      result(response)
      completion(uniqueId, true, quality.registrationImage, quality.mosaicImage, pose)
    } catch {
      result(FlutterError(code: "storageFailed", message: error.localizedDescription, details: nil))
      completion(uniqueId, false, nil, nil, pose)
    }
  }

  private func buildMetadata(
    photo: AVCapturePhoto,
    data: Data,
    pose: MotionPose?,
    capturedAtMs: Int,
    quality: FrameQuality,
    usedImuFallback: Bool
  ) -> [String: Any] {
    let properties = CGImageSourceCreateWithData(data as CFData, nil)
      .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let encodedWidth = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
    let encodedHeight = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
    let exifOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
    let swapsAxes = [5, 6, 7, 8].contains(exifOrientation)
    let width = swapsAxes ? encodedHeight : encodedWidth
    let height = swapsAxes ? encodedWidth : encodedHeight
    let focalLength = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? 0
    let focalLength35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue ?? 0
    let exposureTime = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0
    let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
    let fNumber = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 0
    var intrinsics = cameraInfo
    intrinsics["pixelWidth"] = width
    intrinsics["pixelHeight"] = height
    intrinsics["encodedPixelWidth"] = encodedWidth
    intrinsics["encodedPixelHeight"] = encodedHeight
    intrinsics["exifOrientation"] = exifOrientation
    intrinsics["principalPointX"] = Double(width) / 2.0
    intrinsics["principalPointY"] = Double(height) / 2.0
    intrinsics["focalLengthMm"] = focalLength
    intrinsics["focalLength35mm"] = focalLength35
    if let hFov = cameraInfo["horizontalFovDegrees"] as? Double, hFov > 0, width > 0 {
      intrinsics["fxPixels"] = Double(width) / (2.0 * tan(hFov * .pi / 360.0))
    }
    if let vFov = cameraInfo["verticalFovDegrees"] as? Double, vFov > 0, height > 0 {
      intrinsics["fyPixels"] = Double(height) / (2.0 * tan(vFov * .pi / 360.0))
    }
    var qualityMetadata = quality.dictionary
    qualityMetadata["usedImuFallback"] = usedImuFallback
    return [
      "schemaVersion": "2.0.0",
      "targetId": targetId,
      "capturedAtMs": capturedAtMs,
      "pose": pose?.dictionary ?? [:],
      "intrinsics": intrinsics,
      "exposure": [
        "iso": isoValues?.first?.doubleValue ?? 0,
        "exposureTimeSeconds": exposureTime,
        "fNumber": fNumber,
        "whiteBalanceLocked": cameraInfo["whiteBalanceLockAfterFirstFrame"] as? Bool ?? false,
        "exposureLockUsed": false
      ],
      "quality": qualityMetadata,
      "coordinateFrame": "coreMotionReferenceZUpRearCameraV2"
    ]
  }
}

private struct FrameQuality {
  let sharpness: Double
  let brightness: Double
  let visualRegistration: String
  let registrationImage: CGImage?
  let mosaicImage: CGImage?
  let accepted: Bool
  let reasons: [String]

  var canUseImuFallback: Bool {
    !reasons.contains("tooDark") &&
      !reasons.contains("overexposed") &&
      !reasons.contains("decodeFailed")
  }

  var message: String {
    if reasons.contains("tooDark") { return "Ảnh quá tối — tăng ánh sáng hoặc hướng khỏi vùng tối." }
    if reasons.contains("overexposed") { return "Ảnh bị cháy sáng — tránh hướng thẳng vào nguồn sáng." }
    if reasons.contains("visualRegistrationFailed") {
      return "Không tìm đủ điểm trùng với ảnh bên cạnh — quay chậm và giữ nguyên vị trí."
    }
    return "Ảnh bị rung hoặc thiếu chi tiết — giữ máy yên và chụp lại."
  }

  var dictionary: [String: Any] {
    [
      "sharpness": sharpness,
      "brightness": brightness,
      "visualRegistration": visualRegistration,
      "accepted": accepted,
      "reasons": reasons
    ]
  }
}

private enum FrameQualityAnalyzer {
  private static let context = CIContext(options: [.cacheIntermediates: false])

  static func analyze(data: Data, visualReference: CGImage?) -> FrameQuality {
    guard
      let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
      !image.extent.isEmpty
    else {
      return FrameQuality(
        sharpness: 0,
        brightness: 0,
        visualRegistration: "decodeFailed",
        registrationImage: nil,
        mosaicImage: nil,
        accepted: false,
        reasons: ["decodeFailed"]
      )
    }
    let brightness = averageLuma(image)
    let edges = image
      .applyingFilter("CIPhotoEffectMono")
      .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
    let sharpness = averageLuma(edges)
    var reasons: [String] = []
    if brightness < 0.025 { reasons.append("tooDark") }
    if brightness > 0.985 { reasons.append("overexposed") }
    if sharpness < 0.010 { reasons.append("blurOrLowTexture") }
    let registrationImage = makeScaledImage(image, maximumDimension: 640)
    let mosaicImage = makeScaledImage(image, maximumDimension: 1280)
    var visualRegistration = visualReference == nil ? "firstOrNoNearbyReference" : "failed"
    if let registrationImage, let visualReference {
      visualRegistration = validatesOverlap(reference: visualReference, current: registrationImage)
        ? "homographyValidated"
        : "failed"
      if visualRegistration == "failed" { reasons.append("visualRegistrationFailed") }
    }
    return FrameQuality(
      sharpness: sharpness,
      brightness: brightness,
      visualRegistration: visualRegistration,
      registrationImage: registrationImage,
      mosaicImage: mosaicImage,
      accepted: reasons.isEmpty,
      reasons: reasons
    )
  }

  private static func makeScaledImage(_ image: CIImage, maximumDimension: CGFloat) -> CGImage? {
    let extent = image.extent.integral
    let scale = maximumDimension / max(extent.width, extent.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return context.createCGImage(scaled, from: scaled.extent.integral)
  }

  private static func validatesOverlap(reference: CGImage, current: CGImage) -> Bool {
    guard reference.width == current.width, reference.height == current.height else { return false }
    let request = VNHomographicImageRegistrationRequest(targetedCGImage: current, options: [:])
    let handler = VNImageRequestHandler(cgImage: reference, options: [:])
    do {
      try handler.perform([request])
      guard let observation = request.results?.first else { return false }
      let transform = observation.warpTransform
      return transform.columns.0.x.isFinite && transform.columns.1.y.isFinite && transform.columns.2.z.isFinite
    } catch {
      return false
    }
  }

  private static func averageLuma(_ image: CIImage) -> Double {
    let extent = image.extent.integral
    guard let filter = CIFilter(name: "CIAreaAverage") else { return 0 }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
    guard let output = filter.outputImage else { return 0 }
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
      output,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255.0
  }
}

final class PreviewView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

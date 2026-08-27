package com.camera360.camera360_sphere_ux

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import android.view.TextureView
import android.view.View
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.atan
import kotlin.math.sqrt

class MainActivity : FlutterActivity(), EventChannel.StreamHandler, SensorEventListener {
    companion object { private const val CAMERA_PERMISSION_REQUEST = 7401 }

    private lateinit var sensorManager: SensorManager
    private var eventSink: EventChannel.EventSink? = null
    private var rotationVector: Sensor? = null
    private var gyroscope: Sensor? = null
    private var rotationRate = 0.0
    private var cameraView: SphereCameraPlatformView? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        rotationVector = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        gyroscope = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "sphere-camera-preview",
            SphereCameraViewFactory(this) { cameraView = it },
        )
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "sphere-camera/motion")
            .setStreamHandler(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sphere-camera/methods")
            .setMethodCallHandler { call, result ->
                val view = cameraView
                when (call.method) {
                    "getCameraInfo" -> {
                        if (view == null) result.error("cameraUnavailable", "Camera preview chưa sẵn sàng.", null)
                        else result.success(view.cameraInfo())
                    }
                    "capturePhoto" -> {
                        val sessionId = call.argument<String>("sessionId") ?: System.currentTimeMillis().toString()
                        if (view == null) result.error("cameraUnavailable", "Camera preview chưa sẵn sàng.", null)
                        else view.capturePhoto(sessionId, result)
                    }
                    else -> result.notImplemented()
                }
            }
        if (!hasCameraPermission()) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST)
        }
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_REQUEST && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            cameraView?.startCamera()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        val orientation = rotationVector
        if (orientation == null || gyroscope == null) {
            events.success(mapOf("available" to false))
            return
        }
        sensorManager.registerListener(this, orientation, SensorManager.SENSOR_DELAY_GAME)
        sensorManager.registerListener(this, gyroscope, SensorManager.SENSOR_DELAY_GAME)
    }

    override fun onCancel(arguments: Any?) {
        sensorManager.unregisterListener(this)
        eventSink = null
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type == Sensor.TYPE_GYROSCOPE) {
            rotationRate = sqrt(
                (event.values[0] * event.values[0] + event.values[1] * event.values[1] +
                    event.values[2] * event.values[2]).toDouble(),
            )
            return
        }
        if (event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return
        val matrix = FloatArray(9)
        val orientation = FloatArray(3)
        SensorManager.getRotationMatrixFromVector(matrix, event.values)
        SensorManager.getOrientation(matrix, orientation)
        val radiansToDegrees = 180.0 / Math.PI
        eventSink?.success(
            mapOf(
                "available" to true,
                "yaw" to orientation[0] * radiansToDegrees,
                "pitch" to (orientation[1] * radiansToDegrees + 90.0).coerceIn(-90.0, 90.0),
                "roll" to orientation[2] * radiansToDegrees,
                "rotationRate" to rotationRate,
            ),
        )
    }

    private class SphereCameraViewFactory(
        private val activity: MainActivity,
        private val onCreated: (SphereCameraPlatformView) -> Unit,
    ) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
            SphereCameraPlatformView(activity).also(onCreated)
    }
}

private class SphereCameraPlatformView(private val activity: Activity) : PlatformView,
    TextureView.SurfaceTextureListener {
    private val textureView = TextureView(activity)
    private val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val backgroundThread = HandlerThread("SphereCamera").apply { start() }
    private val backgroundHandler = Handler(backgroundThread.looper)
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var previewSurface: Surface? = null
    private var sensorOrientation = 90
    private var jpegWidth = 0
    private var jpegHeight = 0
    private var horizontalFovDegrees = 55.0
    private var verticalFovDegrees = 72.0
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSessionId: String? = null
    private val opening = AtomicBoolean(false)

    init {
        textureView.surfaceTextureListener = this
        if (textureView.isAvailable) startCamera()
    }

    override fun getView(): View = textureView

    override fun dispose() {
        captureSession?.close()
        cameraDevice?.close()
        imageReader?.close()
        previewSurface?.release()
        backgroundThread.quitSafely()
    }

    fun startCamera() {
        if (!textureView.isAvailable || cameraDevice != null || !opening.compareAndSet(false, true)) return
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            opening.set(false)
            return
        }
        try {
            val id = cameraManager.cameraIdList.firstOrNull { cameraId ->
                cameraManager.getCameraCharacteristics(cameraId).get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_BACK
            } ?: run { opening.set(false); return }
            val characteristics = cameraManager.getCameraCharacteristics(id)
            sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            val sizes = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(android.graphics.ImageFormat.JPEG)
            val jpegSize = sizes?.maxByOrNull { it.width.toLong() * it.height }
                ?: android.util.Size(1920, 1080)
            jpegWidth = jpegSize.width
            jpegHeight = jpegSize.height
            val sensorSize = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            val focalLength = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                ?.firstOrNull()?.toDouble()
            if (sensorSize != null && focalLength != null && focalLength > 0) {
                val landscapeHorizontal = 2.0 * atan(sensorSize.width / (2.0 * focalLength)) * 180.0 / Math.PI
                val landscapeVertical = 2.0 * atan(sensorSize.height / (2.0 * focalLength)) * 180.0 / Math.PI
                horizontalFovDegrees = landscapeVertical
                verticalFovDegrees = landscapeHorizontal
            }
            imageReader = ImageReader.newInstance(
                jpegSize.width, jpegSize.height, android.graphics.ImageFormat.JPEG, 2,
            ).also { reader -> reader.setOnImageAvailableListener({ saveImage(it) }, backgroundHandler) }
            cameraManager.openCamera(id, cameraStateCallback, backgroundHandler)
        } catch (error: Exception) {
            opening.set(false)
            pendingResult?.error("cameraUnavailable", error.message, null)
            pendingResult = null
        }
    }

    fun cameraInfo(): Map<String, Any> = mapOf(
        "available" to (cameraDevice != null),
        "pixelWidth" to jpegHeight,
        "pixelHeight" to jpegWidth,
        "encodedPixelWidth" to jpegWidth,
        "encodedPixelHeight" to jpegHeight,
        "exifOrientation" to if (sensorOrientation == 270) 8 else if (sensorOrientation == 90) 6 else 1,
        "horizontalFovDegrees" to horizontalFovDegrees,
        "verticalFovDegrees" to verticalFovDegrees,
        "qualityPrioritization" to "maximum-jpeg-resolution",
    )

    private val cameraStateCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(camera: CameraDevice) {
            opening.set(false)
            cameraDevice = camera
            createPreviewSession()
        }
        override fun onDisconnected(camera: CameraDevice) {
            opening.set(false); camera.close(); cameraDevice = null
        }
        override fun onError(camera: CameraDevice, error: Int) {
            opening.set(false); camera.close(); cameraDevice = null
        }
    }

    private fun createPreviewSession() {
        val camera = cameraDevice ?: return
        val surfaceTexture = textureView.surfaceTexture ?: return
        surfaceTexture.setDefaultBufferSize(1280, 720)
        previewSurface?.release()
        val surface = Surface(surfaceTexture).also { previewSurface = it }
        val jpegSurface = imageReader?.surface ?: return
        val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(surface)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        }
        val callback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                session.setRepeatingRequest(request.build(), null, backgroundHandler)
            }
            override fun onConfigureFailed(session: CameraCaptureSession) = Unit
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            camera.createCaptureSession(
                android.hardware.camera2.params.SessionConfiguration(
                    android.hardware.camera2.params.SessionConfiguration.SESSION_REGULAR,
                    listOf(
                        android.hardware.camera2.params.OutputConfiguration(surface),
                        android.hardware.camera2.params.OutputConfiguration(jpegSurface),
                    ),
                    activity.mainExecutor,
                    callback,
                ),
            )
        } else {
            @Suppress("DEPRECATION")
            camera.createCaptureSession(listOf(surface, jpegSurface), callback, backgroundHandler)
        }
    }

    fun capturePhoto(sessionId: String, result: MethodChannel.Result) {
        val camera = cameraDevice
        val session = captureSession
        val jpegSurface = imageReader?.surface
        if (camera == null || session == null || jpegSurface == null) {
            result.error("cameraNotRunning", "Camera chưa chạy.", null)
            return
        }
        if (pendingResult != null) {
            result.error("captureInProgress", "Một ảnh khác đang được ghi.", null)
            return
        }
        pendingResult = result
        pendingSessionId = sessionId
        try {
            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(jpegSurface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(CaptureRequest.JPEG_ORIENTATION, sensorOrientation)
                set(CaptureRequest.JPEG_QUALITY, 100.toByte())
            }
            session.capture(request.build(), null, backgroundHandler)
        } catch (error: Exception) {
            pendingResult = null
            pendingSessionId = null
            result.error("captureFailed", error.message, null)
        }
    }

    private fun saveImage(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        val result = pendingResult
        val sessionId = pendingSessionId
        if (result == null || sessionId == null) {
            image.close()
            return
        }
        try {
            val buffer = image.planes[0].buffer
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            val directory = File(activity.filesDir, "SphereCapture/$sessionId/frames").apply { mkdirs() }
            val file = File(directory, "frame-${System.currentTimeMillis()}.jpg")
            FileOutputStream(file).use { it.write(bytes) }
            activity.runOnUiThread {
                result.success(
                    mapOf(
                        "path" to file.absolutePath,
                        "capturedAtMs" to System.currentTimeMillis(),
                        "intrinsics" to cameraInfo(),
                        "quality" to mapOf("accepted" to true, "validation" to "nativeUnavailable"),
                    ),
                )
            }
        } catch (error: Exception) {
            activity.runOnUiThread { result.error("storageFailed", error.message, null) }
        } finally {
            image.close()
            pendingResult = null
            pendingSessionId = null
        }
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) = startCamera()
    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit
    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        captureSession?.close(); captureSession = null
        cameraDevice?.close(); cameraDevice = null
        return true
    }
}

package com.example.evo_mobile_camera // PAKET ADINIZI KONTROL EDİN

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.*
import android.hardware.camera2.*
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Size // Android Size
import android.view.Surface
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import io.flutter.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.*
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val TAG = "EVO_NATIVE_CAMERA"
    private val EVENT_CHANNEL_CAMERA_STREAM = "com.example.evo_mobile_camera/camera_stream"
    private val METHOD_CHANNEL_CONTROL = "com.example.evo_mobile_camera/camera_control" // Yeni kontrol kanalı
    private var cameraEventSink: EventChannel.EventSink? = null

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var previewSize: Size = Size(640, 480) // Varsayılan
    private var currentCameraId: String? = null
    private var jpegQuality: Int = 50 // Varsayılan JPEG kalitesi

    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private val CAMERA_PERMISSION_REQUEST_CODE = 1001
    private var cameraPermissionGranted = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL_CAMERA_STREAM).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    Log.d(TAG, "EventChannel: onListen")
                    cameraEventSink = events
                    checkAndSetupCamera()
                }
                override fun onCancel(arguments: Any?) {
                    Log.d(TAG, "EventChannel: onCancel")
                    closeCamera()
                    cameraEventSink = null
                }
            }
        )

        // Flutter'dan native'e komut almak için MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL_CONTROL).setMethodCallHandler { call, result ->
            Log.d(TAG, "MethodChannel call: ${call.method} with args: ${call.arguments}")
            when (call.method) {
                "initializeCamera" -> {
                    val args = call.arguments as? Map<String, Any>
                    val cameraId = args?.get("cameraId") as? String
                    val resolutionWidth = args?.get("width") as? Int
                    val resolutionHeight = args?.get("height") as? Int
                    if (cameraId != null && resolutionWidth != null && resolutionHeight != null) {
                        previewSize = Size(resolutionWidth, resolutionHeight)
                        currentCameraId = cameraId
                        // Önce mevcut kamerayı kapat, sonra yenisini aç
                        closeCamera() // Bu asenkron olabilir, dikkatli olmak lazım
                        checkAndSetupCamera() // Bu da startBackgroundThread'i çağıracak
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "Eksik veya geçersiz kamera/çözünürlük argümanları", null)
                    }
                }
                "setJpegQuality" -> {
                    val quality = call.arguments as? Int
                    if (quality != null && quality in 1..100) {
                        jpegQuality = quality
                        Log.d(TAG, "JPEG kalitesi $jpegQuality olarak ayarlandı.")
                        result.success(true)
                    } else {
                        result.error("INVALID_QUALITY", "Geçersiz JPEG kalitesi (1-100 arası olmalı)", null)
                    }
                }
                "getAvailableCameras" -> {
                    val cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    val cameras = mutableListOf<Map<String, String>>()
                    try {
                        for (id in cameraManager.cameraIdList) {
                            val characteristics = cameraManager.getCameraCharacteristics(id)
                            val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
                            val lensFacing = when (facing) {
                                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                                CameraCharacteristics.LENS_FACING_BACK -> "back"
                                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                                else -> "unknown"
                            }
                            cameras.add(mapOf("id" to id, "name" to "Camera $id ($lensFacing)"))
                        }
                        result.success(cameras)
                    } catch (e: Exception) {
                        result.error("CAMERA_LIST_ERROR", "Kamera listesi alınamadı", e.message)
                    }
                }
                 "getAvailableResolutions" -> {
                    val cameraIdForRes = call.arguments as? String ?: currentCameraId
                    if (cameraIdForRes == null) {
                        result.error("NO_CAMERA_ID", "Çözünürlük almak için kamera ID'si belirtilmedi veya seçilmedi.", null)
                        return@setMethodCallHandler
                    }
                    val cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    try {
                        val characteristics = cameraManager.getCameraCharacteristics(cameraIdForRes)
                        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                        val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
                        val resolutions = sizes?.map { mapOf("width" to it.width, "height" to it.height) }?.distinct()?.toList()
                        result.success(resolutions)
                    } catch (e: Exception) {
                        result.error("RESOLUTION_LIST_ERROR", "Çözünürlük listesi alınamadı", e.message)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun checkCameraPermission(): Boolean { /* ... aynı ... */
        cameraPermissionGranted = ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        return cameraPermissionGranted
    }
    private fun requestCameraPermission() { /* ... aynı ... */
         ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        // ... (aynı, ama setupCamera() yerine checkAndSetupCamera() çağırabilir)
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                cameraPermissionGranted = true
                setupCamera() // İzin alındı, kamerayı kur
            } else {
                cameraPermissionGranted = false
                activity.runOnUiThread {
                    eventSink?.error("PERMISSION_DENIED", "Kamera izni reddedildi.", null)
                }
            }
        }
    }

    private fun checkAndSetupCamera() {
        if (cameraPermissionGranted) {
            setupCamera()
        } else {
            requestCameraPermission() // İzin yoksa iste
        }
    }
    
    private fun setupCamera() {
        if (cameraDevice != null) { // Zaten bir kamera açıksa veya açılma sürecindeyse
            Log.w(TAG, "setupCamera: Kamera zaten açık/açılıyor (mevcut cihaz: ${cameraDevice?.id}). Önce kapatılıyor...")
            // Mevcut kamerayı kapatıp yenisini açmak için bir mekanizma gerekebilir,
            // veya bu çağrının sadece kamera null ise yapılmasını sağlamak.
            // Şimdilik, eğer currentCameraId Flutter tarafından set edilmişse onu kullanmaya çalışalım.
            if (currentCameraId == null) {
                Log.d(TAG, "currentCameraId null, kamera seçimi bekleniyor.")
                 activity.runOnUiThread { eventSink?.success(mapOf("status" to "waiting_for_camera_selection"))}
                return
            }
        } else {
             Log.d(TAG, "setupCamera: Yeni kamera kurulumu.")
        }

        startBackgroundThread()
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val camIdToOpen = currentCameraId ?: manager.cameraIdList.firstOrNull { id ->
                val characteristics = manager.getCameraCharacteristics(id)
                characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } ?: manager.cameraIdList.first() // Fallback

            if (camIdToOpen == null) throw CameraAccessException(CameraAccessException.CAMERA_ERROR, "Kamera ID bulunamadı")
            currentCameraId = camIdToOpen // Seçilen ID'yi güncelle

            val characteristics = manager.getCameraCharacteristics(camIdToOpen)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            
            // Gelen çözünürlük veya varsayılanı kullan
            Log.d(TAG, "Hedeflenen Çözünürlük: ${previewSize.width}x${previewSize.height}")
            val actualOutputSizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
            val chosenSize = actualOutputSizes?.firstOrNull { it.width == previewSize.width && it.height == previewSize.height }
                ?: actualOutputSizes?.minByOrNull { abs(it.width * it.height - previewSize.width * previewSize.height) }
                ?: previewSize // Eğer hiçbiri uymazsa gelen previewSize'ı kullanmayı dene
            
            previewSize = chosenSize // Gerçekte kullanılacak boyutu güncelle
            Log.d(TAG, "Kullanılacak GERÇEK Çözünürlük: ${previewSize.width}x${previewSize.height}")

            imageReader?.close()
            imageReader = ImageReader.newInstance(previewSize.width, previewSize.height, ImageFormat.YUV_420_888, 2)
            imageReader!!.setOnImageAvailableListener(onImageAvailableListener, backgroundHandler)
            
            if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                Log.e(TAG, "Kamera izni yok (setupCamera içi tekrar kontrol).")
                requestCameraPermission() // Tekrar izin iste, bu onError'ı tetikleyebilir.
                return
            }
            manager.openCamera(camIdToOpen, deviceStateCallback, backgroundHandler)

        } catch (e: Exception) {
            Log.e(TAG, "setupCamera hatası: ${e.message}", e)
            activity.runOnUiThread { eventSink?.error("CAMERA_SETUP_ERROR", "Kamera kurulamadı: ${e.javaClass.simpleName}", e.message) }
            closeCameraResources()
        }
    }

    private val onImageAvailableListener = ImageReader.OnImageAvailableListener { reader ->
        val image: Image? = try { reader.acquireLatestImage() } catch (e: Exception) { null }
        if (image == null) { return@OnImageAvailableListener }
        
        try {
            val jpegBytes = imageToJpeg(image, jpegQuality) // Kaliteyi config'den al
            if (jpegBytes != null && cameraEventSink != null) { // cameraEventSink olarak düzeltildi
                activity.runOnUiThread {
                    try { cameraEventSink?.success(jpegBytes) } 
                    catch (e: Exception) { Log.w(TAG, "eventSink.success çağrısında hata: $e") }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Görüntü işleme hatası (onImageAvailable): ${e.message}", e)
        } finally {
            image.close()
        }
    }
    
    // Bu fonksiyon artık renkli JPEG üretmeye çalışacak
    private fun imageToJpeg(image: Image, quality: Int): ByteArray? {
        if (image.format != ImageFormat.YUV_420_888 || image.planes.size < 3) {
             Log.e(TAG, "imageToJpeg: Desteklenmeyen format veya eksik plane. Format: ${image.format}")
            return null
        }
        try {
            val width = image.width
            val height = image.height

            val yBuffer = image.planes[0].buffer
            val uBuffer = image.planes[1].buffer
            val vBuffer = image.planes[2].buffer

            val yRowStride = image.planes[0].rowStride
            val uRowStride = image.planes[1].rowStride
            val vRowStride = image.planes[2].rowStride

            val yPixelStride = image.planes[0].pixelStride // Genellikle 1
            val uPixelStride = image.planes[1].pixelStride // Genellikle 1 veya 2 (interleaved için)
            val vPixelStride = image.planes[2].pixelStride // Genellikle 1 veya 2

            val yuvBytes = ByteArray(width * height * ImageFormat.getBitsPerPixel(ImageFormat.YUV_420_888) / 8)
            
            // Y plane kopyala
            var dstIndex = 0
            for (y in 0 until height) {
                yBuffer.position(y * yRowStride)
                yBuffer.get(yuvBytes, dstIndex, width * yPixelStride) // Her piksel için yPixelStride kadar oku
                dstIndex += width * yPixelStride
            }

            // U ve V plane'lerini NV21 formatına (Y sonra V sonra U, interleaved) dönüştürmek yerine,
            // Eğer YuvImage doğrudan YUV_420_888 planar verisini alabiliyorsa (ki sanmıyorum),
            // ya da NV21'e çevirmemiz gerekiyor.
            // Daha güvenli bir yol, Bitmap'e çevirip oradan JPEG almak olabilir ama yavaş.
            // Şimdilik YuvImage ve NV21 ile devam edelim.

            val vuOrder = true // NV21 için V önce gelir. NV12 için U önce.

            // U ve V plane'leri genellikle Y'ye göre yarı çözünürlüktedir.
            // YUV_420_888 için, U ve V plane'leri ayrıdır ve her biri (W/2) x (H/2) örnek içerir.
            // Pixel stride 1 ise, her U/V örneği 1 byte'tır.
            // Pixel stride 2 ise, U ve V interleaved olabilir (örn: UYVY değil, UVUV...).
            
            // NV21: Y plane'i tam, sonra V plane'i sonra U plane'i, interleaved. Boyut = Y + V + U
            // YYYY... VUVUVU...
            val chromaHeight = height / 2
            val chromaWidth = width / 2

            for (row in 0 until chromaHeight) {
                for (col in 0 until chromaWidth) {
                    val vAddr = row * vRowStride + col * vPixelStride
                    val uAddr = row * uRowStride + col * uPixelStride
                    
                    if (dstIndex + 1 < yuvBytes.size) {
                         if (vAddr < vBuffer.capacity() && uAddr < uBuffer.capacity()) {
                            if (vuOrder) { // NV21: V, U
                                yuvBytes[dstIndex] = vBuffer.get(vAddr)
                                yuvBytes[dstIndex + 1] = uBuffer.get(uAddr)
                            } else { // NV12: U, V (YuvImage bunu desteklemiyor olabilir)
                                yuvBytes[dstIndex] = uBuffer.get(uAddr)
                                yuvBytes[dstIndex + 1] = vBuffer.get(vAddr)
                            }
                            dstIndex += 2
                         } else { Log.w(TAG, "UV Buffer sınırı aşıldı."); break; }
                    } else { Log.w(TAG, "YUVBytes sınırı aşıldı."); break; }
                }
                 if (dstIndex + 1 >= yuvBytes.size) break
            }
            
            if (dstIndex != yuvBytes.size) {
                Log.e(TAG, "NV21 byte dizisi tam doldurulamadı. Beklenen: ${yuvBytes.size}, Doldurulan: $dstIndex")
                // return null; // Bu hatayı verirse, YUV->NV21 mantığı yanlış.
            }

            val out = ByteArrayOutputStream()
            val yuvImage = YuvImage(yuvBytes, ImageFormat.NV21, width, height, null)
            yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)
            return out.toByteArray()

        } catch (e: Exception) {
            Log.e(TAG, "imageToJpeg hatası: ${e.message}", e)
            return null
        }
    }

    private val deviceStateCallback = object : CameraDevice.StateCallback() { /* ... aynı ... */ 
        override fun onOpened(camera: CameraDevice) {
            Log.d(TAG, "Kamera açıldı: ${camera.id}")
            cameraDevice = camera
            createCameraCaptureSession()
        }
        override fun onDisconnected(camera: CameraDevice) {
            Log.w(TAG, "Kamera bağlantısı koptu: ${camera.id}")
            closeCameraResources()
        }
        override fun onError(camera: CameraDevice, error: Int) {
             val errorMsg = when(error) {
                CameraDevice.StateCallback.ERROR_CAMERA_IN_USE -> "CAMERA_IN_USE"
                CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE -> "MAX_CAMERAS_IN_USE"
                // ... diğer hata kodları
                else -> "UNKNOWN_CAMERA_ERROR_$error"
            }
            Log.e(TAG, "Kamera Cihaz Hatası: $errorMsg (${camera.id})")
            closeCameraResources()
            activity.runOnUiThread { 
                 cameraEventSink?.error("CAMERA_ERROR", "Kamera hatası: $errorMsg", null)
            }
        }
    }
    private fun createCameraCaptureSession() { /* ... aynı ... */ 
        val currentCameraDevice = cameraDevice
        val currentImageReader = imageReader
        if (currentCameraDevice == null || currentImageReader == null || currentImageReader.surface == null) {
            Log.e(TAG, "Capture session oluşturulamadı: Kamera veya ImageReader hazır değil.")
            return
        }
        try {
            val imageReaderSurface = currentImageReader.surface
            val captureRequestBuilder = currentCameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            captureRequestBuilder.addTarget(imageReaderSurface)

            currentCameraDevice.createCaptureSession(
                Collections.singletonList(imageReaderSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (cameraDevice == null) return 
                        captureSession = session
                        try {
                            captureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                            captureRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                            session.setRepeatingRequest(captureRequestBuilder.build(), null, backgroundHandler)
                            Log.d(TAG, "Kamera capture session yapılandırıldı ve akış başladı.")
                        } catch (e: Exception) { Log.e(TAG, "Capture session setRepeatingRequest hatası", e) }
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Kamera capture session yapılandırması BAŞARISIZ.")
                        activity.runOnUiThread { cameraEventSink?.error("SESSION_FAIL", "Kamera session kurulamadı", null) }
                    }
                }, backgroundHandler
            )
        } catch (e: Exception) { Log.e(TAG, "createCameraCaptureSession hatası", e) }
    }

    // Kaynakları güvenli bir şekilde kapatmak için merkezi bir metot
    private fun closeCameraResources() {
        Log.d(TAG, "Kamera kaynakları serbest bırakılıyor (closeCameraResources)...")
        try { captureSession?.stopRepeating() } catch (e: Exception) { Log.e(TAG,"CSR stopRep",e)}
        try { captureSession?.abortCaptures() } catch (e: Exception) { Log.e(TAG,"CSR abort",e)}
        try { captureSession?.close() } catch (e: Exception) { Log.e(TAG,"CSR close",e)}
        captureSession = null
        try { cameraDevice?.close() } catch (e: Exception) { Log.e(TAG,"Dev close",e)}
        cameraDevice = null
        try { imageReader?.close() } catch (e: Exception) { Log.e(TAG,"IR close",e)}
        imageReader = null
        Log.d(TAG,"Kamera kaynakları serbest bırakıldı.")
    }
    
    private fun closeCamera() {
        Log.d(TAG, "closeCamera çağrıldı (genellikle onCancel veya onDestroy).")
        // Arka plan thread'ini önce durdur, sonra kaynakları serbest bırak
        stopBackgroundThread() 
        closeCameraResources()
        Log.d(TAG, "Kamera ve arka plan thread'i durduruldu.")
    }

    override fun onPause() {
        Log.d(TAG, "onPause çağrıldı.")
        // Eğer stream aktifse ve istemci bağlı değilse kamerayı kapatmak iyi olabilir.
        // Veya sadece eventSink null ise (Flutter dinlemiyorsa)
        // if (cameraEventSink == null) { // Bu, onCancel'in zaten çağrıldığı anlamına gelebilir
        //    closeCamera()
        // }
        super.onPause()
    }

     override fun onDestroy() {
        Log.d(TAG, "onDestroy çağrıldı.")
        closeCamera()
        super.onDestroy()
    }

    private fun startBackgroundThread() { /* ... aynı ... */ 
         if (backgroundThread == null) {
            backgroundThread = HandlerThread("EvoCameraProcessingThread").also { it.start() }
            backgroundHandler = Handler(backgroundThread!!.looper)
            Log.d(TAG, "Arka plan thread'i başlatıldı.")
        }
    }
    private fun stopBackgroundThread() { /* ... aynı ... */ 
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join(250) 
            if (backgroundThread?.isAlive == true) { Log.w(TAG, "Arka plan thread'i zamanında sonlanmadı.") }
        } catch (e: InterruptedException) { Log.e(TAG, "Background thread join hatası", e)
        } finally { backgroundThread = null; backgroundHandler = null; Log.d(TAG, "Arka plan thread'i durduruldu ve null yapıldı.") }
    }
}
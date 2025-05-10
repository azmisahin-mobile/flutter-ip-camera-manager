import 'dart:async';
import 'dart:io';
import 'dart:typed_data'; // Uint8List için gerekli
import 'package:flutter/foundation.dart'; // compute fonksiyonu için
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

List<CameraDescription> cameras = [];
StreamController<List<int>>? frameStreamController;

// compute fonksiyonu için top-level veya static metot olmalı
Future<List<int>?> convertCameraImageToJpeg(CameraImage cameraImage) async {
  // Bu fonksiyon bir Isolate'ta çalışacak (compute tarafından yönetilen)
  // debugPrint("Isolate: convertCameraImageToJpeg başladı. Format Grubu: ${cameraImage.format.group}, Görüntü Boyutu: ${cameraImage.width}x${cameraImage.height}");

  if (cameraImage.planes.isEmpty) {
    debugPrint("Isolate: Hata - CameraImage planes boş!");
    return null;
  }

  final Plane yPlane = cameraImage.planes[0];
  final int width = cameraImage.width;
  final int height = cameraImage.height;
  final int rowStride = yPlane.bytesPerRow;
  final Uint8List yPlaneBytes = yPlane.bytes;

  // debugPrint("Isolate: Y Plane Detayları -> Genişlik: $width, Yükseklik: $height, Satır Adımı (RowStride): $rowStride, Gelen Bytes Uzunluğu: ${yPlaneBytes.lengthInBytes}");

  // Hedefimiz, padding'siz, sadece width*height boyutunda bir Y datası elde etmek.
  Uint8List imagePixelBytes = Uint8List(width * height);

  if (width <= 0 || height <= 0) {
    debugPrint(
      "Isolate: Hata - Geçersiz genişlik ($width) veya yükseklik ($height)",
    );
    return null;
  }

  try {
    if (rowStride == width) {
      // Padding yok, Y plane'in ilk width*height kadarını alabiliriz.
      if (yPlaneBytes.lengthInBytes >= width * height) {
        imagePixelBytes = yPlaneBytes.sublist(0, width * height);
        // debugPrint("Isolate: Y plane padding'siz, direkt sublist alındı. Boyut: ${imagePixelBytes.lengthInBytes}");
      } else {
        debugPrint(
          "Isolate: Hata - Padding yok ama Y plane boyutu ($yPlaneBytes.lengthInBytes) beklenenden küçük ($width x $height = ${width * height}).",
        );
        return null;
      }
    } else {
      // Padding var, satır satır doğru pikselleri kopyala
      // debugPrint("Isolate: Y plane padding içeriyor, satır satır kopyalanacak.");
      int dstIndex = 0;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int srcIndex = y * rowStride + x;
          if (srcIndex < yPlaneBytes.lengthInBytes) {
            imagePixelBytes[dstIndex++] = yPlaneBytes[srcIndex];
          } else {
            // Bu durum genellikle olmamalı eğer width, height, rowStride doğruysa
            debugPrint(
              "Isolate: Hata - Y plane kopyalanırken sınır aşıldı! y:$y, x:$x, srcIdx:$srcIndex, yPlaneLen:${yPlaneBytes.lengthInBytes}",
            );
            return null;
          }
        }
      }
      // debugPrint("Isolate: Y plane padding'li, satır satır kopyalandı. Hedef Boyut: ${imagePixelBytes.lengthInBytes}");
    }

    if (imagePixelBytes.lengthInBytes != width * height) {
      debugPrint(
        "Isolate: Hata - imagePixelBytes son boyutu beklenmiyor. Beklenen: ${width * height}, Gelen: ${imagePixelBytes.lengthInBytes}",
      );
      return null;
    }

    // Şimdi imagePixelBytes, width*height boyutunda, padding'siz Y verisini içermeli.
    final grayscaleImage = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: imagePixelBytes.buffer, // ByteBuffer ver
      numChannels: 1, // Gri tonlama olduğunu belirt
      format: img.Format.uint8,
    );

    final List<int> jpeg = img.encodeJpg(
      grayscaleImage,
      quality: 35,
    ); // Kaliteyi biraz artırdık
    // debugPrint("Isolate: JPEG encode başarılı, boyut: ${jpeg.length}");
    return jpeg;
  } catch (e, s) {
    debugPrint(
      "Isolate: Görüntü dönüştürme veya JPEG encode sırasında kritik hata: $e\nStack: $s",
    );
  }
  return null;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    var cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      cameraStatus = await Permission.camera.request();
    }
    if (!cameraStatus.isGranted) {
      debugPrint("Kamera izni verilmedi! Uygulama kapatılıyor.");
      // exit(1); // İzin yoksa uygulamayı kapatmak daha doğru olabilir.
      return;
    }

    cameras = await availableCameras();
    if (cameras.isEmpty) {
      debugPrint("Kullanılabilir kamera bulunamadı! Uygulama kapatılıyor.");
      // exit(1);
      return;
    }
  } catch (e) {
    debugPrint("Kamera listesi/izin alınırken kritik hata: $e");
    // exit(1);
    return;
  }
  runApp(const EvoMobileCameraApp());
}

class EvoMobileCameraApp extends StatelessWidget {
  const EvoMobileCameraApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Evo Mobile Camera',
      theme: ThemeData.dark(),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  HttpServer? _server;
  String _serverUrl = "Sunucu başlatılıyor...";
  bool _isClientConnected =
      false; // İstemci bağlı mı? MJPEG için daha iyi bir kontrol
  final int _mjpegPort = 8080;
  bool _isProcessingFrame = false; // Aynı anda tek kare işlemek için kilit

  @override
  void initState() {
    super.initState();
    if (cameras.isNotEmpty) {
      _initializeCamera(
        cameras.first,
      ); // Genellikle arka kamera daha yüksek çözünürlüklüdür
    } else {
      debugPrint(
        "initState: Kullanılabilir kamera yok, kamera başlatılamıyor.",
      );
      setState(() {
        _serverUrl = "Kamera bulunamadı!";
      });
    }
    _startServer();
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_controller != null) {
      // Eğer zaten bir controller varsa, önce onu dispose et
      await _controller!.dispose();
    }
    _controller = CameraController(
      cameraDescription,
      ResolutionPreset
          .medium, // Çözünürlüğü biraz artırdık, performansı gözlemleyin
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420, // En yaygın format
    );

    try {
      await _controller!.initialize();
      if (!mounted) {
        return;
      }
      setState(() {}); // UI'ı güncelle (önizleme için)

      debugPrint(
        "Kamera başlatıldı. Çözünürlük: ${_controller!.value.previewSize}",
      );

      _controller!.startImageStream((CameraImage image) async {
        // Sadece bir istemci bağlıysa ve önceki kare işlenmiyorsa yeni kare işle
        if (!_isClientConnected ||
            _isProcessingFrame ||
            frameStreamController == null ||
            frameStreamController!.isClosed) {
          return;
        }
        _isProcessingFrame = true; // Kilitle

        try {
          final List<int>? jpegData = await compute(
            convertCameraImageToJpeg,
            image,
          );

          if (jpegData != null && jpegData.isNotEmpty) {
            if (mounted &&
                frameStreamController != null &&
                !frameStreamController!.isClosed &&
                _isClientConnected) {
              frameStreamController!.add(jpegData);
            }
          } else if (jpegData == null) {
            // debugPrint("Ana thread: Isolate'tan null JPEG verisi geldi (dönüşüm hatası).");
          }
        } catch (e) {
          debugPrint(
            "Ana thread: compute(convertCameraImageToJpeg) çağrısında hata: $e",
          );
        } finally {
          // mounted kontrolü önemli, widget ağaçtan kaldırılmış olabilir
          if (mounted) {
            _isProcessingFrame = false; // Kilidi aç
          }
        }
      });
    } catch (e) {
      debugPrint("Kamera başlatma veya stream başlatma hatası: $e");
      if (mounted) {
        setState(() {
          _serverUrl = "Kamera hatası: ${e.toString().substring(0, 50)}...";
        });
      }
    }
  }

  Future<void> _startServer() async {
    final router = shelf_router.Router();
    // StreamController'ı her sunucu başlangıcında yeniden oluşturmak daha güvenli olabilir
    // Eğer zaten varsa ve kapalı değilse kapatıp yeniden oluştur.
    if (frameStreamController != null && !frameStreamController!.isClosed) {
      await frameStreamController!.close();
    }
    frameStreamController = StreamController<List<int>>();

    router.get('/video', (shelf.Request request) {
      if (!_isClientConnected) {
        _isClientConnected = true; // İstemci bağlandı
        if (mounted) setState(() {}); // UI'da "Streaming..." göstermek için
        debugPrint("MJPEG stream client bağlandı.");
      }

      final headers = {
        'Content-Type': 'multipart/x-mixed-replace; boundary=--frame',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
        'Connection': 'close', // Her isteğe özel bağlantı
      };

      // Yeni bir StreamController oluşturup, onun stream'ini döndür.
      // Bu, her istemci bağlantısı için ayrı bir stream sağlar.
      // Ancak MJPEG'de genellikle tek bir stream ve ona abone olan istemciler olur.
      // Bizim yapımızda, frameStreamController'a gönderilen kareler tüm dinleyicilere gider.
      // Shelf, her /video isteği için bu handler'ı çalıştırır.
      // Önemli olan, stream'in sürekli açık kalması ve yeni karelerin push edilmesi.

      return shelf.Response.ok(
        frameStreamController!.stream.transform<List<int>>(
          // <List<int>> tipini belirt
          StreamTransformer.fromHandlers(
            handleData: (jpegData, EventSink<List<int>> sink) {
              // EventSink tipini belirt
              if (jpegData.isNotEmpty) {
                final frameBytes = BytesBuilder();
                frameBytes.add("--frame\r\n".codeUnits);
                frameBytes.add("Content-Type: image/jpeg\r\n".codeUnits);
                frameBytes.add(
                  "Content-Length: ${jpegData.length}\r\n\r\n".codeUnits,
                );
                frameBytes.add(jpegData);
                frameBytes.add("\r\n".codeUnits);
                sink.add(frameBytes.toBytes());
              }
            },
            handleDone: (EventSink<List<int>> sink) {
              debugPrint(
                "MJPEG stream handleDone çağrıldı (muhtemelen frameStreamController kapandı).",
              );
              _isClientConnected = false; // İstemci bağlantısı koptu/bitti
              if (mounted) setState(() {});
              sink.close();
            },
            handleError: (
              Object error,
              StackTrace stackTrace,
              EventSink<List<int>> sink,
            ) {
              debugPrint("MJPEG stream transform error: $error\n$stackTrace");
              _isClientConnected = false;
              if (mounted) setState(() {});
              // sink.addError(error, stackTrace); // Hata akışını kesmek yerine sadece loglayıp kapatabiliriz.
              sink.close(); // Hata durumunda stream'i kapat
            },
          ),
        ),
        headers: headers,
        context: {
          'shelf.io.buffer_output': false,
        }, // Bufferlamayı kapatmayı dene (daha hızlı akış için)
      );
    });

    try {
      final ip = await NetworkInfo().getWifiIP();
      if (ip != null) {
        // Sunucuyu başlatmadan önce varsa eskisini kapat
        if (_server != null) {
          await _server!.close(force: true);
          debugPrint('Eski sunucu kapatıldı.');
        }
        _server = await shelf_io.serve(router.call, ip, _mjpegPort);
        if (mounted) {
          setState(() {
            _serverUrl = "MJPEG Stream: http://$ip:$_mjpegPort/video";
          });
        }
        debugPrint('Sunucu başlatıldı: $_serverUrl');
      } else {
        if (mounted) {
          setState(() {
            _serverUrl = "Wi-Fi IP adresi alınamadı.";
          });
        }
        debugPrint(_serverUrl);
      }
    } catch (e) {
      debugPrint("Sunucu başlatma hatası: $e");
      if (mounted) {
        setState(() {
          _serverUrl =
              "Sunucu başlatılamadı: ${e.toString().substring(0, 30)}...";
        });
      }
    }
  }

  @override
  void dispose() {
    debugPrint("CameraScreen disposing...");
    _isProcessingFrame = false;
    _isClientConnected = false; // Önemli: Bağlantı durumunu sıfırla

    // Önce image stream'i durdur
    _controller
        ?.stopImageStream()
        .then((_) {
          _controller?.dispose();
          debugPrint("CameraController disposed.");
        })
        .catchError((e) {
          debugPrint("Error stopping image stream or disposing controller: $e");
          // Controller dispose edilemese bile diğerlerini dene
          _controller?.dispose().catchError(
            (de) => debugPrint("Error disposing controller finally: $de"),
          );
        });

    _server
        ?.close(force: true)
        .then((_) {
          debugPrint("HTTP server closed.");
        })
        .catchError((e) {
          debugPrint("Error closing server: $e");
        });

    // frameStreamController'ı en son kapatmak daha güvenli olabilir
    // veya referanslarını tutan stream'ler kapandıktan sonra.
    // Ancak dispose'da olduğumuz için hemen kapatmak da mantıklı.
    if (frameStreamController != null && !frameStreamController!.isClosed) {
      frameStreamController!.close().catchError((e) {
        debugPrint("Error closing frameStreamController: $e");
      });
    }

    super.dispose();
    debugPrint("CameraScreen disposed completely.");
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Scaffold(
        // Hata durumunda da Scaffold döndür
        appBar: AppBar(title: const Text('Evo Mobile Camera')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text("Kamera başlatılıyor veya bulunamadı..."),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Evo Mobile Camera')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child:
                  controller
                          .value
                          .isInitialized //&& controller.value.isStreamingImages (bu bayrak her zaman doğru olmayabilir)
                      ? AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: CameraPreview(controller),
                      )
                      : const Text("Kamera önizlemesi bekleniyor..."),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _serverUrl,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              _isClientConnected
                  ? "Streaming to client..."
                  : "Waiting for client on http://.../video",
              style: TextStyle(
                color:
                    _isClientConnected
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

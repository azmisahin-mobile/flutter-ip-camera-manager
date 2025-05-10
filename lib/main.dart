import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:image/image.dart' as img; // compute fonksiyonu içinde import ediliyor

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// image paketini compute fonksiyonu içinde import etmek daha iyi olabilir
// veya burada global olarak import edip compute fonksiyonuna parametre olarak geçmeyebiliriz.
// Şimdilik compute içinde kalsın.

List<CameraDescription> _cameras = [];

// compute fonksiyonu için top-level veya static metot
// Bu fonksiyon CameraImage'ı alır ve JPEG byte listesi döndürür.
// 'image' paketini burada import ediyoruz, çünkü compute farklı bir isolate'ta çalışır.
Future<List<int>?> convertCameraImageToJpegWithQuality(
    ConversionParams params) async {
  final cameraImage = params.cameraImage;
  final quality = params.quality;
  final imgLib = await import('package:image/image.dart'); // Dinamik import

  // debugPrint("Isolate: convertCameraImageToJpeg çağrıldı. Format Grubu: ${cameraImage.format.group}, Boyut: ${cameraImage.width}x${cameraImage.height}");
  if (cameraImage.planes.isEmpty) {
    debugPrint("Isolate Hata: CameraImage planes boş!");
    return null;
  }

  final Plane yPlane = cameraImage.planes[0];
  final int width = cameraImage.width;
  final int height = cameraImage.height;
  final int rowStride = yPlane.bytesPerRow;
  final Uint8List yPlaneBytes = yPlane.bytes;

  Uint8List imagePixelBytes;
  if (width <= 0 || height <= 0) {
    debugPrint("Isolate Hata: Geçersiz width ($width) veya height ($height)");
    return null;
  }

  final expectedMinYSize = width * height;
  // Y plane boyutu kontrolleri
  bool sizeError = false;
  if (rowStride == width) {
    if (yPlaneBytes.lengthInBytes < expectedMinYSize) {
      debugPrint(
          "Isolate Hata: Y plane boyutu (padding yok) beklenenden küçük! Gelen: ${yPlaneBytes.lengthInBytes}, Beklenen min: $expectedMinYSize");
      sizeError = true;
    }
  } else {
    // padding var
    if (yPlaneBytes.lengthInBytes < height * rowStride) {
      debugPrint(
          "Isolate Hata: Y plane boyutu (padding var) beklenenden küçük! Gelen: ${yPlaneBytes.lengthInBytes}, Beklenen min (stride ile): ${height * rowStride}");
      sizeError = true;
    }
  }
  if (sizeError) return null;

  try {
    imagePixelBytes = Uint8List(width * height);
    if (rowStride == width) {
      imagePixelBytes.setAll(0, yPlaneBytes.sublist(0, expectedMinYSize));
    } else {
      int dstIndex = 0;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int srcIndex = y * rowStride + x;
          if (dstIndex < imagePixelBytes.length &&
              srcIndex < yPlaneBytes.lengthInBytes) {
            imagePixelBytes[dstIndex++] = yPlaneBytes[srcIndex];
          } else {
            debugPrint(
                "Isolate HATA: Y plane kopyalarken sınır aşıldı! dst:$dstIndex, src:$srcIndex");
            return null;
          }
        }
      }
    }

    if (imagePixelBytes.lengthInBytes != expectedMinYSize) {
      debugPrint(
          "Isolate HATA: imagePixelBytes son boyutu (${imagePixelBytes.lengthInBytes}) beklenmiyor ($expectedMinYSize).");
      return null;
    }

    final grayscaleImage = imgLib.Image.fromBytes(
      width: width,
      height: height,
      bytes: imagePixelBytes.buffer,
      numChannels: 1,
      format: imgLib.Format.uint8,
    );

    final List<int> jpeg = imgLib.encodeJpg(grayscaleImage, quality: quality);
    return jpeg;
  } catch (e, s) {
    debugPrint("Isolate: Görüntü dönüştürme/JPEG encode kritik hata: $e\n$s");
  }
  return null;
}

import(String s) {}

class ConversionParams {
  final CameraImage cameraImage;
  final int quality;
  ConversionParams(this.cameraImage, this.quality);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    var cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      cameraStatus = await Permission.camera.request();
    }
    if (!cameraStatus.isGranted) {
      debugPrint("Kamera izni verilmedi!");
    }
    _cameras = await availableCameras();
    if (_cameras.isEmpty && cameraStatus.isGranted) {
      debugPrint("Kullanılabilir kamera bulunamadı!");
    }
  } catch (e) {
    debugPrint("Ana başlatma (izin/kamera) hatası: $e");
  }
  runApp(const EvoMobileCameraApp());
}

class EvoMobileCameraApp extends StatelessWidget {
  const EvoMobileCameraApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Evo Native Camera UI',
      theme: ThemeData.dark().copyWith(/* ... tema ... */),
      home: const CameraInterfaceScreen(),
    );
  }
}

class CameraInterfaceScreen extends StatefulWidget {
  const CameraInterfaceScreen({super.key});
  @override
  State<CameraInterfaceScreen> createState() => _CameraInterfaceScreenState();
}

class _CameraInterfaceScreenState extends State<CameraInterfaceScreen> {
  static const String _eventChannelCameraStreamName =
      "com.example.evo_mobile_camera/camera_stream";
  static const String _methodChannelCameraControlName =
      "com.example.evo_mobile_camera/camera_control";

  final EventChannel _cameraEventChannel =
      const EventChannel(_eventChannelCameraStreamName);
  final MethodChannel _cameraControlChannel =
      const MethodChannel(_methodChannelCameraControlName);

  StreamController<List<int>>? _frameStreamController;
  HttpServer? _server;

  String _serverStatus = "Başlatılıyor...";
  String _cameraStatus = "Kamera seçiliyor...";
  String _streamUrl = "-";
  bool _isClientConnected = false;

  final int _mjpegPort = 8080;
  StreamSubscription<dynamic>? _cameraStreamSubscription;
  Uint8List? _latestFrameForPreview;
  bool _cameraPermissionGranted = false;

  String? _selectedCameraId;
  Map<String, int>? _selectedResolution;
  int _selectedJpegQuality = 60;
  List<Map<String, String>> _availableNativeCamerasList = [];
  List<Map<String, int>> _availableNativeResolutionsList = [];
  final List<ResolutionPreset> _availableResolutionsPresets =
      ResolutionPreset.values; // Stil uyarısı için final yapıldı

  @override
  void initState() {
    super.initState();
    _frameStreamController = StreamController<List<int>>.broadcast();
    _checkPermissionsAndFetchCameras();
    _startHttpServer();
  }

  Future<void> _checkPermissionsAndFetchCameras() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }
    if (mounted) {
      setState(() {
        _cameraPermissionGranted = status.isGranted;
        if (!_cameraPermissionGranted) {
          _cameraStatus = "Kamera izni reddedildi.";
        }
      });
    }
    if (_cameraPermissionGranted) {
      await _fetchAvailableCameras();
    }
  }

  Future<void> _fetchAvailableCameras() async {
    if (!_cameraPermissionGranted) {
      return;
    }
    try {
      final List<dynamic>? camerasDyn =
          await _cameraControlChannel.invokeMethod('getAvailableCameras');
      if (!mounted) {
        return;
      }
      if (camerasDyn != null) {
        _availableNativeCamerasList =
            camerasDyn.map((c) => Map<String, String>.from(c as Map)).toList();
        if (_availableNativeCamerasList.isNotEmpty) {
          _selectedCameraId = _availableNativeCamerasList.firstWhere(
              (c) => c['name']?.toLowerCase().contains('back') ?? false,
              orElse: () => _availableNativeCamerasList.first)['id'];
          await _fetchResolutionsForCamera(_selectedCameraId!);
        } else {
          if (mounted) {
            setState(() => _cameraStatus = "Native kamera bulunamadı.");
          }
        }
      }
    } catch (e) {
      debugPrint("Native kameralar alınırken hata: $e");
      if (mounted) {
        setState(() => _cameraStatus = "Kamera listesi alınamadı.");
      }
    }
  }

  Future<void> _fetchResolutionsForCamera(String cameraId) async {
    if (!_cameraPermissionGranted) {
      return;
    }
    try {
      final List<dynamic>? resolutionsDyn = await _cameraControlChannel
          .invokeMethod('getAvailableResolutions', cameraId);
      if (!mounted) {
        return;
      }
      if (resolutionsDyn != null) {
        _availableNativeResolutionsList =
            resolutionsDyn.map((r) => Map<String, int>.from(r as Map)).toList();
        _availableNativeResolutionsList.sort((a, b) =>
            (a['width']! * a['height']!).compareTo(b['width']! * b['height']!));

        if (_availableNativeResolutionsList.isNotEmpty) {
          _selectedResolution = _availableNativeResolutionsList.firstWhere(
              (r) => r['width'] == 640 && r['height'] == 480,
              orElse: () => _availableNativeResolutionsList.firstWhere(
                  (r) => r['width']! <= 800,
                  orElse: () => _availableNativeResolutionsList.length > 1
                      ? _availableNativeResolutionsList[
                          _availableNativeResolutionsList.length ~/ 2 - 1]
                      : _availableNativeResolutionsList.first));
          await _initializeNativeCamera();
        } else {
          if (mounted) {
            setState(
                () => _cameraStatus = "$cameraId için çözünürlük bulunamadı.");
          }
        }
      }
    } catch (e) {
      debugPrint("$cameraId için çözünürlük alınırken hata: $e");
      if (mounted) {
        setState(() => _cameraStatus = "Çözünürlük alınamadı.");
      }
    }
  }

  Future<void> _initializeNativeCamera() async {
    if (_selectedCameraId == null ||
        _selectedResolution == null ||
        !_cameraPermissionGranted) {
      debugPrint(
          "Kamera/çözünürlük seçilmedi veya izin yok; native başlatma atlanıyor.");
      if (mounted) {
        setState(
            () => _cameraStatus = "Kamera/çözünürlük seçin veya izin verin.");
      }
      return;
    }
    _listenToNativeCamera();

    try {
      if (mounted) {
        setState(() {
          _cameraStatus =
              "Native Kamera $_selectedCameraId (${_selectedResolution!['width']}x${_selectedResolution!['height']}) @Q$_selectedJpegQuality başlatılıyor...";
        });
      }
      await _cameraControlChannel.invokeMethod('initializeCamera', {
        'cameraId': _selectedCameraId,
        'width': _selectedResolution!['width'],
        'height': _selectedResolution!['height'],
      });
      await _cameraControlChannel.invokeMethod(
          'setJpegQuality', _selectedJpegQuality);
      if (mounted) {
        setState(() {
          _cameraStatus =
              "Native Kamera Aktif: ${_selectedResolution!['width']}x${_selectedResolution!['height']} @Q$_selectedJpegQuality";
        });
      }
    } catch (e) {
      debugPrint("Native kamera başlatma hatası: $e");
      if (mounted) {
        setState(() => _cameraStatus = "Native kamera başlatılamadı.");
      }
    }
  }

  void _listenToNativeCamera() {
    debugPrint("Native kamera olayları dinlenmeye başlıyor...");
    _cameraStreamSubscription?.cancel();
    _cameraStreamSubscription =
        _cameraEventChannel.receiveBroadcastStream().listen(
      (dynamic eventData) {
        if (eventData is Uint8List) {
          if (_frameStreamController != null &&
              !_frameStreamController!.isClosed &&
              _isClientConnected) {
            _frameStreamController!.add(eventData);
          }
          if (mounted) {
            setState(() {
              _latestFrameForPreview = eventData;
            });
          }
        } else if (eventData is Map) {
          if (eventData['status'] == 'waiting_for_camera_selection' &&
              mounted) {
            setState(() => _cameraStatus = "Lütfen bir kamera seçin.");
          } else if (eventData['error'] != null && mounted) {
            setState(
                () => _cameraStatus = "Native Hata: ${eventData['error']}");
          }
        } else if (eventData != null) {
          debugPrint(
              "Native'den beklenmedik veri tipi: ${eventData.runtimeType}");
        }
      },
      onError: (dynamic errorObject) {
        String errorMessage = errorObject.toString();
        if (errorObject is PlatformException) {
          errorMessage =
              "Platform Hatası: ${errorObject.code} - ${errorObject.message}";
        }
        debugPrint("Native Kamera EventChannel Hatası: $errorMessage");
        if (mounted) {
          setState(() => _cameraStatus = errorMessage);
        }
      },
      onDone: () {
        debugPrint("Native Kamera EventChannel Akışı Kapandı (onDone).");
        if (mounted) {
          setState(() => _cameraStatus = "Native kamera akışı durdu.");
        }
      },
      cancelOnError: false,
    );
  }

  Future<void> _startHttpServer() async {
    final router = shelf_router.Router();
    if (_frameStreamController == null || _frameStreamController!.isClosed) {
      _frameStreamController = StreamController<List<int>>.broadcast();
    }

    router.get('/video', (shelf.Request request) {
      if (!_isClientConnected && mounted) {
        setState(() => _isClientConnected = true);
        debugPrint("MJPEG stream: İstemci bağlandı.");
      }
      final headers = {
        'Content-Type': 'multipart/x-mixed-replace; boundary=--frame',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
        'Connection': 'close',
      };
      // StreamTransformer için giriş ve çıkış tiplerini belirt
      final transformer = StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (jpegData, EventSink<List<int>> sink) {
          if (jpegData.isNotEmpty) {
            final frameBytes = BytesBuilder();
            frameBytes.add("--frame\r\n".codeUnits);
            frameBytes.add("Content-Type: image/jpeg\r\n".codeUnits);
            frameBytes
                .add("Content-Length: ${jpegData.length}\r\n\r\n".codeUnits);
            frameBytes.add(jpegData);
            frameBytes.add("\r\n".codeUnits);
            try {
              sink.add(frameBytes.toBytes());
            } catch (e) {
              debugPrint("MJPEG Sink add error: $e");
              sink.close();
            }
          }
        },
        handleDone: (EventSink<List<int>> sink) {
          if (mounted) {
            setState(() => _isClientConnected = false);
          }
          sink.close();
          debugPrint("MJPEG Stream: HandleDone.");
        },
        handleError:
            (Object error, StackTrace stackTrace, EventSink<List<int>> sink) {
          if (mounted) {
            setState(() => _isClientConnected = false);
          }
          debugPrint("MJPEG Stream Transform Error: $error\n$stackTrace");
          sink.close();
        },
      );
      return shelf.Response.ok(
        _frameStreamController!.stream
            .transform(transformer), // Hata burada olmamalı artık
        headers: headers,
        context: const <String, Object>{
          'shelf.io.buffer_output': false
        }, // Düzeltildi
      );
    });

    try {
      final ip = await NetworkInfo().getWifiIP();
      if (ip != null) {
        if (_server != null) {
          await _server!.close(force: true);
        }
        _server = await shelf_io.serve(router.call, ip, _mjpegPort);
        if (mounted) {
          setState(() {
            _streamUrl = "http://$ip:$_mjpegPort/video";
            _serverStatus = "Çalışıyor";
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _streamUrl = "-";
            _serverStatus = "Wi-Fi IP alınamadı.";
          });
        }
      }
    } catch (e) {
      debugPrint("Sunucu başlatma hatası: $e");
      if (mounted) {
        setState(() {
          _streamUrl = "-";
          _serverStatus = "Sunucu hatası.";
        });
      }
    }
  }

  @override
  void dispose() {
    debugPrint("CameraInterfaceScreen disposing...");
    _isClientConnected = false;
    _cameraStreamSubscription?.cancel();
    _cameraStreamSubscription = null;

    _server
        ?.close(force: true)
        .then((_) => debugPrint("Server closed on dispose."));
    _server = null;

    if (_frameStreamController != null && !_frameStreamController!.isClosed) {
      _frameStreamController!.close();
    }
    _frameStreamController = null;

    // Native taraftaki kamerayı kapatmak için MethodChannel çağrısı (opsiyonel, onCancel halletmeli)
    // _cameraControlChannel.invokeMethod('closeCamera').catchError((e) => debugPrint("Dispose: Error invoking closeCamera on native: $e"));

    super.dispose();
    debugPrint("CameraInterfaceScreen disposed completely.");
  }

  @override
  Widget build(BuildContext context) {
    Widget previewContent;
    final latestFrame = _latestFrameForPreview;
    if (_cameraPermissionGranted &&
        latestFrame != null &&
        latestFrame.isNotEmpty) {
      // isNotEmpty eklendi
      try {
        previewContent = Image.memory(latestFrame,
            gaplessPlayback: true, fit: BoxFit.contain);
      } catch (e) {
        previewContent = Text("Önizleme hatası: $e",
            style: const TextStyle(color: Colors.red));
      }
    } else if (!_cameraPermissionGranted) {
      previewContent = Center(
          child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography,
              size: 48, color: Colors.orangeAccent),
          const SizedBox(height: 16),
          const Text("Kamera izni gerekli.",
              style: TextStyle(color: Colors.orangeAccent)),
          const SizedBox(height: 8),
          ElevatedButton(
              onPressed: _checkPermissionsAndFetchCameras,
              child: const Text("İzinleri Kontrol Et/İste"))
        ],
      ));
    } else {
      previewContent = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(_cameraStatus,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Evo Native Camera UI')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Sunucu:",
                        style: Theme.of(context).textTheme.titleMedium),
                    Text(_serverStatus),
                    const SizedBox(height: 4),
                    Text("MJPEG URL:",
                        style: Theme.of(context).textTheme.titleSmall),
                    SelectableText(_streamUrl),
                    const SizedBox(height: 4),
                    Text(
                        "İstemci: ${_isClientConnected ? 'Bağlı' : 'Bekleniyor'}",
                        style: TextStyle(
                            color: _isClientConnected
                                ? Colors.greenAccent[400]
                                : Colors.orangeAccent[400])),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Kamera Ayarları:",
                        style: Theme.of(context).textTheme.titleMedium),
                    Text(_cameraStatus,
                        style: Theme.of(context).textTheme.bodySmall),
                    if (_availableNativeCamerasList.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        decoration: const InputDecoration(
                            labelText: "Kamera Seç",
                            border: OutlineInputBorder()),
                        value: _selectedCameraId,
                        items: _availableNativeCamerasList
                            .map((camera) => DropdownMenuItem<String>(
                                value: camera["id"],
                                child: Text(
                                  camera["name"] ?? camera["id"]!,
                                  overflow: TextOverflow.ellipsis,
                                )))
                            .toList(),
                        onChanged: !_cameraPermissionGranted
                            ? null
                            : (String? newCameraId) {
                                if (newCameraId != null &&
                                    newCameraId != _selectedCameraId) {
                                  setState(() {
                                    _selectedCameraId = newCameraId;
                                    _selectedResolution = null;
                                    _availableNativeResolutionsList = [];
                                    _cameraStatus = "Çözünürlükler alınıyor...";
                                  });
                                  _fetchResolutionsForCamera(newCameraId);
                                }
                              },
                      ),
                      if (_selectedCameraId != null &&
                          _availableNativeResolutionsList.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        DropdownButtonFormField<Map<String, int>>(
                          decoration: const InputDecoration(
                              labelText: "Çözünürlük",
                              border: OutlineInputBorder()),
                          value: _selectedResolution,
                          items: _availableNativeResolutionsList
                              .map((res) => DropdownMenuItem<Map<String, int>>(
                                  value: res,
                                  child:
                                      Text("${res['width']}x${res['height']}")))
                              .toList(),
                          onChanged: (Map<String, int>? newResolution) {
                            if (newResolution != null &&
                                newResolution != _selectedResolution) {
                              setState(() {
                                _selectedResolution = newResolution;
                              });
                              _initializeNativeCamera();
                            }
                          },
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text("JPEG Kalitesi: ${_selectedJpegQuality}%",
                          style: Theme.of(context).textTheme.bodyMedium),
                      Slider(
                        value: _selectedJpegQuality.toDouble(),
                        min: 10,
                        max: 100,
                        divisions: 9,
                        label: _selectedJpegQuality.round().toString(),
                        activeColor:
                            Theme.of(context).sliderTheme.activeTrackColor,
                        inactiveColor:
                            Theme.of(context).sliderTheme.inactiveTrackColor,
                        thumbColor: Theme.of(context).sliderTheme.thumbColor,
                        onChanged: (double value) {
                          if (mounted) {
                            setState(() {
                              _selectedJpegQuality = value.round();
                            });
                          }
                        },
                        onChangeEnd: (double value) {
                          _cameraControlChannel
                              .invokeMethod('setJpegQuality',
                                  _selectedJpegQuality.round())
                              .then((_) => debugPrint(
                                  "JPEG kalitesi native'e gönderildi: $_selectedJpegQuality"))
                              .catchError((e) => debugPrint(
                                  "JPEG kalite ayarı gönderilemedi: $e"));
                        },
                      ),
                    ] else if (_cameraPermissionGranted) ...[
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: Text(
                              "Native kamera listesi yükleniyor veya bulunamadı..."))
                    ] else ...[
                      Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Column(
                            children: [
                              const Text("Kamera izni gerekli."),
                              ElevatedButton(
                                  onPressed: _checkPermissionsAndFetchCameras,
                                  child: const Text("İzinleri Kontrol Et/İste"))
                            ],
                          ))
                    ]
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    color: Colors.black54,
                    child: Center(child: previewContent),
                  )),
            ),
          ],
        ),
      ),
    );
  }
}

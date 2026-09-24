import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../../config/constants.dart';

/// Provides live camera preview + periodic silent JPEG sampling for Gemini.
/// Adapted for watch — uses the device's built-in camera.
class WatchCameraService {
  CameraController? _controller;
  Timer? _sampleTimer;
  final _frames = StreamController<Uint8List>.broadcast();
  bool _capturing = false;
  bool _encoding = false;
  CameraImage? _latestImage;
  CameraConfig _config = const CameraConfig();
  int _frameCount = 0;

  Stream<Uint8List> get frames => _frames.stream;
  CameraController? get controller => _controller;
  bool get isCapturing => _capturing;

  Future<void> start({
    CameraLensDirection lens = CameraLensDirection.front,
    CameraConfig config = const CameraConfig(),
  }) async {
    if (_capturing) return;
    _config = config;
    _frameCount = 0;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw Exception('No cameras available');
    }

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == lens,
      orElse: () => cameras.first,
    );

    debugPrint('[WATCH_CAM] Starting camera: ${camera.name}, '
        'sensor=${camera.sensorOrientation}°, '
        'resolution=${_config.resolution}, '
        'rotation=${_config.rotation}°, '
        'aspect=${_config.aspectRatio}, '
        'quality=${_config.quality}');

    _controller = CameraController(
      camera,
      _config.resolutionPreset,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    await _controller!.initialize();
    await _controller!.setFlashMode(FlashMode.off);

    await _controller!.startImageStream((image) {
      _latestImage = image;
    });

    _capturing = true;

    _sampleTimer = Timer.periodic(
      Duration(milliseconds: 1000 ~/ AppConstants.maxFps),
      (_) => _sampleFrame(),
    );
  }

  Future<void> updateConfig(CameraConfig config) async {
    final resolutionChanged = config.resolution != _config.resolution;
    _config = config;

    if (resolutionChanged && _capturing) {
      final lens = _controller?.description.lensDirection ??
          CameraLensDirection.front;
      await stop();
      await start(lens: lens, config: _config);
    }
  }

  Future<void> _sampleFrame() async {
    if (!_capturing || _encoding || _latestImage == null) return;

    final image = _latestImage!;
    final width = image.width;
    final height = image.height;
    final quality = _config.quality;
    final rotation = _config.rotation;
    final mirror = _config.mirror;
    final aspectRatio = _config.aspectRatio;

    _encoding = true;
    try {
      Uint8List? jpeg;
      if (Platform.isAndroid) {
        final yBytes = Uint8List.fromList(image.planes[0].bytes);
        final uBytes = Uint8List.fromList(image.planes[1].bytes);
        final vBytes = Uint8List.fromList(image.planes[2].bytes);
        final yRowStride = image.planes[0].bytesPerRow;
        final uvRowStride = image.planes[1].bytesPerRow;
        final uvPixelStride = image.planes[1].bytesPerPixel ?? 1;
        jpeg = await compute(_encodeYuv420ToJpeg, (
          yBytes, uBytes, vBytes,
          width, height,
          yRowStride, uvRowStride, uvPixelStride,
          quality, rotation, mirror, aspectRatio,
        ));
      } else {
        jpeg = await compute(_encodeBgraToJpeg, (
          Uint8List.fromList(image.planes[0].bytes),
          width, height,
          quality, rotation, mirror, aspectRatio,
        ));
      }
      if (jpeg != null && _capturing) {
        _frameCount++;
        if (_frameCount <= 3 || _frameCount % 10 == 0) {
          debugPrint('[WATCH_CAM] Frame #$_frameCount: ${jpeg.length} bytes, '
              'src=${width}x$height');
        }
        _frames.add(jpeg);
      }
    } catch (e) {
      debugPrint('[WATCH_CAM] Encode error: $e');
    } finally {
      _encoding = false;
    }
  }

  Future<void> stop() async {
    _capturing = false;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _latestImage = null;
    if (_controller?.value.isStreamingImages ?? false) {
      await _controller?.stopImageStream();
    }
    await _controller?.dispose();
    _controller = null;
  }

  void dispose() {
    stop();
    _frames.close();
  }
}

/// Center-crop image to target aspect ratio.
img.Image _cropToAspect(img.Image image, String aspectRatio) {
  if (aspectRatio == 'original') return image;

  final double targetRatio = switch (aspectRatio) {
    'landscape' => 4.0 / 3.0,
    'portrait' => 3.0 / 4.0,
    'square' => 1.0,
    _ => image.width / image.height, // original
  };

  final double currentRatio = image.width / image.height;
  if ((currentRatio - targetRatio).abs() < 0.01) return image;

  int cropW, cropH;
  if (currentRatio > targetRatio) {
    // Too wide — crop width
    cropH = image.height;
    cropW = (cropH * targetRatio).round();
  } else {
    // Too tall — crop height
    cropW = image.width;
    cropH = (cropW / targetRatio).round();
  }

  cropW = math.min(cropW, image.width);
  cropH = math.min(cropH, image.height);

  final x = (image.width - cropW) ~/ 2;
  final y = (image.height - cropH) ~/ 2;

  return img.copyCrop(image, x: x, y: y, width: cropW, height: cropH);
}

img.Image _applyTransforms(
    img.Image image, int rotation, bool mirror, String aspectRatio) {
  if (mirror) {
    image = img.flipHorizontal(image);
  }
  if (rotation != 0) {
    image = img.copyRotate(image, angle: rotation);
  }
  // Crop to aspect ratio after rotation
  image = _cropToAspect(image, aspectRatio);
  return image;
}

Uint8List? _encodeBgraToJpeg(
    (Uint8List, int, int, int, int, bool, String) params) {
  final (bytes, width, height, quality, rotation, mirror, aspectRatio) = params;
  try {
    var image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      order: img.ChannelOrder.bgra,
    );
    image = _applyTransforms(image, rotation, mirror, aspectRatio);
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  } catch (_) {
    return null;
  }
}

Uint8List? _encodeYuv420ToJpeg(
    (Uint8List, Uint8List, Uint8List, int, int, int, int, int, int, int, bool,
            String)
        params) {
  final (yBytes, uBytes, vBytes, width, height, yRowStride, uvRowStride,
      uvPixelStride, quality, rotation, mirror, aspectRatio) = params;
  try {
    var image = img.Image(width: width, height: height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yRowStride + x;
        final uvIndex = (y >> 1) * uvRowStride + (x >> 1) * uvPixelStride;

        final yVal = yBytes[yIndex];
        final uVal = uBytes[uvIndex];
        final vVal = vBytes[uvIndex];

        int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
        int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128))
            .round()
            .clamp(0, 255);
        int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

        image.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    image = _applyTransforms(image, rotation, mirror, aspectRatio);
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  } catch (_) {
    return null;
  }
}

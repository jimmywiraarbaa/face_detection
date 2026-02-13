import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/face_detector_service.dart';
import '../services/face_recognition_service.dart';
import '../services/face_storage_service.dart';
import '../services/image_quality_service.dart';

enum FacePosition {
  center,
  up,
  down,
  left,
  right,
}

class FaceRegistrationScreen extends StatefulWidget {
  final String name;

  const FaceRegistrationScreen({
    super.key,
    required this.name,
  });

  @override
  State<FaceRegistrationScreen> createState() => _FaceRegistrationScreenState();
}

class _FaceRegistrationScreenState extends State<FaceRegistrationScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  final FaceRecognitionService _faceRecognitionService = FaceRecognitionService();
  final FaceStorageService _faceStorageService = FaceStorageService();
  final ImageQualityService _imageQualityService = ImageQualityService();

  List<Face> _detectedFaces = [];
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  bool _isInBackground = false;
  String? _errorMessage;
  bool _isHeadPositionCorrect = false;
  String? _headPositionFeedback;
  ImageQualityResult? _imageQualityResult;

  Timer? _captureTimer;
  final Map<FacePosition, List<List<double>>> _capturedEmbeddings = {
    FacePosition.center: [],
    FacePosition.up: [],
    FacePosition.down: [],
    FacePosition.left: [],
    FacePosition.right: [],
  };
  FacePosition _currentPosition = FacePosition.center;

  static const int _requiredFramesPerPosition = 3;
  static const int _minFramesPerPosition = 2;

  List<CameraDescription> _cameras = [];
  int _currentCameraIndex = 0;

  bool get _isFrontCamera {
    if (_cameras.isEmpty || _currentCameraIndex >= _cameras.length) {
      return false;
    }
    return _cameras[_currentCameraIndex].lensDirection == CameraLensDirection.front;
  }

  String _getPositionLabel(FacePosition position) {
    switch (position) {
      case FacePosition.center:
        return 'Lihat ke depan';
      case FacePosition.up:
        return 'Lihat ke atas';
      case FacePosition.down:
        return 'Lihat ke bawah';
      case FacePosition.left:
        return 'Lihat ke kiri';
      case FacePosition.right:
        return 'Lihat ke kanan';
    }
  }

  String _getPositionInstruction(FacePosition position) {
    switch (position) {
      case FacePosition.center:
        return 'Posisikan wajah Anda di tengah lingkaran';
      case FacePosition.up:
        return 'Miringkan kepala ke atas';
      case FacePosition.down:
        return 'Miringkan kepala ke bawah';
      case FacePosition.left:
        return 'Miringkan kepala ke kiri';
      case FacePosition.right:
        return 'Miringkan kepala ke kanan';
    }
  }

  String _getPositionNumber(FacePosition position) {
    final index = FacePosition.values.indexOf(position);
    return '${index + 1}';
  }

  double get _currentPositionProgress {
    final captured = _capturedEmbeddings[_currentPosition]?.length ?? 0;
    return captured / _requiredFramesPerPosition;
  }

  /// Check if the head rotation matches the required position
  bool _checkHeadPosition(Face face) {
    var headEulerAngleX = face.headEulerAngleX ?? 0;
    var headEulerAngleY = face.headEulerAngleY ?? 0;

    if (_isFrontCamera) {
      headEulerAngleY = -headEulerAngleY;
      headEulerAngleX = -headEulerAngleX;
    }

    switch (_currentPosition) {
      case FacePosition.center:
        final isCenter = headEulerAngleX.abs() < 15 && headEulerAngleY.abs() < 15;
        if (!isCenter) {
          _headPositionFeedback = 'Lihat lurus ke depan';
        }
        return isCenter;

      case FacePosition.up:
        final isUp = headEulerAngleX < -10 && headEulerAngleX > -50;
        if (!isUp) {
          if (headEulerAngleX > -5) {
            _headPositionFeedback = 'Miringkan kepala lebih ke atas';
          } else if (headEulerAngleX < -50) {
            _headPositionFeedback = 'Terlalu atas, turunkan sedikit';
          }
        }
        return isUp;

      case FacePosition.down:
        final isDown = headEulerAngleX > 10 && headEulerAngleX < 50;
        if (!isDown) {
          if (headEulerAngleX < 5) {
            _headPositionFeedback = 'Miringkan kepala lebih ke bawah';
          } else if (headEulerAngleX > 50) {
            _headPositionFeedback = 'Terlalu bawah, angkat sedikit';
          }
        }
        return isDown;

      case FacePosition.left:
        final isLeft = headEulerAngleY < -15 && headEulerAngleY > -60;
        if (!isLeft) {
          if (headEulerAngleY > -10) {
            _headPositionFeedback = 'Putar kepala lebih ke kiri';
          } else if (headEulerAngleY < -60) {
            _headPositionFeedback = 'Terlalu kiri, putar sedikit ke kanan';
          }
        }
        return isLeft;

      case FacePosition.right:
        final isRight = headEulerAngleY > 15 && headEulerAngleY < 60;
        if (!isRight) {
          if (headEulerAngleY < 10) {
            _headPositionFeedback = 'Putar kepala lebih ke kanan';
          } else if (headEulerAngleY > 60) {
            _headPositionFeedback = 'Terlalu kanan, putar sedikit ke kiri';
          }
        }
        return isRight;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _loadFaceRecognitionModel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _isInBackground = true;
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      _isInBackground = false;
      _initializeCamera();
    }
  }

  Future<void> _loadFaceRecognitionModel() async {
    await _faceRecognitionService.loadModel();
  }

  Future<void> _stopCamera() async {
    _stopCapture();
    await _cameraController?.dispose();
    _cameraController = null;

    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
        _detectedFaces = [];
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (_isInBackground) {
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = 'No cameras available';
          });
        }
        return;
      }

      _currentCameraIndex = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
      if (_currentCameraIndex == -1) {
        _currentCameraIndex = 0;
      }

      await _initCameraController(_currentCameraIndex);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error initializing camera: $e';
        });
      }
    }
  }

  Future<void> _initCameraController(int cameraIndex) async {
    await _cameraController?.dispose();
    _stopCapture();

    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
        _detectedFaces = [];
      });
    }

    _cameraController = CameraController(
      _cameras[cameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
    );

    await _cameraController!.initialize();

    if (mounted) {
      setState(() {
        _isCameraInitialized = true;
        _errorMessage = null;
      });

      _startCapture();
    }
  }

  void _startCapture() {
    if (_isInBackground) {
      return;
    }

    _captureTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_isProcessing || _isInBackground) {
        return;
      }
      _captureFrame();
    });
  }

  void _stopCapture() {
    _captureTimer?.cancel();
    _captureTimer = null;
    _isProcessing = false;
  }

  Future<void> _captureFrame() async {
    if (_isProcessing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isInBackground) {
      return;
    }

    final currentFrames = _capturedEmbeddings[_currentPosition] ?? [];
    if (currentFrames.length >= _requiredFramesPerPosition) {
      return;
    }

    _isProcessing = true;
    _headPositionFeedback = null;
    _imageQualityResult = null;

    try {
      final image = await _cameraController!.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);

      await _faceDetectorService.detectFacesFromImage(inputImage);

      if (mounted && !_isInBackground && _faceDetectorService.faces.isNotEmpty) {
        final face = _faceDetectorService.faces.first;
        final isPositionCorrect = _checkHeadPosition(face);

        // Check image quality
        final qualityResult = await _imageQualityService.checkImageQuality(image.path);

        setState(() {
          _isHeadPositionCorrect = isPositionCorrect;
          _detectedFaces = _faceDetectorService.faces;
          _imageQualityResult = qualityResult;
        });

        if (isPositionCorrect && qualityResult.isGood) {
          final embedding = await _faceRecognitionService.getFaceEmbedding(image.path, face);

          setState(() {
            _capturedEmbeddings[_currentPosition]!.add(embedding);
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isHeadPositionCorrect = false;
            _detectedFaces = _faceDetectorService.faces;
            _imageQualityResult = null;
          });
        }
      }

      try {
        final file = File(image.path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(() {
          _isHeadPositionCorrect = false;
          _detectedFaces = [];
          _imageQualityResult = null;
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  void _moveToNextPosition() {
    final positions = FacePosition.values;
    final currentIndex = positions.indexOf(_currentPosition);

    if (currentIndex < positions.length - 1) {
      setState(() {
        _currentPosition = positions[currentIndex + 1];
        _isHeadPositionCorrect = false;
        _headPositionFeedback = null;
        _detectedFaces = [];
      });
    } else {
      _stopCapture();
      _finalizeRegistration();
    }
  }

  Future<void> _finalizeRegistration() async {
    final allEmbeddings = <List<double>>[];
    for (final embeddings in _capturedEmbeddings.values) {
      allEmbeddings.addAll(embeddings);
    }

    if (allEmbeddings.length < FacePosition.values.length * _minFramesPerPosition) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Need at least ${FacePosition.values.length * _minFramesPerPosition} frames. Only captured ${allEmbeddings.length}'),
          ),
        );
        _startCapture();
      }
      return;
    }

    try {
      await _faceStorageService.saveFace(widget.name, allEmbeddings);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.name} registered successfully with ${allEmbeddings.length} frames!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to register face: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCapture();
    _cameraController?.dispose();
    _faceDetectorService.dispose();
    _faceRecognitionService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) async {
        await _stopCamera();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Register: ${widget.name}'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Error',
                style: TextStyle(fontSize: 32, color: Colors.red, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: const TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  if (mounted) {
                    setState(() {
                      _errorMessage = null;
                    });
                  }
                  _initializeCamera();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isCameraInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        Center(child: CameraPreview(_cameraController!)),
        FaceOverlay(
          faces: _detectedFaces,
          imageSize: Size(
            _cameraController!.value.previewSize!.height,
            _cameraController!.value.previewSize!.width,
          ),
          isFrontCamera: _isFrontCamera,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          child: FacePositioningGuide(
            currentPosition: _currentPosition,
          ),
        ),
        // Current position indicator
        Positioned(
          top: 70,
          left: 20,
          right: 20,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(180),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(
                  _getPositionLabel(_currentPosition),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  _getPositionInstruction(_currentPosition),
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_headPositionFeedback != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _headPositionFeedback!,
                      style: TextStyle(
                        color: _isHeadPositionCorrect ? Colors.green : Colors.orange,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                // Image quality feedback
                if (_imageQualityResult != null && !_imageQualityResult!.isGood)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _imageQualityService.getFeedbackMessage(_imageQualityResult!),
                      style: TextStyle(
                        color: _imageQualityService.getIndicatorColor(_imageQualityResult!),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Frame counter
        Positioned(
          top: 200,
          left: 0,
          right: 0,
          child: Center(
            child: Text(
              '${_capturedEmbeddings[_currentPosition]!.length} / $_requiredFramesPerPosition',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 48,
                fontWeight: FontWeight.bold,
                shadows: [
                  Shadow(
                    color: Colors.black,
                    blurRadius: 10,
                  ),
                ],
              ),
            ),
          ),
        ),
        // Progress section
        Positioned(
          bottom: 100,
          left: 20,
          right: 20,
          child: Column(
            children: [
              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _currentPositionProgress,
                  minHeight: 8,
                  backgroundColor: Colors.grey.withAlpha(100),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _currentPositionProgress >= 1.0 ? Colors.green : Colors.blue,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Position indicators
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: FacePosition.values.map((position) {
                  final frames = _capturedEmbeddings[position]?.length ?? 0;
                  final isComplete = frames >= _requiredFramesPerPosition;
                  final isCurrent = position == _currentPosition;

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: isComplete
                            ? Colors.green
                            : isCurrent
                                ? Colors.blue
                                : Colors.grey.withAlpha(100),
                        shape: BoxShape.circle,
                        border: isCurrent
                            ? Border.all(color: Colors.white, width: 2)
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          _getPositionNumber(position),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              // Status text
              Text(
                _capturedEmbeddings[_currentPosition]!.length >= _requiredFramesPerPosition
                    ? 'Posisi selesai! Tekan LANJUT untuk lanjut'
                    : 'Posisi ${FacePosition.values.indexOf(_currentPosition) + 1} dari ${FacePosition.values.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              // Detection status
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: _detectedFaces.isEmpty
                      ? Colors.red.withAlpha(200)
                      : (_imageQualityResult != null && !_imageQualityResult!.isGood)
                          ? Colors.red.withAlpha(200)
                          : _isHeadPositionCorrect
                              ? Colors.green.withAlpha(200)
                              : Colors.orange.withAlpha(200),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _detectedFaces.isEmpty
                      ? 'Tidak ada wajah'
                      : _imageQualityResult != null && !_imageQualityResult!.isGood
                          ? _imageQualityService.getFeedbackMessage(_imageQualityResult!)
                          : _isHeadPositionCorrect
                              ? 'Posisi tepat! Mengcapture...'
                              : 'Posisi kurang tepat',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Top buttons
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Row(
            children: [
              // Cancel button
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    _stopCapture();
                    Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                  ),
                  child: const Text('BATAL', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              // Skip button
              if (_capturedEmbeddings[_currentPosition]!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      if (_capturedEmbeddings[_currentPosition]!.length >= _minFramesPerPosition) {
                        _moveToNextPosition();
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Minimal $_minFramesPerPosition frame diperlukan untuk skip'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                    ),
                    child: const Text('LEWATI', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
              // Next button
              if (_capturedEmbeddings[_currentPosition]!.length >= _requiredFramesPerPosition) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _moveToNextPosition,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('LANJUT', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class FaceOverlay extends StatelessWidget {
  final List<Face> faces;
  final Size imageSize;
  final bool isFrontCamera;

  const FaceOverlay({
    super.key,
    required this.faces,
    required this.imageSize,
    required this.isFrontCamera,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: FaceOverlayPainter(
        faces: faces,
        imageSize: imageSize,
        isFrontCamera: isFrontCamera,
      ),
    );
  }
}

class FaceOverlayPainter extends CustomPainter {
  final List<Face> faces;
  final Size imageSize;
  final bool isFrontCamera;

  FaceOverlayPainter({
    required this.faces,
    required this.imageSize,
    required this.isFrontCamera,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.green;

    for (final face in faces) {
      final boundingBox = face.boundingBox;

      final scaleX = size.width / imageSize.width;
      final scaleY = size.height / imageSize.height;

      double left = boundingBox.left * scaleX;
      double right = boundingBox.right * scaleX;
      double top = boundingBox.top * scaleY;
      double bottom = boundingBox.bottom * scaleY;

      if (isFrontCamera) {
        final temp = left;
        left = size.width - right;
        right = size.width - temp;
      }

      final rect = Rect.fromLTRB(left, top, right, bottom);
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) {
    return oldDelegate.faces != faces || oldDelegate.isFrontCamera != isFrontCamera;
  }
}

class FacePositioningGuide extends StatelessWidget {
  final FacePosition currentPosition;

  const FacePositioningGuide({
    super.key,
    required this.currentPosition,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;

        final ovalWidth = screenWidth * 0.6;
        final ovalHeight = screenHeight * 0.5;

        return CustomPaint(
          size: Size(screenWidth, screenHeight),
          painter: FacePositioningGuidePainter(
            ovalWidth: ovalWidth,
            ovalHeight: ovalHeight,
            currentPosition: currentPosition,
          ),
        );
      },
    );
  }
}

class FacePositioningGuidePainter extends CustomPainter {
  final double ovalWidth;
  final double ovalHeight;
  final FacePosition currentPosition;

  FacePositioningGuidePainter({
    required this.ovalWidth,
    required this.ovalHeight,
    required this.currentPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final ovalRect = Rect.fromCenter(
      center: center,
      width: ovalWidth,
      height: ovalHeight,
    );

    // Draw outer glow
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = Colors.white.withAlpha(40)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawOval(ovalRect, glowPaint);

    // Draw main oval outline
    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withAlpha(180);
    canvas.drawOval(ovalRect, outlinePaint);

    // Draw directional indicator
    final indicatorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.cyan
      ..strokeCap = StrokeCap.round;

    final indicatorSize = 35.0;
    final indicatorOffset = 25.0;

    switch (currentPosition) {
      case FacePosition.center:
        // Draw center dot
        final centerPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.green.withAlpha(180);
        canvas.drawCircle(center, 15, centerPaint);
        break;

      case FacePosition.up:
        final arrowStart = Offset(center.dx, center.dy - indicatorOffset);
        _drawUpArrow(canvas, arrowStart, indicatorSize, indicatorPaint);
        break;

      case FacePosition.down:
        final arrowStart = Offset(center.dx, center.dy + indicatorOffset);
        _drawDownArrow(canvas, arrowStart, indicatorSize, indicatorPaint);
        break;

      case FacePosition.left:
        final arrowStart = Offset(center.dx - indicatorOffset, center.dy);
        _drawLeftArrow(canvas, arrowStart, indicatorSize, indicatorPaint);
        break;

      case FacePosition.right:
        final arrowStart = Offset(center.dx + indicatorOffset, center.dy);
        _drawRightArrow(canvas, arrowStart, indicatorSize, indicatorPaint);
        break;
    }

    // Draw corner brackets
    final bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withAlpha(120)
      ..strokeCap = StrokeCap.round;

    final bracketLength = 25.0;
    final cornerRadius = 15.0;

    // Top-left corner
    final topLeft = Offset(ovalRect.left + cornerRadius, ovalRect.top + cornerRadius);
    canvas.drawLine(
      Offset(ovalRect.left - 8, topLeft.dy),
      Offset(topLeft.dx - bracketLength / 2, topLeft.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(topLeft.dx, ovalRect.top - 8),
      Offset(topLeft.dx, topLeft.dy - bracketLength / 2),
      bracketPaint,
    );

    // Top-right corner
    final topRight = Offset(ovalRect.right - cornerRadius, ovalRect.top + cornerRadius);
    canvas.drawLine(
      Offset(topRight.dx + bracketLength / 2, topRight.dy),
      Offset(ovalRect.right + 8, topRight.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(topRight.dx, ovalRect.top - 8),
      Offset(topRight.dx, topRight.dy - bracketLength / 2),
      bracketPaint,
    );

    // Bottom-left corner
    final bottomLeft = Offset(ovalRect.left + cornerRadius, ovalRect.bottom - cornerRadius);
    canvas.drawLine(
      Offset(ovalRect.left - 8, bottomLeft.dy),
      Offset(bottomLeft.dx - bracketLength / 2, bottomLeft.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(bottomLeft.dx, ovalRect.bottom + 8),
      Offset(bottomLeft.dx, bottomLeft.dy + bracketLength / 2),
      bracketPaint,
    );

    // Bottom-right corner
    final bottomRight = Offset(ovalRect.right - cornerRadius, ovalRect.bottom - cornerRadius);
    canvas.drawLine(
      Offset(bottomRight.dx + bracketLength / 2, bottomRight.dy),
      Offset(ovalRect.right + 8, bottomRight.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(bottomRight.dx, ovalRect.bottom + 8),
      Offset(bottomRight.dx, bottomRight.dy + bracketLength / 2),
      bracketPaint,
    );
  }

  void _drawUpArrow(Canvas canvas, Offset start, double size, Paint paint) {
    final path = Path();
    path.moveTo(start.dx, start.dy - size);
    path.lineTo(start.dx - size / 2, start.dy);
    path.moveTo(start.dx, start.dy - size);
    path.lineTo(start.dx + size / 2, start.dy);
    canvas.drawPath(path, paint);
  }

  void _drawDownArrow(Canvas canvas, Offset start, double size, Paint paint) {
    final path = Path();
    path.moveTo(start.dx, start.dy + size);
    path.lineTo(start.dx - size / 2, start.dy);
    path.moveTo(start.dx, start.dy + size);
    path.lineTo(start.dx + size / 2, start.dy);
    canvas.drawPath(path, paint);
  }

  void _drawLeftArrow(Canvas canvas, Offset start, double size, Paint paint) {
    final path = Path();
    path.moveTo(start.dx - size, start.dy);
    path.lineTo(start.dx, start.dy - size / 2);
    path.moveTo(start.dx - size, start.dy);
    path.lineTo(start.dx, start.dy + size / 2);
    canvas.drawPath(path, paint);
  }

  void _drawRightArrow(Canvas canvas, Offset start, double size, Paint paint) {
    final path = Path();
    path.moveTo(start.dx + size, start.dy);
    path.lineTo(start.dx, start.dy - size / 2);
    path.moveTo(start.dx + size, start.dy);
    path.lineTo(start.dx, start.dy + size / 2);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(FacePositioningGuidePainter oldDelegate) {
    return oldDelegate.ovalWidth != ovalWidth ||
        oldDelegate.ovalHeight != ovalHeight ||
        oldDelegate.currentPosition != currentPosition;
  }
}

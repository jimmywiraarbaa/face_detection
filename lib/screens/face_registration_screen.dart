import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/face_detector_service.dart';
import '../services/face_recognition_service.dart';
import '../services/face_storage_service.dart';

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

  List<Face> _detectedFaces = [];
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  bool _isInBackground = false;
  String? _errorMessage;
  bool _isHeadPositionCorrect = false;
  String? _headPositionFeedback;

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

  String _getPositionIcon(FacePosition position) {
    switch (position) {
      case FacePosition.center:
        return '😐';
      case FacePosition.up:
        return '😃';
      case FacePosition.down:
        return '😔';
      case FacePosition.left:
        return '🙁';
      case FacePosition.right:
        return '😊';
    }
  }

  double get _currentPositionProgress {
    final captured = _capturedEmbeddings[_currentPosition]?.length ?? 0;
    return captured / _requiredFramesPerPosition;
  }

  /// Check if the head rotation matches the required position
  bool _checkHeadPosition(Face face) {
    var headEulerAngleX = face.headEulerAngleX ?? 0; // Up/Down rotation
    var headEulerAngleY = face.headEulerAngleY ?? 0; // Left/Right rotation

    // Flip angles for front camera because the preview is mirrored
    if (_isFrontCamera) {
      headEulerAngleY = -headEulerAngleY;
      headEulerAngleX = -headEulerAngleX;
    }

    switch (_currentPosition) {
      case FacePosition.center:
        // Face should be relatively straight (within 15 degrees)
        final isCenter = headEulerAngleX.abs() < 15 && headEulerAngleY.abs() < 15;
        if (!isCenter) {
          _headPositionFeedback = 'Lihat lurus ke depan';
        }
        return isCenter;

      case FacePosition.up:
        // Head should be tilted up (X angle should be negative, around -15 to -45 degrees)
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
        // Head should be tilted down (X angle should be positive, around 15 to 45 degrees)
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
        // Head should be turned left (Y angle should be negative for looking left)
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
        // Head should be turned right (Y angle should be positive for looking right)
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
      // Stop capturing when position is complete, wait for user to press "Next Position" button
      return;
    }

    _isProcessing = true;
    _headPositionFeedback = null;

    try {
      // Always try to capture and detect faces
      final image = await _cameraController!.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);

      // Detect faces from the captured image
      await _faceDetectorService.detectFacesFromImage(inputImage);

      if (mounted && !_isInBackground && _faceDetectorService.faces.isNotEmpty) {
        final face = _faceDetectorService.faces.first;

        // Check if head position matches required position
        final isPositionCorrect = _checkHeadPosition(face);

        setState(() {
          _isHeadPositionCorrect = isPositionCorrect;
          _detectedFaces = _faceDetectorService.faces;
        });

        // Only capture and save embedding if head position is correct
        if (isPositionCorrect) {
          final embedding = await _faceRecognitionService.getFaceEmbedding(image.path, face);

          setState(() {
            _capturedEmbeddings[_currentPosition]!.add(embedding);
          });
        }
      } else {
        // Update detected faces even if no face found (for UI indicator)
        if (mounted) {
          setState(() {
            _isHeadPositionCorrect = false;
            _detectedFaces = _faceDetectorService.faces;
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
      // Update detected faces on error (for UI indicator)
      if (mounted) {
        setState(() {
          _isHeadPositionCorrect = false;
          _detectedFaces = [];
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
      // All positions complete
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
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
        // Face positioning guideline
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
          top: 80,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text(
                    _getPositionIcon(_currentPosition),
                    style: const TextStyle(fontSize: 48),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _getPositionLabel(_currentPosition),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _getPositionInstruction(_currentPosition),
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 14,
                    ),
                  ),
                  // Head position feedback
                  if (_headPositionFeedback != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isHeadPositionCorrect ? Icons.check_circle : Icons.info_outline,
                            color: _isHeadPositionCorrect ? Colors.green : Colors.orange,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _headPositionFeedback!,
                            style: TextStyle(
                              color: _isHeadPositionCorrect ? Colors.green : Colors.orange,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
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
                fontSize: 36,
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
        // Progress bar for current position
        Positioned(
          bottom: 120,
          left: 40,
          right: 40,
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LinearProgressIndicator(
                  value: _currentPositionProgress,
                  minHeight: 12,
                  backgroundColor: Colors.grey.withAlpha(100),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _currentPositionProgress >= 1.0
                        ? Colors.green
                        : Colors.blue,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Overall progress indicator
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: FacePosition.values.map((position) {
                  final frames = _capturedEmbeddings[position]?.length ?? 0;
                  final isComplete = frames >= _requiredFramesPerPosition;
                  final isCurrent = position == _currentPosition;

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Container(
                      width: 40,
                      height: 40,
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
                          _getPositionIcon(position),
                          style: const TextStyle(fontSize: 20),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              Text(
                _capturedEmbeddings[_currentPosition]!.length >= _requiredFramesPerPosition
                    ? 'Posisi selesai! Tekan tombol panah hijau untuk lanjut'
                    : 'Posisi ${FacePosition.values.indexOf(_currentPosition) + 1} dari ${FacePosition.values.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        // Face detection indicator
        Positioned(
          bottom: 220,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _detectedFaces.isEmpty
                    ? Colors.red.withAlpha(200)
                    : _isHeadPositionCorrect
                        ? Colors.green.withAlpha(200)
                        : Colors.orange.withAlpha(200),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _detectedFaces.isEmpty
                        ? Icons.face_outlined
                        : _isHeadPositionCorrect
                            ? Icons.check_circle
                            : Icons.info_outline,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _detectedFaces.isEmpty
                        ? 'Tidak ada wajah'
                        : _isHeadPositionCorrect
                            ? 'Posisi tepat! Capture...'
                            : 'Posisi kurang tepat',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Skip position button (only show after at least 1 frame is captured)
        if (_capturedEmbeddings[_currentPosition]!.isNotEmpty)
          Positioned(
            top: 20,
            right: 20,
            child: FloatingActionButton(
              heroTag: 'skip_position',
              backgroundColor: Colors.orange,
              mini: true,
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
              child: const Icon(Icons.skip_next),
            ),
          ),
        // Next position button (only show when current position is complete)
        if (_capturedEmbeddings[_currentPosition]!.length >= _requiredFramesPerPosition)
          Positioned(
            top: 20,
            right: 70,
            child: FloatingActionButton(
              heroTag: 'next_position',
              backgroundColor: Colors.green,
              onPressed: () {
                _moveToNextPosition();
              },
              child: const Icon(Icons.arrow_forward),
            ),
          ),
        // Cancel button
        Positioned(
          top: 20,
          left: 20,
          child: FloatingActionButton(
            heroTag: 'cancel_registration',
            backgroundColor: Colors.red,
            onPressed: () {
              _stopCapture();
              Navigator.of(context).pop();
            },
            child: const Icon(Icons.close),
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
      ..strokeWidth = 3.0
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
      ..strokeWidth = 8
      ..color = Colors.white.withAlpha(50)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawOval(ovalRect, glowPaint);

    // Draw main oval outline
    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white;
    canvas.drawOval(ovalRect, outlinePaint);

    // Draw directional arrow based on current position
    final arrowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.cyan
      ..strokeCap = StrokeCap.round;

    final arrowSize = 40.0;
    final arrowOffset = 30.0;

    switch (currentPosition) {
      case FacePosition.center:
        // Draw checkmark or center indicator
        final centerPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.green;
        canvas.drawCircle(center, 20, centerPaint);
        break;

      case FacePosition.up:
        // Draw arrow pointing up
        final arrowStart = Offset(center.dx, center.dy - arrowOffset);
        _drawUpArrow(canvas, arrowStart, arrowSize, arrowPaint);
        break;

      case FacePosition.down:
        // Draw arrow pointing down
        final arrowStart = Offset(center.dx, center.dy + arrowOffset);
        _drawDownArrow(canvas, arrowStart, arrowSize, arrowPaint);
        break;

      case FacePosition.left:
        // Draw arrow pointing left
        final arrowStart = Offset(center.dx - arrowOffset, center.dy);
        _drawLeftArrow(canvas, arrowStart, arrowSize, arrowPaint);
        break;

      case FacePosition.right:
        // Draw arrow pointing right
        final arrowStart = Offset(center.dx + arrowOffset, center.dy);
        _drawRightArrow(canvas, arrowStart, arrowSize, arrowPaint);
        break;
    }

    // Draw corner brackets
    final bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white.withAlpha(150)
      ..strokeCap = StrokeCap.round;

    final bracketLength = 30.0;
    final cornerRadius = 20.0;

    // Top-left corner
    final topLeft = Offset(ovalRect.left + cornerRadius, ovalRect.top + cornerRadius);
    canvas.drawLine(
      Offset(ovalRect.left - 10, topLeft.dy),
      Offset(topLeft.dx - bracketLength / 2, topLeft.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(topLeft.dx, ovalRect.top - 10),
      Offset(topLeft.dx, topLeft.dy - bracketLength / 2),
      bracketPaint,
    );

    // Top-right corner
    final topRight = Offset(ovalRect.right - cornerRadius, ovalRect.top + cornerRadius);
    canvas.drawLine(
      Offset(topRight.dx + bracketLength / 2, topRight.dy),
      Offset(ovalRect.right + 10, topRight.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(topRight.dx, ovalRect.top - 10),
      Offset(topRight.dx, topRight.dy - bracketLength / 2),
      bracketPaint,
    );

    // Bottom-left corner
    final bottomLeft = Offset(ovalRect.left + cornerRadius, ovalRect.bottom - cornerRadius);
    canvas.drawLine(
      Offset(ovalRect.left - 10, bottomLeft.dy),
      Offset(bottomLeft.dx - bracketLength / 2, bottomLeft.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(bottomLeft.dx, ovalRect.bottom + 10),
      Offset(bottomLeft.dx, bottomLeft.dy + bracketLength / 2),
      bracketPaint,
    );

    // Bottom-right corner
    final bottomRight = Offset(ovalRect.right - cornerRadius, ovalRect.bottom - cornerRadius);
    canvas.drawLine(
      Offset(bottomRight.dx + bracketLength / 2, bottomRight.dy),
      Offset(ovalRect.right + 10, bottomRight.dy),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(bottomRight.dx, ovalRect.bottom + 10),
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

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/face_detector_service.dart';
import '../services/face_recognition_service.dart';
import '../services/face_storage_service.dart';
import 'face_registration_screen.dart';

class FaceDetectionScreen extends StatefulWidget {
  const FaceDetectionScreen({super.key});

  @override
  State<FaceDetectionScreen> createState() => _FaceDetectionScreenState();
}

class _FaceDetectionScreenState extends State<FaceDetectionScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  final FaceRecognitionService _faceRecognitionService = FaceRecognitionService();
  final FaceStorageService _faceStorageService = FaceStorageService();

  List<Face> _detectedFaces = [];
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  String? _errorMessage;
  Timer? _detectionTimer;

  List<CameraDescription> _cameras = [];
  int _currentCameraIndex = 0;
  bool _isInBackground = false;

  List<FaceData> _registeredFaces = [];
  String? _recognizedName;

  bool get _isFrontCamera {
    if (_cameras.isEmpty || _currentCameraIndex >= _cameras.length) {
      return false;
    }
    return _cameras[_currentCameraIndex].lensDirection == CameraLensDirection.front;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _loadRegisteredFaces();
    _loadFaceRecognitionModel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // App going to background
      _isInBackground = true;
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      // App coming to foreground
      _isInBackground = false;
      _initializeCamera();
    }
  }

  Future<void> _loadRegisteredFaces() async {
    final faces = await _faceStorageService.getRegisteredFaces();
    if (mounted) {
      setState(() {
        _registeredFaces = faces;
      });
    }
  }

  Future<void> _loadFaceRecognitionModel() async {
    await _faceRecognitionService.loadModel();
  }

  Future<void> _stopCamera() async {
    _stopDetection();
    await _cameraController?.dispose();
    _cameraController = null;

    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
        _detectedFaces = [];
        _recognizedName = null;
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (_isInBackground) {
      // Don't initialize if in background
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

      // Set default to front camera
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
    _stopDetection();

    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
        _detectedFaces = [];
        _recognizedName = null;
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

      _startDetection();
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length <= 1) return;

    final newIndex = (_currentCameraIndex + 1) % _cameras.length;
    await _initCameraController(newIndex);

    if (mounted) {
      setState(() {
        _currentCameraIndex = newIndex;
      });
    }
  }

  void _startDetection() {
    if (_isInBackground) {
      // Don't start if in background
      return;
    }

    _detectionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_isProcessing || _isInBackground) {
        return;
      }
      _detectFaces();
    });
  }

  void _stopDetection() {
    _detectionTimer?.cancel();
    _detectionTimer = null;
    _isProcessing = false;
  }

  Future<void> _detectFaces() async {
    if (_isProcessing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isInBackground) {
      return;
    }

    _isProcessing = true;

    try {
      final image = await _cameraController!.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);

      await _faceDetectorService.detectFacesFromImage(inputImage);

      if (mounted && !_isInBackground) {
        setState(() {
          _detectedFaces = _faceDetectorService.faces;
        });

        // Check if any registered face matches
        if (_detectedFaces.isNotEmpty && _registeredFaces.isNotEmpty) {
          await _checkFaceRecognition(image.path);
        }
      }

      // Delete temp file
      try {
        final file = File(image.path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    } catch (e) {
      // Silently fail to avoid spamming logs
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _checkFaceRecognition(String imagePath) async {
    if (_detectedFaces.isEmpty || _registeredFaces.isEmpty) return;

    for (final face in _detectedFaces) {
      try {
        final embedding = await _faceRecognitionService.getFaceEmbedding(imagePath, face);

        for (final registeredFace in _registeredFaces) {
          if (_faceRecognitionService.isSameFaceMultiple(
            embedding,
            registeredFace.embeddings,
          )) {
            if (mounted) {
              setState(() {
                _recognizedName = registeredFace.name;
              });
            }
            return;
          }
        }

        if (mounted) {
          setState(() {
            _recognizedName = null;
          });
        }
      } catch (e) {
        // Silently handle recognition errors
      }
    }
  }

  Future<void> _showRegisterDialog() async {
    final controller = TextEditingController();

    // Pause detection while showing dialog
    _stopDetection();

    final result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Register Face'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your name to register this face:'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter a name')),
                  );
                  return;
                }
                Navigator.of(context).pop(name);
              },
              child: const Text('Next'),
            ),
          ],
        );
      },
    );

    if (result != null && result.isNotEmpty) {
      if (!mounted) return;
      // Stop camera before navigating to registration screen
      await _stopCamera();

      if (!mounted) return;
      // Import the FaceRegistrationScreen at the top of the file
      final registered = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (context) => FaceRegistrationScreen(name: result),
        ),
      );

      if (registered == true && mounted) {
        await _loadRegisteredFaces();
      }

      // Re-initialize camera after returning from registration
      if (mounted) {
        await _initializeCamera();
      }
    } else {
      // User cancelled, restart detection
      if (mounted && _isCameraInitialized) {
        _startDetection();
      }
    }
  }

  Future<void> _showRegisteredFacesDialog() async {
    await _loadRegisteredFaces();

    if (!mounted) return;

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Registered Faces (${_registeredFaces.length})'),
          content: _registeredFaces.isEmpty
              ? const Text('No faces registered yet.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...ListTile.divideTiles(
                      tiles: _registeredFaces.map((face) {
                        return ListTile(
                          title: Text(face.name),
                          subtitle: Text(
                            'Registered: ${face.registeredAt.day}/${face.registeredAt.month}/${face.registeredAt.year}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () async {
                              await _faceStorageService.deleteFace(face.name);
                              if (!mounted) return;
                              Navigator.of(context).pop();
                              await _loadRegisteredFaces();
                              if (!mounted) return;
                              _showRegisteredFacesDialog();
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
          actions: <Widget>[
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDetection();
    _cameraController?.dispose();
    _faceDetectorService.dispose();
    _faceRecognitionService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Face Detection'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.people),
            onPressed: _showRegisteredFacesDialog,
            tooltip: 'Registered Faces',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showRegisterDialog,
        backgroundColor: Colors.blue,
        icon: const Icon(Icons.person_add),
        label: const Text('Register Face'),
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
        // Face positioning guide
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          child: FacePositioningGuide(),
        ),
        FaceOverlay(
          faces: _detectedFaces,
          imageSize: Size(
            _cameraController!.value.previewSize!.height,
            _cameraController!.value.previewSize!.width,
          ),
          isFrontCamera: _isFrontCamera,
        ),
        // Recognized name badge
        if (_recognizedName != null)
          Positioned(
            top: 80,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.green.withAlpha(230),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      '$_recognizedName',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          bottom: 100,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Faces detected: ${_detectedFaces.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
        // Camera switch button
        if (_cameras.length > 1)
          Positioned(
            top: 20,
            right: 20,
            child: FloatingActionButton(
              heroTag: 'switch_camera',
              onPressed: _switchCamera,
              child: const Icon(Icons.cameraswitch),
            ),
          ),
        // Registered faces count
        if (_registeredFaces.isNotEmpty)
          Positioned(
            top: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blue.withAlpha(200),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.people, color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    '${_registeredFaces.length}',
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

      // For front camera, mirror the X coordinate
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

/// Face positioning guide for detection screen (simpler version)
class FacePositioningGuide extends StatelessWidget {
  const FacePositioningGuide({super.key});

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
          ),
        );
      },
    );
  }
}

class FacePositioningGuidePainter extends CustomPainter {
  final double ovalWidth;
  final double ovalHeight;

  FacePositioningGuidePainter({
    required this.ovalWidth,
    required this.ovalHeight,
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

    // Draw center indicator
    final centerPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.green.withAlpha(150);
    canvas.drawCircle(center, 12, centerPaint);

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

  @override
  bool shouldRepaint(FacePositioningGuidePainter oldDelegate) {
    return oldDelegate.ovalWidth != ovalWidth || oldDelegate.ovalHeight != ovalHeight;
  }
}

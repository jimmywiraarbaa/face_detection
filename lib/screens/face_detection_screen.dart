import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/face_detector_service.dart';

class FaceDetectionScreen extends StatefulWidget {
  const FaceDetectionScreen({super.key});

  @override
  State<FaceDetectionScreen> createState() => _FaceDetectionScreenState();
}

class _FaceDetectionScreenState extends State<FaceDetectionScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  List<Face> _detectedFaces = [];
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  String? _errorMessage;
  Timer? _detectionTimer;

  List<CameraDescription> _cameras = [];
  int _currentCameraIndex = 0;
  bool _isInBackground = false;

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

  Future<void> _stopCamera() async {
    _stopDetection();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDetection();
    _cameraController?.dispose();
    _faceDetectorService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) async {
        // Stop camera when leaving screen
        await _stopCamera();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Face Detection'),
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
        Positioned(
          bottom: 30,
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

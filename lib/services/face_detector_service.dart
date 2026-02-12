import 'dart:io';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectorService {
  late final FaceDetector _faceDetector;
  List<Face> _faces = [];

  List<Face> get faces => _faces;

  FaceDetectorService() {
    final options = FaceDetectorOptions(
      enableContours: true,
      enableClassification: true,
      enableLandmarks: true,
      enableTracking: true,
      performanceMode: FaceDetectorMode.accurate,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<void> detectFacesFromImage(InputImage inputImage) async {
    try {
      _faces = await _faceDetector.processImage(inputImage);
    } catch (e) {
      print('Error detecting faces: $e');
      _faces = [];
    }
  }

  void dispose() {
    _faceDetector.close();
  }
}

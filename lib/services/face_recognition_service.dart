import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceRecognitionService {
  Interpreter? _interpreter;
  bool _isModelLoaded = false;

  static const int _inputSize = 112;
  static const int _outputSize = 192;

  Future<void> loadModel() async {
    if (_isModelLoaded) return;

    try {
      _interpreter = await Interpreter.fromAsset('assets/mobilefacenet.tflite');
      _isModelLoaded = true;
    } catch (e) {
      _isModelLoaded = false;
    }
  }

  bool get isModelLoaded => _isModelLoaded;

  Future<List<double>> getFaceEmbedding(String imagePath, Face face) async {
    if (!_isModelLoaded) {
      await loadModel();
    }

    // Read image file
    final file = File(imagePath);
    final bytes = await file.readAsBytes();
    final decodedImage = img.decodeImage(bytes);

    if (decodedImage == null) {
      throw Exception('Failed to decode image');
    }

    // Extract face region
    final faceImage = _extractFaceFromFile(decodedImage, face);

    // Resize and convert to model input format
    final input = _preprocessImage(faceImage);

    // Run inference
    final output = List.filled(1 * _outputSize, 0.0).reshape([1, _outputSize]);
    _interpreter?.run(input.reshape([1, _inputSize, _inputSize, 3]), output);

    return output[0] as List<double>;
  }

  img.Image _extractFaceFromFile(img.Image image, Face face) {
    final rect = face.boundingBox;

    // Convert normalized coordinates to pixel coordinates
    final left = rect.left.toDouble();
    final top = rect.top.toDouble();
    final right = rect.right.toDouble();
    final bottom = rect.bottom.toDouble();

    // Extract face region with some padding
    const padding = 20;
    final x = math.max(0, (left - padding).toInt());
    final y = math.max(0, (top - padding).toInt());
    final width = math.min((right - left + padding * 2).toInt(), image.width - x);
    final height = math.min((bottom - top + padding * 2).toInt(), image.height - y);

    return img.copyCrop(
      image,
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }

  List<List<List<double>>> _preprocessImage(img.Image faceImage) {
    // Resize to input size
    final resized = img.copyResize(
      faceImage,
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.linear,
    );

    // Convert to float array and normalize
    final input = List.generate(
      _inputSize,
      (y) => List.generate(
        _inputSize,
        (x) {
          final pixel = resized.getPixel(x, y);
          return [
            pixel.r / 255.0,
            pixel.g / 255.0,
            pixel.b / 255.0,
          ];
        },
      ),
    );

    return input;
  }

  double calculateCosineSimilarity(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) {
      return 0.0;
    }

    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;

    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }

    return dotProduct / (math.sqrt(norm1) * math.sqrt(norm2));
  }

  double calculateEuclideanDistance(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) {
      return double.infinity;
    }

    double sum = 0.0;
    for (int i = 0; i < embedding1.length; i++) {
      sum += (embedding1[i] - embedding2[i]) * (embedding1[i] - embedding2[i]);
    }

    return math.sqrt(sum);
  }

  bool isSameFace(List<double> embedding1, List<double> embedding2, {double threshold = 0.8}) {
    final similarity = calculateCosineSimilarity(embedding1, embedding2);
    return similarity >= threshold;
  }

  /// Compare an embedding against multiple embeddings and return the best similarity score
  double getBestSimilarity(List<double> embedding, List<List<double>> embeddings) {
    if (embeddings.isEmpty) return 0.0;

    double bestSimilarity = 0.0;
    for (final emb in embeddings) {
      final similarity = calculateCosineSimilarity(embedding, emb);
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
      }
    }
    return bestSimilarity;
  }

  /// Compare an embedding against multiple embeddings and return true if any match above threshold
  bool isSameFaceMultiple(List<double> embedding, List<List<double>> embeddings, {double threshold = 0.8}) {
    return getBestSimilarity(embedding, embeddings) >= threshold;
  }

  void dispose() {
    _interpreter?.close();
    _isModelLoaded = false;
  }
}

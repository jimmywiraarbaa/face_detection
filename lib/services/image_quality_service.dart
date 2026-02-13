import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';

enum ImageQualityIssue {
  none,
  tooDark,
  tooBright,
  blurry,
}

class ImageQualityResult {
  final ImageQualityIssue issue;
  final double brightness;
  final double sharpness;

  const ImageQualityResult({
    required this.issue,
    required this.brightness,
    required this.sharpness,
  });

  bool get isGood => issue == ImageQualityIssue.none;
}

class ImageQualityService {
  // Thresholds for quality check
  static const double _minBrightness = 50.0;
  static const double _maxBrightness = 200.0;
  static const double _minSharpness = 100.0; // Laplacian variance threshold

  /// Check image quality from file path
  Future<ImageQualityResult> checkImageQuality(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return const ImageQualityResult(
          issue: ImageQualityIssue.blurry,
          brightness: 0,
          sharpness: 0,
        );
      }

      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);

      if (image == null) {
        return const ImageQualityResult(
          issue: ImageQualityIssue.blurry,
          brightness: 0,
          sharpness: 0,
        );
      }

      // Calculate brightness
      final brightness = _calculateBrightness(image);

      // Check brightness first
      if (brightness < _minBrightness) {
        return ImageQualityResult(
          issue: ImageQualityIssue.tooDark,
          brightness: brightness,
          sharpness: 0,
        );
      }

      if (brightness > _maxBrightness) {
        return ImageQualityResult(
          issue: ImageQualityIssue.tooBright,
          brightness: brightness,
          sharpness: 0,
        );
      }

      // Calculate sharpness (Laplacian variance)
      final sharpness = _calculateSharpness(image);

      if (sharpness < _minSharpness) {
        return ImageQualityResult(
          issue: ImageQualityIssue.blurry,
          brightness: brightness,
          sharpness: sharpness,
        );
      }

      return ImageQualityResult(
        issue: ImageQualityIssue.none,
        brightness: brightness,
        sharpness: sharpness,
      );
    } catch (e) {
      // On error, return blurry to be safe
      return const ImageQualityResult(
        issue: ImageQualityIssue.blurry,
        brightness: 0,
        sharpness: 0,
      );
    }
  }

  /// Calculate average brightness (0-255)
  double _calculateBrightness(img.Image image) {
    int total = 0;
    int count = 0;

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        // Use perceived brightness formula
        final brightness = (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b).toInt();
        total += brightness;
        count++;
      }
    }

    return count > 0 ? total / count : 0;
  }

  /// Calculate sharpness using Laplacian variance
  double _calculateSharpness(img.Image image) {
    // Convert to grayscale if not already
    final gray = image.numChannels == 1 ? image : img.grayscale(image);

    // Apply Laplacian operator
    final laplacian = img.Image(width: gray.width - 2, height: gray.height - 2);

    for (int y = 1; y < gray.height - 1; y++) {
      for (int x = 1; x < gray.width - 1; x++) {
        // Laplacian kernel: [[0, -1, 0], [-1, 4, -1], [0, -1, 0]]
        final center = gray.getPixel(x, y).r.toInt();
        final top = gray.getPixel(x, y - 1).r.toInt();
        final bottom = gray.getPixel(x, y + 1).r.toInt();
        final left = gray.getPixel(x - 1, y).r.toInt();
        final right = gray.getPixel(x + 1, y).r.toInt();

        final laplacianValue = (4 * center - top - bottom - left - right).toDouble();
        laplacian.setPixelRgb(x - 1, y - 1, laplacianValue.toInt(), laplacianValue.toInt(), laplacianValue.toInt());
      }
    }

    // Calculate variance
    double sum = 0;
    double sumSquared = 0;
    int count = 0;

    for (int y = 0; y < laplacian.height; y++) {
      for (int x = 0; x < laplacian.width; x++) {
        final value = laplacian.getPixel(x, y).r.toDouble();
        sum += value;
        sumSquared += value * value;
        count++;
      }
    }

    if (count == 0) return 0;

    final mean = sum / count;
    final variance = (sumSquared / count) - (mean * mean);

    return variance;
  }

  /// Get feedback message for quality issue
  String getFeedbackMessage(ImageQualityResult result) {
    switch (result.issue) {
      case ImageQualityIssue.tooDark:
        return 'Terlalu gelap! Cari tempat lebih terang';
      case ImageQualityIssue.tooBright:
        return 'Terlalu terang! Kurangi pencahayaan';
      case ImageQualityIssue.blurry:
        return 'Gambar blur! Tahan kamera stabil';
      case ImageQualityIssue.none:
        return 'Kualitas bagus! Capturing...';
    }
  }

  /// Get color for quality indicator
  Color getIndicatorColor(ImageQualityResult result) {
    switch (result.issue) {
      case ImageQualityIssue.tooDark:
        return Colors.orange;
      case ImageQualityIssue.tooBright:
        return Colors.yellow;
      case ImageQualityIssue.blurry:
        return Colors.red;
      case ImageQualityIssue.none:
        return Colors.green;
    }
  }
}

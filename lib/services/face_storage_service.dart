import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class FaceData {
  final String name;
  final List<List<double>> embeddings;
  final DateTime registeredAt;

  FaceData({
    required this.name,
    required this.embeddings,
    required this.registeredAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'embeddings': embeddings,
      'registeredAt': registeredAt.toIso8601String(),
    };
  }

  factory FaceData.fromJson(Map<String, dynamic> json) {
    // Handle backward compatibility
    List<List<double>> embeddings;

    if (json.containsKey('embeddings')) {
      // New format: embeddings is List<List<double>>
      try {
        embeddings = (json['embeddings'] as List)
            .map((emb) => List<double>.from(emb as List))
            .toList();
      } catch (_) {
        // If parsing fails, try old format
        embeddings = [];
      }
    } else if (json.containsKey('embedding')) {
      // Old format: embedding is List<double>, wrap it in a list
      try {
        embeddings = [List<double>.from(json['embedding'] as List)];
      } catch (_) {
        embeddings = [];
      }
    } else {
      embeddings = [];
    }

    return FaceData(
      name: json['name'] as String,
      embeddings: embeddings,
      registeredAt: DateTime.parse(json['registeredAt'] as String),
    );
  }

  /// Get the average embedding from all stored embeddings
  List<double> get averageEmbedding {
    if (embeddings.isEmpty) return [];
    if (embeddings.length == 1) return embeddings.first;

    final length = embeddings.first.length;
    final averaged = List<double>.filled(length, 0.0);

    for (final embedding in embeddings) {
      for (int i = 0; i < length; i++) {
        averaged[i] += embedding[i];
      }
    }

    for (int i = 0; i < length; i++) {
      averaged[i] /= embeddings.length;
    }

    return averaged;
  }
}

class FaceStorageService {
  static const String _facesKey = 'registered_faces';

  Future<List<FaceData>> getRegisteredFaces() async {
    final prefs = await SharedPreferences.getInstance();
    final facesJson = prefs.getStringList(_facesKey);

    if (facesJson == null) return [];

    final faces = <FaceData>[];
    for (final jsonStr in facesJson) {
      try {
        final face = FaceData.fromJson(jsonDecode(jsonStr));
        faces.add(face);
      } catch (_) {
        // Skip invalid entries
        continue;
      }
    }
    return faces;
  }

  Future<void> saveFace(String name, List<List<double>> embeddings) async {
    final prefs = await SharedPreferences.getInstance();
    final faces = await getRegisteredFaces();

    // Remove existing face with same name if exists
    faces.removeWhere((face) => face.name == name);

    final faceData = FaceData(
      name: name,
      embeddings: embeddings,
      registeredAt: DateTime.now(),
    );

    faces.add(faceData);

    try {
      final facesJson = faces.map((face) => jsonEncode(face.toJson())).toList();
      await prefs.setStringList(_facesKey, facesJson);
    } catch (e) {
      throw Exception('Failed to register face: $e');
    }
  }

  Future<void> addEmbedding(String name, List<double> embedding) async {
    final prefs = await SharedPreferences.getInstance();
    final faces = await getRegisteredFaces();

    final existingIndex = faces.indexWhere((face) => face.name == name);

    if (existingIndex != -1) {
      // Add embedding to existing face
      final existingFace = faces[existingIndex];
      final updatedEmbeddings = List<List<double>>.from(existingFace.embeddings)
        ..add(embedding);

      faces[existingIndex] = FaceData(
        name: name,
        embeddings: updatedEmbeddings,
        registeredAt: existingFace.registeredAt,
      );
    } else {
      // Create new face
      faces.add(FaceData(
        name: name,
        embeddings: [embedding],
        registeredAt: DateTime.now(),
      ));
    }

    final facesJson = faces.map((face) => jsonEncode(face.toJson())).toList();
    await prefs.setStringList(_facesKey, facesJson);
  }

  Future<void> deleteFace(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final faces = await getRegisteredFaces();

    faces.removeWhere((face) => face.name == name);

    final facesJson = faces.map((face) => jsonEncode(face.toJson())).toList();
    await prefs.setStringList(_facesKey, facesJson);
  }

  Future<void> clearAllFaces() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_facesKey);
  }

  Future<int> getFaceCount() async {
    final faces = await getRegisteredFaces();
    return faces.length;
  }
}

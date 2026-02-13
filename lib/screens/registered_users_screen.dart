import 'package:flutter/material.dart';
import '../services/face_storage_service.dart';

class RegisteredUsersScreen extends StatefulWidget {
  const RegisteredUsersScreen({super.key});

  @override
  State<RegisteredUsersScreen> createState() => _RegisteredUsersScreenState();
}

class _RegisteredUsersScreenState extends State<RegisteredUsersScreen> {
  final FaceStorageService _faceStorageService = FaceStorageService();
  List<FaceData> _registeredFaces = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRegisteredFaces();
  }

  Future<void> _loadRegisteredFaces() async {
    setState(() {
      _isLoading = true;
    });

    final faces = await _faceStorageService.getRegisteredFaces();

    if (mounted) {
      setState(() {
        _registeredFaces = faces;
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteFace(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus Wajah'),
        content: Text('Apakah Anda yakin ingin menghapus wajah $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _faceStorageService.deleteFace(name);
      await _loadRegisteredFaces();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name berhasil dihapus')),
        );
      }
    }
  }

  Future<void> _clearAllFaces() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus Semua'),
        content: const Text('Apakah Anda yakin ingin menghapus semua data wajah?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Hapus Semua'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _faceStorageService.clearAllFaces();
      await _loadRegisteredFaces();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Semua data wajah berhasil dihapus')),
        );
      }
    }
  }

  int _getTotalEmbeddings(FaceData face) {
    return face.embeddings.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Terdaftar'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_registeredFaces.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _clearAllFaces,
              tooltip: 'Hapus Semua',
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRegisteredFaces,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_registeredFaces.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.person_off,
                size: 64,
                color: Colors.grey.withAlpha(150),
              ),
              const SizedBox(height: 16),
              const Text(
                'Belum ada user terdaftar',
                style: TextStyle(fontSize: 18, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              const Text(
                'Silakan register wajah terlebih dahulu',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRegisteredFaces,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _registeredFaces.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final face = _registeredFaces[index];
          return _buildUserCard(face);
        },
      ),
    );
  }

  Widget _buildUserCard(FaceData face) {
    final totalEmbeddings = _getTotalEmbeddings(face);
    final registeredDate = face.registeredAt;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.blue.withAlpha(50),
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: const Icon(
                    Icons.person,
                    color: Colors.blue,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        face.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Registered: ${registeredDate.day}/${registeredDate.month}/${registeredDate.year}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.withAlpha(180),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _deleteFace(face.name),
                  tooltip: 'Hapus',
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Embeddings info
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fingerprint,
                    size: 16,
                    color: Colors.blue.withAlpha(180),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$totalEmbeddings frame terdata',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.withAlpha(180),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

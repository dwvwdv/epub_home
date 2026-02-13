import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class EpubStorageService {
  Future<Directory> get _booksDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final booksDir = Directory('${appDir.path}/books');
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    return booksDir;
  }

  Future<File> saveBook(String hash, Uint8List bytes) async {
    final dir = await _booksDir;
    final file = File('${dir.path}/$hash.epub');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<File?> getBookFile(String hash) async {
    final dir = await _booksDir;
    final file = File('${dir.path}/$hash.epub');
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  Future<bool> hasBook(String hash) async {
    final dir = await _booksDir;
    final file = File('${dir.path}/$hash.epub');
    return file.exists();
  }

  Future<String> computeHash(Uint8List bytes) async {
    return sha256.convert(bytes).toString();
  }

  Future<String> computeFileHash(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  Future<void> deleteBook(String hash) async {
    final dir = await _booksDir;
    final file = File('${dir.path}/$hash.epub');
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<List<String>> listBooks() async {
    final dir = await _booksDir;
    final files = await dir.list().toList();
    return files
        .whereType<File>()
        .where((f) => f.path.endsWith('.epub'))
        .map((f) => f.path.split('/').last.replaceAll('.epub', ''))
        .toList();
  }
}

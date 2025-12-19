import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/user.dart';

class StorageService {
  static const String _keyBooks = 'books';
  static const String _keyCurrentUser = 'current_user';
  static const String _keyDeviceId = 'device_id';

  late final SharedPreferences _prefs;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // 用戶相關
  Future<void> saveCurrentUser(User user) async {
    await _prefs.setString(_keyCurrentUser, jsonEncode(user.toJson()));
  }

  User? getCurrentUser() {
    final userJson = _prefs.getString(_keyCurrentUser);
    if (userJson == null) return null;
    return User.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
  }

  Future<void> saveDeviceId(String deviceId) async {
    await _prefs.setString(_keyDeviceId, deviceId);
  }

  String? getDeviceId() {
    return _prefs.getString(_keyDeviceId);
  }

  // 書籍相關
  Future<void> saveBooks(List<Book> books) async {
    final booksJson = books.map((b) => b.toJson()).toList();
    await _prefs.setString(_keyBooks, jsonEncode(booksJson));
  }

  List<Book> getBooks() {
    final booksJson = _prefs.getString(_keyBooks);
    if (booksJson == null) return [];

    final List<dynamic> decoded = jsonDecode(booksJson) as List;
    return decoded.map((b) => Book.fromJson(b as Map<String, dynamic>)).toList();
  }

  Future<void> addBook(Book book) async {
    final books = getBooks();
    books.add(book);
    await saveBooks(books);
  }

  Future<void> updateBook(Book book) async {
    final books = getBooks();
    final index = books.indexWhere((b) => b.id == book.id);
    if (index != -1) {
      books[index] = book;
      await saveBooks(books);
    }
  }

  Future<void> deleteBook(String bookId) async {
    final books = getBooks();
    books.removeWhere((b) => b.id == bookId);
    await saveBooks(books);
  }

  // 閱讀進度
  Future<void> saveReadingProgress(String bookId, int chapter, int page) async {
    await _prefs.setInt('${bookId}_chapter', chapter);
    await _prefs.setInt('${bookId}_page', page);
  }

  Map<String, int> getReadingProgress(String bookId) {
    return {
      'chapter': _prefs.getInt('${bookId}_chapter') ?? 0,
      'page': _prefs.getInt('${bookId}_page') ?? 0,
    };
  }

  // 清除所有數據
  Future<void> clear() async {
    await _prefs.clear();
  }
}

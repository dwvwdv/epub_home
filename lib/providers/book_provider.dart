import 'package:flutter/foundation.dart';
import '../models/book.dart';
import '../services/epub_service.dart';
import '../services/storage_service.dart';

class BookProvider extends ChangeNotifier {
  final EpubService _epubService;
  final StorageService _storageService;

  List<Book> _books = [];
  Book? _currentBook;
  bool _isLoading = false;
  String? _error;

  List<Book> get books => _books;
  Book? get currentBook => _currentBook;
  bool get isLoading => _isLoading;
  String? get error => _error;

  BookProvider({
    required EpubService epubService,
    required StorageService storageService,
  })  : _epubService = epubService,
        _storageService = storageService {
    _loadBooks();
  }

  /// 加載書籍列表
  Future<void> _loadBooks() async {
    _books = _storageService.getBooks();
    notifyListeners();
  }

  /// 導入 EPUB 文件
  Future<void> importEpubFile(String filePath) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final book = await _epubService.parseEpubFile(filePath);
      _books.add(book);
      await _storageService.addBook(book);

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 設置當前閱讀的書籍
  void setCurrentBook(Book book) {
    _currentBook = book;
    notifyListeners();
  }

  /// 更新閱讀進度
  Future<void> updateReadingProgress(String bookId, int chapter, int page) async {
    final book = _books.firstWhere((b) => b.id == bookId);
    book.currentChapter = chapter;
    book.currentPage = page;

    await _storageService.updateBook(book);
    await _storageService.saveReadingProgress(bookId, chapter, page);

    notifyListeners();
  }

  /// 刪除書籍
  Future<void> deleteBook(String bookId) async {
    _books.removeWhere((b) => b.id == bookId);
    await _storageService.deleteBook(bookId);

    if (_currentBook?.id == bookId) {
      _currentBook = null;
    }

    notifyListeners();
  }

  /// 獲取書籍的閱讀進度
  Map<String, int> getReadingProgress(String bookId) {
    return _storageService.getReadingProgress(bookId);
  }
}

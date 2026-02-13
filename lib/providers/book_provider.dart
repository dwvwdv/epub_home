import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book_metadata.dart';
import '../services/epub_storage_service.dart';
import '../services/file_transfer_service.dart';
import '../services/realtime_service.dart';
import 'presence_provider.dart';
import 'room_provider.dart';

final epubStorageProvider = Provider<EpubStorageService>((ref) {
  return EpubStorageService();
});

final bookProvider = StateNotifierProvider<BookNotifier, BookState>((ref) {
  return BookNotifier(
    ref: ref,
    storageService: ref.read(epubStorageProvider),
  );
});

class BookState {
  final BookMetadata? currentBook;
  final File? bookFile;
  final bool isLoading;
  final String? error;
  final String? currentCfi;

  const BookState({
    this.currentBook,
    this.bookFile,
    this.isLoading = false,
    this.error,
    this.currentCfi,
  });

  bool get hasBook => bookFile != null;

  BookState copyWith({
    BookMetadata? currentBook,
    File? bookFile,
    bool? isLoading,
    String? error,
    String? currentCfi,
  }) {
    return BookState(
      currentBook: currentBook ?? this.currentBook,
      bookFile: bookFile ?? this.bookFile,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      currentCfi: currentCfi ?? this.currentCfi,
    );
  }
}

class BookNotifier extends StateNotifier<BookState> {
  final Ref ref;
  final EpubStorageService _storageService;
  FileTransferService? _transferService;

  BookNotifier({
    required this.ref,
    required EpubStorageService storageService,
  })  : _storageService = storageService,
        super(const BookState());

  void initTransferService({
    required RealtimeService realtimeService,
    required String currentUserId,
  }) {
    _transferService = FileTransferService(
      realtimeService: realtimeService,
      storageService: _storageService,
      currentUserId: currentUserId,
    );
    _transferService!.initialize();

    // Listen for transfer completion
    _transferService!.stateStream.listen((transferState) {
      if (transferState.status == TransferStatus.completed &&
          transferState.bookHash != null) {
        _onBookReceived(transferState.bookHash!);
      }
    });
  }

  Future<void> pickAndShareBook() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }

      final file = result.files.first;
      final Uint8List bytes;

      if (file.bytes != null) {
        bytes = file.bytes!;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      } else {
        throw Exception('Cannot read file');
      }

      // Compute hash
      final hash = await _storageService.computeHash(bytes);

      // Save locally
      final savedFile = await _storageService.saveBook(hash, bytes);

      final metadata = BookMetadata(
        id: hash,
        title: file.name.replaceAll('.epub', ''),
        author: 'Unknown',
        fileName: file.name,
        fileSizeBytes: bytes.length,
        fileHash: hash,
      );

      state = state.copyWith(
        currentBook: metadata,
        bookFile: savedFile,
        isLoading: false,
      );

      // Update room with book info
      await ref.read(roomProvider.notifier).updateBookShared(
            bookTitle: metadata.title,
            bookHash: hash,
          );

      // Broadcast book_shared event
      final realtimeService = ref.read(realtimeServiceProvider);
      await realtimeService.broadcast(
        event: 'book_shared',
        payload: metadata.toJson(),
      );

      // Start sending to other members
      await _transferService?.sendBook(
        fileBytes: bytes,
        bookHash: hash,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> _onBookReceived(String bookHash) async {
    final bookFile = await _storageService.getBookFile(bookHash);
    if (bookFile != null) {
      state = state.copyWith(bookFile: bookFile);

      // Update presence
      await ref.read(presenceProvider.notifier).updateHasBook(true);
    }
  }

  Future<void> loadExistingBook(String bookHash) async {
    final file = await _storageService.getBookFile(bookHash);
    if (file != null) {
      state = state.copyWith(bookFile: file);
    }
  }

  void updateCfi(String cfi) {
    state = state.copyWith(currentCfi: cfi);
  }

  FileTransferService? get transferService => _transferService;

  void reset() {
    _transferService?.dispose();
    _transferService = null;
    state = const BookState();
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/app_constants.dart';
import '../models/book_metadata.dart';
import '../services/epub_storage_service.dart';
import '../models/transfer_state.dart';
import '../services/file_transfer_service.dart';
import '../services/realtime_service.dart';
import 'presence_provider.dart';
import 'room_provider.dart';

final epubStorageProvider = Provider<EpubStorageService>((ref) {
  return EpubStorageService();
});

final bookProvider = StateNotifierProvider<BookNotifier, BookState>((ref) {
  return BookNotifier(ref: ref, storageService: ref.read(epubStorageProvider));
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
  StreamSubscription<TransferState>? _transferStateSubscription;
  RealtimeService? _transferRealtimeService;
  String? _transferUserId;
  String? _transferRoomCode;
  String? _loadedBookHash;
  String? _expectedBookHash;
  int _sessionGeneration = 0;
  int _transferGeneration = 0;
  Future<void> _transferOperationTail = Future<void>.value();
  bool _isDisposed = false;

  BookNotifier({required this.ref, required EpubStorageService storageService})
    : _storageService = storageService,
      super(const BookState());

  Future<void> initTransferService({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String roomCode,
  }) {
    final normalizedRoomCode = roomCode.trim().toUpperCase();
    final sessionGeneration = _sessionGeneration;
    return _serializeTransferOperation(() async {
      if (!_isCurrent(sessionGeneration)) return;
      if (_transferService != null &&
          identical(_transferRealtimeService, realtimeService) &&
          _transferUserId == currentUserId &&
          _transferRoomCode == normalizedRoomCode) {
        return;
      }

      await _replaceTransferService(
        realtimeService: realtimeService,
        currentUserId: currentUserId,
        roomCode: normalizedRoomCode,
        sessionGeneration: sessionGeneration,
      );
    });
  }

  Future<void> _replaceTransferService({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String roomCode,
    required int sessionGeneration,
  }) async {
    await _disposeTransferServiceInternal();
    if (!_isCurrent(sessionGeneration)) return;
    _transferRealtimeService = realtimeService;
    _transferUserId = currentUserId;
    _transferRoomCode = roomCode;
    _transferService = FileTransferService(
      realtimeService: realtimeService,
      storageService: _storageService,
      currentUserId: currentUserId,
    );
    _transferService!.initialize();
    final loadedBookHash = _loadedBookHash;
    if (loadedBookHash != null && state.bookFile != null) {
      _transferService!.markBookAvailable(loadedBookHash);
    } else if (_expectedBookHash != null) {
      _transferService!.expectBook(_expectedBookHash!);
    }
    final transferGeneration = _transferGeneration;

    // Listen for transfer completion
    _transferStateSubscription = _transferService!.stateStream.listen((
      transferState,
    ) {
      if (transferState.status == TransferStatus.completed &&
          transferState.bookHash != null) {
        unawaited(
          _onBookReceived(
            transferState.bookHash!,
            sessionGeneration,
            transferGeneration,
          ).catchError((Object error) {
            if (_isCurrent(sessionGeneration) &&
                transferGeneration == _transferGeneration) {
              state = state.copyWith(error: error.toString());
            }
          }),
        );
      }
    });
  }

  Future<void> pickAndShareBook() async {
    final generation = _sessionGeneration;
    if (_transferService?.currentState.isActive ?? false) {
      state = state.copyWith(error: 'A book transfer is already in progress.');
      return;
    }
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
        withData: true,
      );

      if (!_isCurrent(generation)) return;
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
      if (bytes.length > AppConstants.maxFileSize) {
        throw Exception(
          'Book exceeds the ${AppConstants.maxFileSize} byte limit',
        );
      }

      // Compute hash
      final hash = await _storageService.computeHash(bytes);

      // Save locally
      final savedFile = await _storageService.saveBook(hash, bytes);
      if (!_isCurrent(generation)) return;

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
      _loadedBookHash = hash;
      _expectedBookHash = hash;
      _transferService?.markBookAvailable(hash);

      // Update room with book info
      await ref
          .read(roomProvider.notifier)
          .updateBookShared(bookTitle: metadata.title, bookHash: hash);
      if (!_isCurrent(generation)) return;
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: hash);
      if (!_isCurrent(generation)) return;

      // Broadcast book_shared event
      final realtimeService = ref.read(realtimeServiceProvider);
      await realtimeService.broadcast(
        event: 'book_shared',
        payload: metadata.toJson(),
      );
      if (!_isCurrent(generation)) return;

      // Start sending to other members
      await _transferService?.sendBook(fileBytes: bytes, bookHash: hash);
    } catch (e) {
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
    }
  }

  Future<void> _onBookReceived(
    String bookHash,
    int generation,
    int transferGeneration,
  ) async {
    final bookFile = await _storageService.getBookFile(bookHash);
    if (bookFile != null &&
        _isCurrent(generation) &&
        transferGeneration == _transferGeneration) {
      state = state.copyWith(bookFile: bookFile, isLoading: false);
      _loadedBookHash = bookHash;
      _expectedBookHash = bookHash;

      // Update DB member status and presence
      await ref.read(roomProvider.notifier).updateReceiverBookStatus();
      if (!_isCurrent(generation) ||
          transferGeneration != _transferGeneration) {
        return;
      }
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: bookHash);
    }
  }

  Future<void> loadExistingBook(String bookHash) async {
    final generation = _sessionGeneration;
    final file = await _storageService.getBookFile(bookHash);
    if (!_isCurrent(generation)) return;
    if (file != null) {
      state = state.copyWith(bookFile: file, isLoading: false);
      _loadedBookHash = bookHash;
      _expectedBookHash = bookHash;
      _transferService?.markBookAvailable(bookHash);
      await ref.read(roomProvider.notifier).updateReceiverBookStatus();
      if (!_isCurrent(generation)) return;
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: bookHash);
    } else {
      await prepareForSharedBook(bookHash);
    }
  }

  bool hasBook(String bookHash) {
    return state.bookFile != null && _loadedBookHash == bookHash;
  }

  Future<void> prepareForSharedBook(String bookHash) async {
    final generation = _sessionGeneration;
    _expectedBookHash = bookHash;
    if (hasBook(bookHash)) {
      _transferService?.markBookAvailable(bookHash);
      await ref
          .read(presenceProvider.notifier)
          .updateHasBook(true, bookHash: bookHash);
      return;
    }
    if (!_isCurrent(generation)) return;
    _transferService?.expectBook(bookHash);
    _loadedBookHash = null;
    state = const BookState(isLoading: true);
    await ref.read(presenceProvider.notifier).updateHasBook(false);
  }

  void updateCfi(String cfi) {
    state = state.copyWith(currentCfi: cfi);
  }

  FileTransferService? get transferService => _transferService;

  Future<void> reset() async {
    ++_sessionGeneration;
    _loadedBookHash = null;
    _expectedBookHash = null;
    state = const BookState();
    await _serializeTransferOperation(_disposeTransferServiceInternal);
  }

  Future<void> _disposeTransferServiceInternal() async {
    ++_transferGeneration;
    await _transferStateSubscription?.cancel();
    _transferStateSubscription = null;
    await _transferService?.dispose();
    _transferService = null;
    _transferRealtimeService = null;
    _transferUserId = null;
    _transferRoomCode = null;
  }

  bool _isCurrent(int generation) {
    return !_isDisposed && generation == _sessionGeneration;
  }

  Future<void> _serializeTransferOperation(Future<void> Function() operation) {
    final completer = Completer<void>();
    _transferOperationTail = _transferOperationTail
        .catchError((Object _) {})
        .then((_) async {
          try {
            await operation();
            completer.complete();
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }

  @override
  void dispose() {
    _isDisposed = true;
    ++_sessionGeneration;
    unawaited(_serializeTransferOperation(_disposeTransferServiceInternal));
    super.dispose();
  }
}

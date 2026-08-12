import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../config/app_constants.dart';
import '../models/transfer_state.dart';
import 'epub_storage_service.dart';
import 'realtime_service.dart';

class FileTransferService {
  static const receiveTimeout = Duration(seconds: 30);

  final RealtimeService _realtimeService;
  final EpubStorageService _storageService;
  final String _currentUserId;

  final _stateController = StreamController<TransferState>.broadcast();
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  TransferState _state = const TransferState.idle();

  final Map<int, Uint8List> _receivedChunks = {};
  String? _pendingSenderId;
  String? _pendingBookHash;
  int _expectedTotalChunks = 0;
  int _expectedTotalBytes = 0;
  Timer? _receiveTimer;
  bool _initialized = false;
  bool _isAssembling = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  FileTransferService({
    required RealtimeService realtimeService,
    required EpubStorageService storageService,
    required String currentUserId,
  }) : _realtimeService = realtimeService,
       _storageService = storageService,
       _currentUserId = currentUserId;

  Stream<TransferState> get stateStream => _stateController.stream;
  TransferState get currentState => _state;
  int get subscriptionCount => _subscriptions.length;

  void initialize() {
    if (_initialized || _disposed) return;
    _initialized = true;
    _subscriptions.add(
      _realtimeService.broadcastStream('book_chunk').listen(_onBookChunk),
    );
  }

  Future<void> sendBook({
    required Uint8List fileBytes,
    required String bookHash,
  }) async {
    if (_disposed) throw StateError('FileTransferService is disposed');
    if (_state.isActive) throw StateError('A file transfer is already active');
    if (fileBytes.isEmpty) throw ArgumentError('Book file is empty');
    if (fileBytes.length > AppConstants.maxFileSize) {
      throw ArgumentError(
        'Book exceeds the ${AppConstants.maxFileSize} byte limit',
      );
    }
    if (!_isSha256(bookHash)) throw ArgumentError('Invalid book hash');

    final actualHash = sha256.convert(fileBytes).toString();
    if (actualHash != bookHash) {
      throw ArgumentError('Book hash does not match file contents');
    }

    final totalChunks = (fileBytes.length / AppConstants.fileChunkSize).ceil();
    _updateState(
      TransferState(
        status: TransferStatus.transferring,
        bookHash: bookHash,
        totalBytes: fileBytes.length,
        totalChunks: totalChunks,
        isSending: true,
      ),
    );

    try {
      for (var index = 0; index < totalChunks; index++) {
        if (_disposed) throw StateError('File transfer was cancelled');
        final start = index * AppConstants.fileChunkSize;
        final candidateEnd = start + AppConstants.fileChunkSize;
        final end = candidateEnd > fileBytes.length
            ? fileBytes.length
            : candidateEnd;
        final chunk = fileBytes.sublist(start, end);

        await _realtimeService.broadcast(
          event: 'book_chunk',
          payload: {
            'sender_id': _currentUserId,
            'book_hash': bookHash,
            'chunk_index': index,
            'total_chunks': totalChunks,
            'total_bytes': fileBytes.length,
            'data': base64Encode(chunk),
          },
        );

        _updateState(
          _state.copyWith(transferredBytes: end, receivedChunks: index + 1),
        );
        if (index + 1 < totalChunks) {
          await Future<void>.delayed(AppConstants.chunkDelay);
        }
      }

      _updateState(_state.copyWith(status: TransferStatus.completed));
      debugPrint('Book sent: $totalChunks chunks');
    } catch (error) {
      _updateState(
        _state.copyWith(
          status: TransferStatus.failed,
          errorMessage: error.toString(),
        ),
      );
      rethrow;
    }
  }

  void _onBookChunk(Map<String, dynamic> payload) {
    if (_disposed || _isAssembling) return;

    try {
      final senderId = payload['sender_id'];
      final bookHash = payload['book_hash'];
      final chunkIndex = payload['chunk_index'];
      final totalChunks = payload['total_chunks'];
      final totalBytes = payload['total_bytes'];
      final encodedData = payload['data'];

      if (senderId is! String ||
          senderId.isEmpty ||
          senderId == _currentUserId) {
        return;
      }
      if (bookHash is! String || !_isSha256(bookHash)) {
        throw const FormatException('Invalid book hash');
      }
      if (chunkIndex is! int ||
          totalChunks is! int ||
          totalBytes is! int ||
          encodedData is! String) {
        throw const FormatException('Invalid chunk field types');
      }
      if (totalBytes <= 0 || totalBytes > AppConstants.maxFileSize) {
        throw const FormatException('Invalid total file size');
      }
      const maxEncodedChunkLength = ((AppConstants.fileChunkSize + 2) ~/ 3) * 4;
      if (encodedData.length > maxEncodedChunkLength) {
        throw const FormatException('Encoded chunk exceeds size limit');
      }

      final calculatedChunks = (totalBytes / AppConstants.fileChunkSize).ceil();
      if (totalChunks <= 0 ||
          totalChunks != calculatedChunks ||
          chunkIndex < 0 ||
          chunkIndex >= totalChunks) {
        throw const FormatException('Invalid chunk index or count');
      }

      if (_pendingBookHash != null &&
          (_pendingBookHash != bookHash || _pendingSenderId != senderId)) {
        // Do not clear an in-flight transfer because an unrelated sender sent
        // a chunk to the room.
        return;
      }

      final chunkBytes = base64Decode(encodedData);
      final expectedLength = chunkIndex == totalChunks - 1
          ? totalBytes - (chunkIndex * AppConstants.fileChunkSize)
          : AppConstants.fileChunkSize;
      if (chunkBytes.length != expectedLength ||
          chunkBytes.length > AppConstants.fileChunkSize) {
        throw const FormatException('Invalid chunk size');
      }

      if (_pendingBookHash == null) {
        _beginReceive(
          senderId: senderId,
          bookHash: bookHash,
          totalChunks: totalChunks,
          totalBytes: totalBytes,
        );
      } else if (_expectedTotalChunks != totalChunks ||
          _expectedTotalBytes != totalBytes) {
        throw const FormatException('Transfer metadata changed mid-stream');
      }

      final existingChunk = _receivedChunks[chunkIndex];
      if (existingChunk != null && !listEquals(existingChunk, chunkBytes)) {
        throw const FormatException('Conflicting duplicate chunk');
      }
      final isNewChunk = existingChunk == null;
      if (isNewChunk) _receivedChunks[chunkIndex] = chunkBytes;
      final receivedBytes = _receivedChunks.values.fold<int>(
        0,
        (sum, chunk) => sum + chunk.length,
      );
      _updateState(
        _state.copyWith(
          transferredBytes: receivedBytes,
          receivedChunks: _receivedChunks.length,
        ),
      );
      // A duplicate packet is not forward progress and must not keep a stalled
      // transfer alive indefinitely.
      if (isNewChunk) _restartReceiveTimeout();

      if (_receivedChunks.length == _expectedTotalChunks) {
        _isAssembling = true;
        _receiveTimer?.cancel();
        unawaited(_assembleAndSave(bookHash));
      }
    } on FormatException catch (error) {
      debugPrint('Rejected book chunk: $error');
      final belongsToCurrentTransfer =
          _pendingBookHash != null &&
          payload['sender_id'] == _pendingSenderId &&
          payload['book_hash'] == _pendingBookHash;
      // A malformed unrelated packet must not destroy a valid in-flight
      // transfer, but invalid data from its established sender must fail it.
      if (_pendingBookHash == null || belongsToCurrentTransfer) {
        _failReceive(error.message);
      }
    }
  }

  void _beginReceive({
    required String senderId,
    required String bookHash,
    required int totalChunks,
    required int totalBytes,
  }) {
    _clearReceiveBuffer();
    _pendingSenderId = senderId;
    _pendingBookHash = bookHash;
    _expectedTotalChunks = totalChunks;
    _expectedTotalBytes = totalBytes;
    _updateState(
      TransferState(
        status: TransferStatus.transferring,
        bookHash: bookHash,
        totalBytes: totalBytes,
        totalChunks: totalChunks,
      ),
    );
  }

  Future<void> _assembleAndSave(String expectedHash) async {
    try {
      final builder = BytesBuilder(copy: false);
      for (var index = 0; index < _expectedTotalChunks; index++) {
        final chunk = _receivedChunks[index];
        if (chunk == null) throw FormatException('Missing chunk $index');
        builder.add(chunk);
      }

      final fullBytes = builder.takeBytes();
      if (fullBytes.length != _expectedTotalBytes) {
        throw const FormatException('Assembled file size mismatch');
      }
      final hash = sha256.convert(fullBytes).toString();
      if (hash != expectedHash) {
        throw const FormatException('Assembled file hash mismatch');
      }

      await _storageService.saveBook(expectedHash, fullBytes);
      _updateState(_state.copyWith(status: TransferStatus.completed));
      debugPrint('Book received and saved: $expectedHash');
      _clearReceiveBuffer();
    } catch (error) {
      _failReceive(error.toString());
    } finally {
      _isAssembling = false;
    }
  }

  void _restartReceiveTimeout() {
    _receiveTimer?.cancel();
    _receiveTimer = Timer(receiveTimeout, () {
      _failReceive('Book transfer timed out');
    });
  }

  void _failReceive(String message) {
    _clearReceiveBuffer();
    _updateState(
      _state.copyWith(status: TransferStatus.failed, errorMessage: message),
    );
  }

  void reset() {
    _clearReceiveBuffer();
    _isAssembling = false;
    _updateState(const TransferState.idle());
  }

  void _clearReceiveBuffer() {
    _receiveTimer?.cancel();
    _receiveTimer = null;
    _receivedChunks.clear();
    _pendingSenderId = null;
    _pendingBookHash = null;
    _expectedTotalChunks = 0;
    _expectedTotalBytes = 0;
  }

  void _updateState(TransferState newState) {
    _state = newState;
    if (!_stateController.isClosed) _stateController.add(newState);
  }

  bool _isSha256(String hash) {
    return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash);
  }

  Future<void> dispose() {
    return _disposeFuture ??= _disposeInternal();
  }

  Future<void> _disposeInternal() async {
    _disposed = true;
    _clearReceiveBuffer();
    await Future.wait<void>([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    _subscriptions.clear();
    await _stateController.close();
  }
}

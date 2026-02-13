import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../config/app_constants.dart';
import '../models/transfer_state.dart';
import 'realtime_service.dart';
import 'epub_storage_service.dart';

class FileTransferService {
  final RealtimeService _realtimeService;
  final EpubStorageService _storageService;
  final String _currentUserId;

  final _stateController = StreamController<TransferState>.broadcast();
  TransferState _state = const TransferState.idle();
  final List<StreamSubscription> _subscriptions = [];

  // Receiving buffer
  final Map<int, Uint8List> _receivedChunks = {};
  String? _pendingBookHash;
  int _expectedTotalChunks = 0;

  FileTransferService({
    required RealtimeService realtimeService,
    required EpubStorageService storageService,
    required String currentUserId,
  })  : _realtimeService = realtimeService,
        _storageService = storageService,
        _currentUserId = currentUserId;

  Stream<TransferState> get stateStream => _stateController.stream;
  TransferState get currentState => _state;

  void initialize() {
    _subscriptions.add(
      _realtimeService.broadcastStream('book_chunk').listen(_onBookChunk),
    );
  }

  /// Send a book file to all room members via chunked broadcast
  Future<void> sendBook({
    required Uint8List fileBytes,
    required String bookHash,
  }) async {
    final totalChunks =
        (fileBytes.length / AppConstants.fileChunkSize).ceil();

    _updateState(TransferState(
      status: TransferStatus.transferring,
      bookHash: bookHash,
      totalBytes: fileBytes.length,
      transferredBytes: 0,
      totalChunks: totalChunks,
      receivedChunks: 0,
    ));

    for (int i = 0; i < totalChunks; i++) {
      final start = i * AppConstants.fileChunkSize;
      final end = start + AppConstants.fileChunkSize > fileBytes.length
          ? fileBytes.length
          : start + AppConstants.fileChunkSize;

      final chunk = fileBytes.sublist(start, end);
      final encoded = base64Encode(chunk);

      await _realtimeService.broadcast(
        event: 'book_chunk',
        payload: {
          'sender_id': _currentUserId,
          'book_hash': bookHash,
          'chunk_index': i,
          'total_chunks': totalChunks,
          'total_bytes': fileBytes.length,
          'data': encoded,
        },
      );

      _updateState(_state.copyWith(
        transferredBytes: end,
        receivedChunks: i + 1,
      ));

      // Rate limiting to avoid Supabase rate limits
      await Future.delayed(AppConstants.chunkDelay);
    }

    _updateState(_state.copyWith(status: TransferStatus.completed));
    debugPrint('Book sent: $totalChunks chunks');
  }

  void _onBookChunk(Map<String, dynamic> payload) {
    final senderId = payload['sender_id'] as String?;
    if (senderId == _currentUserId) return; // Ignore own chunks

    final bookHash = payload['book_hash'] as String? ?? '';
    final chunkIndex = payload['chunk_index'] as int? ?? 0;
    final totalChunks = payload['total_chunks'] as int? ?? 0;
    final totalBytes = payload['total_bytes'] as int? ?? 0;
    final data = payload['data'] as String? ?? '';

    // Initialize receiving state
    if (_receivedChunks.isEmpty || _pendingBookHash != bookHash) {
      _receivedChunks.clear();
      _pendingBookHash = bookHash;
      _expectedTotalChunks = totalChunks;

      _updateState(TransferState(
        status: TransferStatus.transferring,
        bookHash: bookHash,
        totalBytes: totalBytes,
        transferredBytes: 0,
        totalChunks: totalChunks,
        receivedChunks: 0,
      ));
    }

    try {
      final chunkBytes = base64Decode(data);
      _receivedChunks[chunkIndex] = chunkBytes;

      final received = _receivedChunks.values
          .fold<int>(0, (sum, chunk) => sum + chunk.length);

      _updateState(_state.copyWith(
        transferredBytes: received,
        receivedChunks: _receivedChunks.length,
      ));

      // Check if all chunks received
      if (_receivedChunks.length == _expectedTotalChunks) {
        _assembleAndSave(bookHash, totalBytes);
      }
    } catch (e) {
      debugPrint('Error processing chunk $chunkIndex: $e');
      _updateState(_state.copyWith(
        status: TransferStatus.failed,
        errorMessage: 'Error receiving chunk: $e',
      ));
    }
  }

  Future<void> _assembleAndSave(String expectedHash, int expectedSize) async {
    try {
      // Assemble chunks in order
      final builder = BytesBuilder();
      for (int i = 0; i < _expectedTotalChunks; i++) {
        final chunk = _receivedChunks[i];
        if (chunk == null) {
          throw Exception('Missing chunk $i');
        }
        builder.add(chunk);
      }

      final fullBytes = builder.toBytes();

      // Verify hash
      final hash = sha256.convert(fullBytes).toString();
      if (hash != expectedHash) {
        throw Exception(
            'Hash mismatch: expected $expectedHash, got $hash');
      }

      // Save to local storage
      await _storageService.saveBook(expectedHash, fullBytes);

      _updateState(_state.copyWith(status: TransferStatus.completed));
      debugPrint('Book received and saved: $expectedHash');

      // Clean up
      _receivedChunks.clear();
      _pendingBookHash = null;
    } catch (e) {
      debugPrint('Error assembling book: $e');
      _updateState(_state.copyWith(
        status: TransferStatus.failed,
        errorMessage: e.toString(),
      ));
      _receivedChunks.clear();
      _pendingBookHash = null;
    }
  }

  void reset() {
    _receivedChunks.clear();
    _pendingBookHash = null;
    _updateState(const TransferState.idle());
  }

  void _updateState(TransferState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _stateController.close();
  }
}

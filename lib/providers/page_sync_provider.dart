import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/page_sync_state.dart';
import '../services/page_sync_service.dart';
import '../services/realtime_service.dart';

final pageSyncProvider =
    StateNotifierProvider<PageSyncNotifier, PageSyncState>((ref) {
  return PageSyncNotifier();
});

class PageSyncNotifier extends StateNotifier<PageSyncState> {
  PageSyncService? _service;
  StreamSubscription? _subscription;

  /// Called when consensus is reached and the page should actually turn.
  void Function(PageTurnDirection direction)? onPageTurn;

  PageSyncNotifier() : super(const PageSyncState.idle());

  void initialize({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String currentNickname,
  }) {
    _service?.dispose();
    _subscription?.cancel();

    _service = PageSyncService(
      realtimeService: realtimeService,
      currentUserId: currentUserId,
      currentNickname: currentNickname,
    );

    _service!.onPageTurn = (direction) {
      onPageTurn?.call(direction);
    };

    _service!.initialize();

    _subscription = _service!.stateStream.listen((syncState) {
      state = syncState;
    });
  }

  Future<void> requestPageTurn({
    required PageTurnDirection direction,
    String? fromCfi,
  }) async {
    await _service?.requestPageTurn(
      direction: direction,
      fromCfi: fromCfi,
    );
  }

  Future<void> confirmPageTurn() async {
    await _service?.confirmPageTurn();
  }

  Future<void> declinePageTurn() async {
    await _service?.declinePageTurn();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _service?.dispose();
    super.dispose();
  }
}

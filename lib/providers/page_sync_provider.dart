import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/page_sync_state.dart';
import '../services/page_sync_service.dart';
import '../services/realtime_service.dart';

final pageSyncProvider = StateNotifierProvider<PageSyncNotifier, PageSyncState>(
  (ref) {
    return PageSyncNotifier();
  },
);

class PageSyncNotifier extends StateNotifier<PageSyncState> {
  PageSyncService? _service;
  StreamSubscription<PageSyncState>? _subscription;
  int _lifecycleGeneration = 0;

  void Function(PageTurnCommand command)? onPageTurn;
  void Function(PagePositionCommit commit)? onPositionCommit;
  void Function(String targetCfi)? onPositionRecovery;

  PageSyncNotifier() : super(const PageSyncState.idle());

  Future<void> initialize({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String currentNickname,
    required String readingSessionId,
    required Set<String> expectedParticipantUserIds,
    String? initialCfi,
  }) async {
    final generation = ++_lifecycleGeneration;
    await _stopResources(clearCallbacks: false);
    if (!mounted || generation != _lifecycleGeneration) return;
    state = const PageSyncState.idle();

    final service = PageSyncService(
      transport: RealtimePageSyncTransport(realtimeService),
      currentUserId: currentUserId,
      currentNickname: currentNickname,
      readingSessionId: readingSessionId,
      expectedParticipantUserIds: expectedParticipantUserIds,
    );
    _service = service;
    service.onPageTurn = (command) => onPageTurn?.call(command);
    service.onPositionCommit = (commit) => onPositionCommit?.call(commit);
    service.onPositionRecovery = (targetCfi) {
      onPositionRecovery?.call(targetCfi);
    };
    service.updateReaderContext(isReady: false, currentCfi: initialCfi);

    _subscription = service.stateStream.listen((syncState) {
      if (mounted && identical(_service, service)) state = syncState;
    });
    service.initialize();
  }

  void updateReaderContext({required bool isReady, String? currentCfi}) {
    _service?.updateReaderContext(isReady: isReady, currentCfi: currentCfi);
  }

  Future<bool> requestPageTurn({
    required PageTurnDirection direction,
    String? fromCfi,
  }) async {
    return await _service?.requestPageTurn(
          direction: direction,
          fromCfi: fromCfi,
        ) ??
        false;
  }

  Future<bool> confirmPageTurn() async {
    return await _service?.confirmPageTurn() ?? false;
  }

  Future<void> declinePageTurn() async {
    await _service?.declinePageTurn();
  }

  Future<bool> commitPagePosition(String targetCfi) async {
    return await _service?.commitPagePosition(targetCfi) ?? false;
  }

  Future<bool> acknowledgePagePosition(String targetCfi) async {
    return await _service?.acknowledgePagePosition(targetCfi) ?? false;
  }

  void reportPositionPersistenceFailure({
    required String requestId,
    required Object error,
  }) {
    _service?.reportPositionPersistenceFailure(
      requestId: requestId,
      error: error,
    );
  }

  bool isRequestActive(String requestId) {
    return _service?.isRequestActive(requestId) ?? false;
  }

  Future<void> leaveReadingSession() async {
    await _service?.leaveReadingSession();
  }

  Future<void> stop({bool clearCallbacks = true}) async {
    _lifecycleGeneration++;
    await _stopResources(clearCallbacks: clearCallbacks);
  }

  Future<void> _stopResources({required bool clearCallbacks}) async {
    final subscription = _subscription;
    final service = _service;
    _subscription = null;
    _service = null;
    await subscription?.cancel();
    await service?.dispose();
    if (clearCallbacks) {
      onPageTurn = null;
      onPositionCommit = null;
      onPositionRecovery = null;
    }
    if (mounted) state = const PageSyncState.idle();
  }

  @override
  void dispose() {
    _lifecycleGeneration++;
    unawaited(_subscription?.cancel());
    unawaited(_service?.dispose());
    _subscription = null;
    _service = null;
    onPageTurn = null;
    onPositionCommit = null;
    onPositionRecovery = null;
    super.dispose();
  }
}

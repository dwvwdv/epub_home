import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/page_sync_state.dart';
import 'realtime_service.dart';

class PageSyncService {
  final RealtimeService _realtimeService;
  final String _currentUserId;
  final String _currentNickname;
  final _uuid = const Uuid();

  Timer? _timeoutTimer;
  final _stateController = StreamController<PageSyncState>.broadcast();
  PageSyncState _state = const PageSyncState.idle();

  // Callback invoked when consensus is reached and page should turn
  void Function(PageTurnDirection direction)? onPageTurn;

  // Subscriptions
  final List<StreamSubscription> _subscriptions = [];

  PageSyncService({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String currentNickname,
  })  : _realtimeService = realtimeService,
        _currentUserId = currentUserId,
        _currentNickname = currentNickname;

  Stream<PageSyncState> get stateStream => _stateController.stream;
  PageSyncState get currentState => _state;

  void initialize() {
    _subscriptions.add(
      _realtimeService.broadcastStream('page_turn_request').listen(
        _onPageTurnRequest,
      ),
    );
    _subscriptions.add(
      _realtimeService.broadcastStream('page_turn_confirm').listen(
        _onPageTurnConfirm,
      ),
    );
    _subscriptions.add(
      _realtimeService.broadcastStream('page_turn_execute').listen(
        _onPageTurnExecute,
      ),
    );
    _subscriptions.add(
      _realtimeService.broadcastStream('page_turn_cancel').listen(
        _onPageTurnCancel,
      ),
    );
    _subscriptions.add(
      _realtimeService.presenceStream.listen(_onPresenceChange),
    );
  }

  Future<void> requestPageTurn({
    required PageTurnDirection direction,
    String? fromCfi,
  }) async {
    if (_state.status != SyncStatus.idle) return;

    // Get current online users
    final onlineUsers = _realtimeService.getOnlineUsers();
    final requiredIds = <String>{};
    for (final user in onlineUsers) {
      final userId = user['user_id'] as String?;
      if (userId != null) requiredIds.add(userId);
    }

    if (requiredIds.isEmpty) requiredIds.add(_currentUserId);

    final request = PageTurnRequest(
      requestId: _uuid.v4(),
      requestedByUserId: _currentUserId,
      requestedByNickname: _currentNickname,
      direction: direction,
      fromCfi: fromCfi,
      requestedAt: DateTime.now(),
      confirmedUserIds: {_currentUserId}, // Auto-confirm self
      requiredUserIds: requiredIds,
    );

    _updateState(PageSyncState(
      status: SyncStatus.requesting,
      currentRequest: request,
    ));

    // Check if solo reader
    if (request.isConsensusReached) {
      _executePageTurn(request);
      return;
    }

    // Broadcast request
    await _realtimeService.broadcast(
      event: 'page_turn_request',
      payload: request.toJson(),
    );

    // Start timeout
    _startTimeout(request.requestId);
  }

  Future<void> confirmPageTurn() async {
    final request = _state.currentRequest;
    if (request == null) return;
    if (_state.status != SyncStatus.confirming) return;

    await _realtimeService.broadcast(
      event: 'page_turn_confirm',
      payload: {
        'request_id': request.requestId,
        'user_id': _currentUserId,
      },
    );

    final updated = request.copyWith(
      confirmedUserIds: {...request.confirmedUserIds, _currentUserId},
    );

    _updateState(PageSyncState(
      status: SyncStatus.waiting,
      currentRequest: updated,
    ));

    _checkConsensus(updated);
  }

  Future<void> declinePageTurn() async {
    final request = _state.currentRequest;
    if (request == null) return;

    await _realtimeService.broadcast(
      event: 'page_turn_cancel',
      payload: {
        'request_id': request.requestId,
        'reason': 'declined_by_$_currentNickname',
      },
    );

    _cancelTimeout();
    _updateState(const PageSyncState.idle());
  }

  void _onPageTurnRequest(Map<String, dynamic> payload) {
    final incomingRequest = PageTurnRequest.fromJson(payload);

    // Ignore our own request (we already handle it locally)
    if (incomingRequest.requestedByUserId == _currentUserId) return;

    if (_state.status == SyncStatus.idle) {
      _updateState(PageSyncState(
        status: SyncStatus.confirming,
        currentRequest: incomingRequest,
      ));
    } else if (_state.status == SyncStatus.requesting) {
      // Race condition: compare request IDs, lower wins
      final current = _state.currentRequest!;
      if (incomingRequest.requestId.compareTo(current.requestId) < 0) {
        // Incoming request wins - cancel ours, adopt theirs
        _cancelTimeout();
        _updateState(PageSyncState(
          status: SyncStatus.confirming,
          currentRequest: incomingRequest,
        ));
      }
      // Otherwise our request wins, ignore the incoming one
    }
  }

  void _onPageTurnConfirm(Map<String, dynamic> payload) {
    final requestId = payload['request_id'] as String?;
    final userId = payload['user_id'] as String?;
    if (requestId == null || userId == null) return;

    final current = _state.currentRequest;
    if (current == null || current.requestId != requestId) return;

    final updated = current.copyWith(
      confirmedUserIds: {...current.confirmedUserIds, userId},
    );

    _updateState(_state.copyWith(currentRequest: updated));
    _checkConsensus(updated);
  }

  void _onPageTurnExecute(Map<String, dynamic> payload) {
    final requestId = payload['request_id'] as String?;
    final directionStr = payload['direction'] as String?;

    final current = _state.currentRequest;
    if (current == null || current.requestId != requestId) return;

    _cancelTimeout();
    final direction = directionStr == 'next'
        ? PageTurnDirection.next
        : PageTurnDirection.previous;

    _updateState(PageSyncState(
      status: SyncStatus.turning,
      currentRequest: current,
    ));

    onPageTurn?.call(direction);

    // Return to idle after a short delay
    Future.delayed(const Duration(milliseconds: 500), () {
      _updateState(const PageSyncState.idle());
    });
  }

  void _onPageTurnCancel(Map<String, dynamic> payload) {
    final requestId = payload['request_id'] as String?;
    final current = _state.currentRequest;
    if (current == null || current.requestId != requestId) return;

    _cancelTimeout();
    _updateState(const PageSyncState.idle());
    debugPrint('Page turn cancelled: ${payload['reason']}');
  }

  void _onPresenceChange(Map<String, dynamic> event) {
    if (event['event'] != 'leave') return;

    final current = _state.currentRequest;
    if (current == null) return;

    // Remove disconnected users from required set
    final payload = event['payload'];
    if (payload is Map<String, dynamic>) {
      final leftPresences = payload['leftPresences'];
      if (leftPresences is List) {
        final leftUserIds = <String>{};
        for (final p in leftPresences) {
          if (p is Map<String, dynamic>) {
            final userId = p['user_id'] as String?;
            if (userId != null) leftUserIds.add(userId);
          }
        }

        if (leftUserIds.isEmpty) return;

        final updatedRequired =
            current.requiredUserIds.difference(leftUserIds);
        final updated = current.copyWith(requiredUserIds: updatedRequired);

        _updateState(_state.copyWith(currentRequest: updated));
        _checkConsensus(updated);
      }
    }
  }

  void _checkConsensus(PageTurnRequest request) {
    if (!request.isConsensusReached) return;

    // Only the requester broadcasts execute to avoid duplicate broadcasts
    if (request.requestedByUserId == _currentUserId) {
      _executePageTurn(request);
    }
  }

  Future<void> _executePageTurn(PageTurnRequest request) async {
    _cancelTimeout();

    await _realtimeService.broadcast(
      event: 'page_turn_execute',
      payload: {
        'request_id': request.requestId,
        'direction':
            request.direction == PageTurnDirection.next ? 'next' : 'previous',
      },
    );

    _updateState(PageSyncState(
      status: SyncStatus.turning,
      currentRequest: request,
    ));

    onPageTurn?.call(request.direction);

    Future.delayed(const Duration(milliseconds: 500), () {
      _updateState(const PageSyncState.idle());
    });
  }

  void _startTimeout(String requestId) {
    _cancelTimeout();
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      final current = _state.currentRequest;
      if (current != null && current.requestId == requestId) {
        _realtimeService.broadcast(
          event: 'page_turn_cancel',
          payload: {
            'request_id': requestId,
            'reason': 'timeout',
          },
        );
        _updateState(const PageSyncState.idle());
      }
    });
  }

  void _cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void _updateState(PageSyncState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  void dispose() {
    _cancelTimeout();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _stateController.close();
  }
}

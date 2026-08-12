import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/page_sync_state.dart';
import 'realtime_service.dart';

/// The small Realtime surface used by page synchronization.
///
/// Keeping this transport injectable makes the consensus state machine testable
/// without a live Supabase channel.
abstract interface class PageSyncTransport {
  Stream<Map<String, dynamic>> broadcastStream(String event);

  Stream<Map<String, dynamic>> get presenceStream;

  List<Map<String, dynamic>> getOnlineUsers();

  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  });
}

class RealtimePageSyncTransport implements PageSyncTransport {
  final RealtimeService _realtimeService;

  const RealtimePageSyncTransport(this._realtimeService);

  @override
  Stream<Map<String, dynamic>> broadcastStream(String event) =>
      _realtimeService.broadcastStream(event);

  @override
  Stream<Map<String, dynamic>> get presenceStream =>
      _realtimeService.presenceStream;

  @override
  List<Map<String, dynamic>> getOnlineUsers() =>
      _realtimeService.getOnlineUsers();

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) {
    return _realtimeService.broadcast(event: event, payload: payload);
  }
}

class PageSyncService {
  static const _requestTimeout = Duration(seconds: 30);

  final PageSyncTransport _transport;
  final String _currentUserId;
  final String _currentNickname;
  final Uuid _uuid;

  final _stateController = StreamController<PageSyncState>.broadcast();
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  final Set<String> _handledExecuteIds = {};
  final Set<String> _handledCommitIds = {};
  final Set<String> _executeInFlightIds = {};
  final Set<String> _seenRequestIds = {};

  Timer? _timeoutTimer;
  PageSyncState _state = const PageSyncState.idle();
  bool _initialized = false;
  bool _disposed = false;
  bool _presenceSynchronized = false;
  bool _readerReady = false;
  String? _currentCfi;

  void Function(PageTurnCommand command)? onPageTurn;
  void Function(PagePositionCommit commit)? onPositionCommit;

  PageSyncService({
    required PageSyncTransport transport,
    required String currentUserId,
    required String currentNickname,
    Uuid uuid = const Uuid(),
  })  : _transport = transport,
        _currentUserId = currentUserId,
        _currentNickname = currentNickname,
        _uuid = uuid;

  Stream<PageSyncState> get stateStream => _stateController.stream;
  PageSyncState get currentState => _state;

  void initialize() {
    if (_initialized || _disposed) return;
    _initialized = true;

    _subscriptions.addAll([
      _transport
          .broadcastStream('page_turn_request')
          .listen(_onPageTurnRequest),
      _transport
          .broadcastStream('page_turn_confirm')
          .listen(_onPageTurnConfirm),
      _transport
          .broadcastStream('page_turn_execute')
          .listen(_onPageTurnExecute),
      _transport
          .broadcastStream('page_turn_cancel')
          .listen(_onPageTurnCancel),
      _transport
          .broadcastStream('page_position_commit')
          .listen(_onPagePositionCommit),
      _transport.presenceStream.listen(_onPresenceChange),
    ]);

    _presenceSynchronized = _transport.getOnlineUsers().any(
          (user) => user['user_id'] == _currentUserId,
        );
    _updateState(const PageSyncState.idle());
  }

  void updateReaderContext({required bool isReady, String? currentCfi}) {
    if (_disposed) return;
    _readerReady = isReady;
    if (currentCfi != null && currentCfi.isNotEmpty) {
      _currentCfi = currentCfi;
    }

    final request = _state.currentRequest;
    if (request != null &&
        _state.status != SyncStatus.turning &&
        (!isReady || _currentCfi != request.fromCfi)) {
      unawaited(_cancelRequest(request, 'reader_became_unready'));
    }
  }

  Future<bool> requestPageTurn({
    required PageTurnDirection direction,
    String? fromCfi,
  }) async {
    if (_disposed || !_initialized) return false;
    if (_state.status != SyncStatus.idle || _state.currentRequest != null) {
      return false;
    }

    final sourceCfi = fromCfi ?? _currentCfi;
    if (!_readerReady || sourceCfi == null || sourceCfi.isEmpty) {
      _setError('Reader is not ready yet');
      return false;
    }
    if (_currentCfi != sourceCfi) {
      _setError('Page changed before the request could start');
      return false;
    }

    final quorum = _buildReadyReaderQuorum();
    if (quorum.error != null) {
      _setError(quorum.error!);
      return false;
    }

    final request = PageTurnRequest(
      requestId: _uuid.v4(),
      requestedByUserId: _currentUserId,
      requestedByNickname: _currentNickname,
      direction: direction,
      fromCfi: sourceCfi,
      requestedAt: DateTime.now().toUtc(),
      confirmedUserIds: {_currentUserId},
      requiredUserIds: quorum.userIds,
    );
    _seenRequestIds.add(request.requestId);

    _updateState(PageSyncState(
      status: SyncStatus.requesting,
      currentRequest: request,
    ));
    _startTimeout(request.requestId);

    try {
      await _transport.broadcast(
        event: 'page_turn_request',
        payload: request.toJson(),
      );
    } catch (error) {
      _setError('Could not request a page turn: $error');
      return false;
    }

    if (request.isConsensusReached) {
      await _executePageTurn(request);
    }
    return _state.currentRequest?.requestId == request.requestId;
  }

  Future<bool> confirmPageTurn() async {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        _state.status != SyncStatus.confirming ||
        !request.requiredUserIds.contains(_currentUserId) ||
        !_readerReady ||
        _currentCfi != request.fromCfi) {
      if (request != null && _currentCfi != request.fromCfi) {
        await _cancelRequest(request, 'stale_page_position');
      }
      return false;
    }

    try {
      await _transport.broadcast(
        event: 'page_turn_confirm',
        payload: {
          'request_id': request.requestId,
          'user_id': _currentUserId,
        },
      );
    } catch (error) {
      _setError('Could not confirm the page turn: $error');
      return false;
    }

    final current = _state.currentRequest;
    if (current == null || current.requestId != request.requestId) return false;
    final updated = current.copyWith(
      confirmedUserIds: {...current.confirmedUserIds, _currentUserId},
    );
    _updateState(PageSyncState(
      status: SyncStatus.waiting,
      currentRequest: updated,
    ));
    _checkConsensus(updated);
    return true;
  }

  Future<void> declinePageTurn() async {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        !request.requiredUserIds.contains(_currentUserId)) {
      return;
    }
    await _cancelRequest(request, 'declined_by_$_currentNickname');
  }

  /// Called by the requester after its programmatic page turn relocates.
  Future<bool> commitPagePosition(String targetCfi) async {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        request.requestedByUserId != _currentUserId ||
        _state.status != SyncStatus.turning ||
        !_handledExecuteIds.contains(request.requestId) ||
        targetCfi.isEmpty) {
      return false;
    }

    final commit = PagePositionCommit(
      requestId: request.requestId,
      requestedByUserId: request.requestedByUserId,
      direction: request.direction,
      fromCfi: request.fromCfi,
      targetCfi: targetCfi,
    );

    try {
      await _transport.broadcast(
        event: 'page_position_commit',
        payload: commit.toJson(),
      );
    } catch (error) {
      _setError('Could not synchronize the new page: $error');
      return false;
    }

    _applyPositionCommit(commit);
    return true;
  }

  void _onPageTurnRequest(Map<String, dynamic> payload) {
    if (_disposed) return;

    final PageTurnRequest incoming;
    try {
      incoming = PageTurnRequest.fromJson(payload);
    } on FormatException {
      return;
    }

    final current = _state.currentRequest;
    if (current?.requestId == incoming.requestId) return;
    if (!_seenRequestIds.add(incoming.requestId)) return;
    if (incoming.requestedByUserId == _currentUserId && current == null) return;

    if (!_isValidIncomingRequest(incoming)) {
      unawaited(_broadcastCancel(incoming, 'invalid_or_stale_request'));
      return;
    }

    if (current == null) {
      _adoptIncomingRequest(incoming);
      return;
    }

    // Once execution starts it is the deterministic winner. Before that, every
    // state uses the lexicographically lower UUID, not arrival order.
    final currentWins = _state.status == SyncStatus.turning ||
        current.requestId.compareTo(incoming.requestId) < 0;
    if (currentWins) {
      unawaited(_rebroadcastRequest(current));
      return;
    }

    _cancelTimeout();
    _adoptIncomingRequest(incoming);
  }

  bool _isValidIncomingRequest(PageTurnRequest request) {
    if (!_readerReady || _currentCfi != request.fromCfi) return false;
    if (request.requiredUserIds.isEmpty ||
        !request.requiredUserIds.contains(request.requestedByUserId) ||
        !request.requiredUserIds.contains(_currentUserId)) {
      return false;
    }

    final quorum = _buildReadyReaderQuorum();
    if (quorum.error != null) return false;
    return request.requiredUserIds.length == quorum.userIds.length &&
        request.requiredUserIds.every(quorum.userIds.contains);
  }

  void _adoptIncomingRequest(PageTurnRequest request) {
    _updateState(PageSyncState(
      status: request.requestedByUserId == _currentUserId
          ? SyncStatus.requesting
          : SyncStatus.confirming,
      currentRequest: request,
    ));
    _startTimeout(request.requestId);
    _checkConsensus(request);
  }

  void _onPageTurnConfirm(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final userId = payload['user_id'];
    if (requestId is! String || userId is! String) return;

    final current = _state.currentRequest;
    if (current == null ||
        current.requestId != requestId ||
        !current.requiredUserIds.contains(userId)) {
      return;
    }

    final updated = current.copyWith(
      confirmedUserIds: {...current.confirmedUserIds, userId},
    );
    _updateState(_state.copyWith(
      currentRequest: updated,
      clearError: true,
    ));
    _checkConsensus(updated);
  }

  void _onPageTurnExecute(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final requestedByUserId = payload['requested_by_user_id'];
    final direction = pageTurnDirectionFromWire(payload['direction']);
    final current = _state.currentRequest;

    if (requestId is! String ||
        requestedByUserId is! String ||
        direction == null ||
        current == null ||
        current.requestId != requestId ||
        current.requestedByUserId != requestedByUserId ||
        current.direction != direction) {
      return;
    }

    _applyExecute(current);
  }

  void _applyExecute(PageTurnRequest request) {
    if (_disposed || !_handledExecuteIds.add(request.requestId)) return;
    _updateState(PageSyncState(
      status: SyncStatus.turning,
      currentRequest: request,
    ));
    onPageTurn?.call(PageTurnCommand(
      requestId: request.requestId,
      direction: request.direction,
      fromCfi: request.fromCfi,
      isRequester: request.requestedByUserId == _currentUserId,
    ));
  }

  void _onPagePositionCommit(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final requestedByUserId = payload['requested_by_user_id'];
    final direction = pageTurnDirectionFromWire(payload['direction']);
    final fromCfi = payload['from_cfi'];
    final targetCfi = payload['target_cfi'];
    final current = _state.currentRequest;

    if (requestId is! String ||
        requestedByUserId is! String ||
        direction == null ||
        fromCfi is! String ||
        targetCfi is! String ||
        targetCfi.isEmpty ||
        current == null ||
        current.requestId != requestId ||
        current.requestedByUserId != requestedByUserId ||
        current.direction != direction ||
        current.fromCfi != fromCfi ||
        !_handledExecuteIds.contains(requestId)) {
      return;
    }

    _applyPositionCommit(PagePositionCommit(
      requestId: requestId,
      requestedByUserId: requestedByUserId,
      direction: direction,
      fromCfi: fromCfi,
      targetCfi: targetCfi,
    ));
  }

  void _applyPositionCommit(PagePositionCommit commit) {
    if (_disposed || !_handledCommitIds.add(commit.requestId)) return;
    _cancelTimeout();
    _currentCfi = commit.targetCfi;
    _updateState(const PageSyncState.idle());
    onPositionCommit?.call(commit);
  }

  void _onPageTurnCancel(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final userId = payload['user_id'];
    final current = _state.currentRequest;
    if (requestId is! String ||
        userId is! String ||
        current == null ||
        current.requestId != requestId ||
        !current.requiredUserIds.contains(userId)) {
      return;
    }

    _cancelTimeout();
    final reason = payload['reason'] as String? ?? 'cancelled';
    _setError('Page turn cancelled: $reason');
  }

  void _onPresenceChange(Map<String, dynamic> event) {
    if (_disposed) return;
    final eventType = event['event'];
    if (eventType == 'sync') {
      _presenceSynchronized = true;
    }
    if (eventType != 'leave' && eventType != 'sync') return;

    final current = _state.currentRequest;
    if (current == null) return;

    final onlineUsers = _transport.getOnlineUsers();
    final remainingRequired = current.requiredUserIds.where((userId) {
      return _isReadyReaderOnline(userId, onlineUsers);
    }).toSet();
    if (remainingRequired.length == current.requiredUserIds.length) return;
    if (eventType == 'sync') {
      unawaited(_cancelRequest(current, 'required_reader_not_ready'));
      return;
    }
    if (remainingRequired.isEmpty ||
        !remainingRequired.contains(current.requestedByUserId)) {
      unawaited(_cancelRequest(current, 'requester_left'));
      return;
    }

    final updated = current.copyWith(requiredUserIds: remainingRequired);
    _updateState(_state.copyWith(
      currentRequest: updated,
      clearError: true,
    ));
    _checkConsensus(updated);
  }

  void _checkConsensus(PageTurnRequest request) {
    if (!request.isConsensusReached ||
        request.requestedByUserId != _currentUserId ||
        _executeInFlightIds.contains(request.requestId) ||
        _handledExecuteIds.contains(request.requestId)) {
      return;
    }
    unawaited(_executePageTurn(request));
  }

  Future<void> _executePageTurn(PageTurnRequest request) async {
    if (!_executeInFlightIds.add(request.requestId)) return;
    _updateState(PageSyncState(
      status: SyncStatus.turning,
      currentRequest: request,
    ));

    try {
      await _transport.broadcast(
        event: 'page_turn_execute',
        payload: {
          'request_id': request.requestId,
          'requested_by_user_id': request.requestedByUserId,
          'direction': pageTurnDirectionToWire(request.direction),
        },
      );
      // Realtime is configured with self:true. If the echo arrived while send
      // was awaited, this is a no-op; otherwise this provides the one local run.
      _applyExecute(request);
    } catch (error) {
      _setError('Could not execute the page turn: $error');
    } finally {
      _executeInFlightIds.remove(request.requestId);
    }
  }

  Future<void> _cancelRequest(PageTurnRequest request, String reason) async {
    try {
      await _broadcastCancel(request, reason);
    } catch (error) {
      _setError('Could not cancel the page turn: $error');
      return;
    }
    if (_state.currentRequest?.requestId == request.requestId) {
      _setError('Page turn cancelled: $reason');
    }
  }

  Future<void> _broadcastCancel(
    PageTurnRequest request,
    String reason,
  ) {
    return _transport.broadcast(
      event: 'page_turn_cancel',
      payload: {
        'request_id': request.requestId,
        'user_id': _currentUserId,
        'reason': reason,
      },
    );
  }

  Future<void> _rebroadcastRequest(PageTurnRequest request) async {
    try {
      await _transport.broadcast(
        event: 'page_turn_request',
        payload: request.toJson(),
      );
    } catch (_) {
      // The original request still has its timeout. A failed convergence hint
      // must not replace valid local state with an unrelated network error.
    }
  }

  _ReadyReaderQuorum _buildReadyReaderQuorum() {
    final users = _transport.getOnlineUsers();
    final hasCurrentPresence = users.any(
      (user) => user['user_id'] == _currentUserId,
    );
    if (!_presenceSynchronized && hasCurrentPresence) {
      _presenceSynchronized = true;
    }
    if (!_presenceSynchronized || !hasCurrentPresence) {
      return const _ReadyReaderQuorum.error(
        'Waiting for room presence to synchronize',
      );
    }

    final readyUserIds = <String>{};
    var hasUnreadyReader = false;
    for (final user in users) {
      final userId = user['user_id'];
      if (userId is! String || user['is_reading'] != true) continue;

      if (userId == _currentUserId) {
        if (_readerReady && user['reader_ready'] == true) {
          readyUserIds.add(userId);
        } else {
          hasUnreadyReader = true;
        }
        continue;
      }

      if (user['reader_ready'] == true) {
        readyUserIds.add(userId);
      } else {
        // Never omit a loading/legacy reader from the quorum. Doing so would
        // silently turn a multi-reader room into a solo page turn.
        hasUnreadyReader = true;
      }
    }

    if (hasUnreadyReader) {
      return const _ReadyReaderQuorum.error(
        'Waiting for every reader to become ready',
      );
    }
    if (!readyUserIds.contains(_currentUserId)) {
      return const _ReadyReaderQuorum.error(
        'This reader is not present and ready',
      );
    }
    return _ReadyReaderQuorum(readyUserIds);
  }

  bool _isReadyReaderOnline(
    String userId,
    List<Map<String, dynamic>> users,
  ) {
    return users.any((user) {
      if (user['user_id'] != userId || user['is_reading'] != true) return false;
      if (userId == _currentUserId) return _readerReady;
      return user['reader_ready'] == true;
    });
  }

  void _startTimeout(String requestId) {
    _cancelTimeout();
    _timeoutTimer = Timer(_requestTimeout, () {
      if (_disposed || _state.currentRequest?.requestId != requestId) return;
      final request = _state.currentRequest!;
      unawaited(_sendTimeoutCancel(request));
      _setError('Page turn timed out');
    });
  }

  Future<void> _sendTimeoutCancel(PageTurnRequest request) async {
    try {
      await _broadcastCancel(request, 'timeout');
    } catch (_) {
      // Timeout already moved the local state to a safe idle error state.
    }
  }

  void _cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void _setError(String message) {
    _cancelTimeout();
    _updateState(PageSyncState.error(message));
  }

  void _updateState(PageSyncState newState) {
    if (_disposed) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelTimeout();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    onPageTurn = null;
    onPositionCommit = null;
    await _stateController.close();
  }
}

class _ReadyReaderQuorum {
  final Set<String> userIds;
  final String? error;

  const _ReadyReaderQuorum(this.userIds) : error = null;

  const _ReadyReaderQuorum.error(this.error) : userIds = const {};
}

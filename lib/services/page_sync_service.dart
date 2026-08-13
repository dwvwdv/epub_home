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
  static const _maxClockSkew = Duration(seconds: 5);

  /// How long a failure stays on screen before the bar returns to idle.
  ///
  /// Every failure here is transient by construction: the protocol always
  /// lands back on [SyncStatus.idle], so a message that never clears reads as
  /// a permanently stuck reader even though page turns still work.
  static const defaultErrorAutoClearDelay = Duration(seconds: 6);

  final PageSyncTransport _transport;
  final String _currentUserId;
  final String _currentNickname;
  final String _readingSessionId;
  final Set<String> _sessionParticipantUserIds;
  final Set<String> _expectedParticipantUserIds;
  final Uuid _uuid;
  final Duration _requestTimeout;
  final Duration _errorAutoClearDelay;

  final _stateController = StreamController<PageSyncState>.broadcast();
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  final Set<String> _handledExecuteIds = {};
  final Set<String> _handledCommitIds = {};
  final Set<String> _handledCompleteIds = {};
  final Set<String> _executeInFlightIds = {};
  final Set<String> _ackInFlightIds = {};
  final Set<String> _sentAckIds = {};
  final Set<String> _completeInFlightIds = {};
  final Set<String> _seenRequestIds = {};
  final Set<String> _enteredReaderParticipantIds = {};
  final Set<String> _explicitlyLeftParticipantUserIds = {};

  Timer? _timeoutTimer;
  Timer? _errorAutoClearTimer;
  PageSyncState _state = const PageSyncState.idle();
  bool _initialized = false;
  bool _disposed = false;
  bool _presenceSynchronized = false;
  bool _readerReady = false;
  String? _currentCfi;
  PagePositionCommit? _positionCommit;
  final Set<String> _positionAckUserIds = {};

  void Function(PageTurnCommand command)? onPageTurn;
  void Function(PagePositionCommit commit)? onPositionCommit;
  void Function(String targetCfi, bool positionWasCommitted)?
      onPositionRecovery;

  PageSyncService({
    required PageSyncTransport transport,
    required String currentUserId,
    required String currentNickname,
    required String readingSessionId,
    required Set<String> expectedParticipantUserIds,
    Uuid uuid = const Uuid(),
    Duration requestTimeout = const Duration(seconds: 30),
    Duration errorAutoClearDelay = defaultErrorAutoClearDelay,
  }) : _transport = transport,
       _currentUserId = currentUserId,
       _currentNickname = currentNickname,
       _readingSessionId = readingSessionId,
       _sessionParticipantUserIds = {
         ...expectedParticipantUserIds,
         currentUserId,
       },
       _expectedParticipantUserIds = Set.of(expectedParticipantUserIds)
         ..add(currentUserId),
       _uuid = uuid,
       _requestTimeout = requestTimeout,
       _errorAutoClearDelay = errorAutoClearDelay;

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
      _transport.broadcastStream('page_turn_cancel').listen(_onPageTurnCancel),
      _transport
          .broadcastStream('page_position_persisting')
          .listen(_onPositionPersisting),
      _transport
          .broadcastStream('page_position_commit')
          .listen(_onPagePositionCommit),
      _transport
          .broadcastStream('page_position_ack')
          .listen(_onPagePositionAck),
      _transport
          .broadcastStream('page_turn_complete')
          .listen(_onPageTurnComplete),
      _transport
          .broadcastStream('reading_session_leave')
          .listen(_onReadingSessionLeave),
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
      sessionId: _readingSessionId,
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

    _updateState(
      PageSyncState(status: SyncStatus.requesting, currentRequest: request),
    );
    _startTimeout(request.requestId);

    try {
      await _transport.broadcast(
        event: 'page_turn_request',
        payload: request.toJson(),
      );
    } catch (error) {
      _failRequest(request, 'Could not request a page turn: $error');
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
        payload: {'request_id': request.requestId, 'user_id': _currentUserId},
      );
    } catch (error) {
      _failRequest(request, 'Could not confirm the page turn: $error');
      return false;
    }

    final current = _state.currentRequest;
    if (current == null || current.requestId != request.requestId) return false;
    final updated = current.copyWith(
      confirmedUserIds: {...current.confirmedUserIds, _currentUserId},
    );
    _updateState(
      PageSyncState(status: SyncStatus.waiting, currentRequest: updated),
    );
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
      _startTimeout(request.requestId);
      _updateState(
        _state.copyWith(
          errorMessage: 'Page saved, but synchronization failed; retrying: $error',
        ),
      );
      return false;
    }

    _applyPositionCommit(commit);
    return true;
  }

  void reportPositionPersistenceFailure({
    required String requestId,
    required Object error,
  }) {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        request.requestId != requestId ||
        !_handledExecuteIds.contains(requestId)) {
      return;
    }
    _startTimeout(requestId);
    _updateState(
      _state.copyWith(
        errorMessage: 'Page moved, but saving failed; retrying: $error',
      ),
    );
  }

  /// Database page writes are not safely cancellable: an HTTP timeout does not
  /// prove the server transaction was rolled back. Pause the protocol timeout
  /// while the sole writer waits for an unambiguous database result.
  Future<bool> beginPositionPersistence(String requestId) async {
    final request = _state.currentRequest;
    if (_disposed ||
        request == null ||
        request.requestId != requestId ||
        request.requestedByUserId != _currentUserId ||
        _state.status != SyncStatus.turning ||
        !_handledExecuteIds.contains(requestId)) {
      return false;
    }
    final payload = {
      'request_id': requestId,
      'requested_by_user_id': _currentUserId,
    };
    try {
      await _transport.broadcast(
        event: 'page_position_persisting',
        payload: payload,
      );
    } catch (_) {
      await _cancelRequest(request, 'persistence_coordination_failed');
      return false;
    }
    _applyPositionPersisting(payload);
    return _state.currentRequest?.requestId == requestId;
  }

  bool isRequestActive(String requestId) {
    return !_disposed && _state.currentRequest?.requestId == requestId;
  }

  Future<void> leaveReadingSession() async {
    if (_disposed || !_initialized) return;
    final payload = {
      'session_id': _readingSessionId,
      'user_id': _currentUserId,
    };
    try {
      await _transport.broadcast(
        event: 'reading_session_leave',
        payload: payload,
      );
    } finally {
      _onReadingSessionLeave(payload);
    }
  }

  /// Acknowledges that this reader has actually displayed the committed CFI.
  ///
  /// The request remains locked until every required reader acknowledges and
  /// the requester broadcasts a final completion event. This prevents a fast
  /// client from starting another turn while a slower client is still moving.
  Future<bool> acknowledgePagePosition(String targetCfi) async {
    final request = _state.currentRequest;
    final commit = _positionCommit;
    if (_disposed ||
        request == null ||
        commit == null ||
        request.requestId != commit.requestId ||
        _state.status != SyncStatus.turning ||
        !request.requiredUserIds.contains(_currentUserId) ||
        !_readerReady ||
        _currentCfi != targetCfi ||
        commit.targetCfi != targetCfi) {
      return false;
    }
    if (_sentAckIds.contains(request.requestId)) return true;
    if (!_ackInFlightIds.add(request.requestId)) return true;

    try {
      await _transport.broadcast(
        event: 'page_position_ack',
        payload: {
          'request_id': request.requestId,
          'user_id': _currentUserId,
          'target_cfi': targetCfi,
        },
      );
      _sentAckIds.add(request.requestId);
      _applyPositionAck(
        requestId: request.requestId,
        userId: _currentUserId,
        targetCfi: targetCfi,
      );
      return true;
    } catch (error) {
      _failRequest(request, 'Could not acknowledge the new page: $error');
      return false;
    } finally {
      _ackInFlightIds.remove(request.requestId);
    }
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
    final currentWins =
        _state.status == SyncStatus.turning ||
        current.requestId.compareTo(incoming.requestId) < 0;
    if (currentWins) {
      unawaited(_rebroadcastRequest(current));
      return;
    }

    _cancelTimeout();
    _adoptIncomingRequest(incoming);
  }

  bool _isValidIncomingRequest(PageTurnRequest request) {
    if (request.sessionId != _readingSessionId ||
        !_readerReady ||
        _currentCfi != request.fromCfi) {
      return false;
    }
    final age = DateTime.now().toUtc().difference(request.requestedAt);
    if (age > _requestTimeout || age < -_maxClockSkew) return false;
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
    _updateState(
      PageSyncState(
        status: request.requestedByUserId == _currentUserId
            ? SyncStatus.requesting
            : SyncStatus.confirming,
        currentRequest: request,
      ),
    );
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
        !current.requiredUserIds.contains(userId) ||
        !_isReadyReaderOnline(userId, _transport.getOnlineUsers())) {
      return;
    }

    final updated = current.copyWith(
      confirmedUserIds: {...current.confirmedUserIds, userId},
    );
    _updateState(_state.copyWith(currentRequest: updated, clearError: true));
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
        current.direction != direction ||
        !current.isConsensusReached) {
      return;
    }

    if (!_isRequestQuorumStillReady(current)) {
      unawaited(_cancelRequest(current, 'required_reader_not_ready'));
      return;
    }

    _applyExecute(current);
  }

  void _applyExecute(PageTurnRequest request) {
    if (_disposed || !_handledExecuteIds.add(request.requestId)) return;
    _startTimeout(request.requestId);
    _updateState(
      PageSyncState(status: SyncStatus.turning, currentRequest: request),
    );
    onPageTurn?.call(
      PageTurnCommand(
        requestId: request.requestId,
        direction: request.direction,
        fromCfi: request.fromCfi,
        isRequester: request.requestedByUserId == _currentUserId,
      ),
    );
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

    _applyPositionCommit(
      PagePositionCommit(
        requestId: requestId,
        requestedByUserId: requestedByUserId,
        direction: direction,
        fromCfi: fromCfi,
        targetCfi: targetCfi,
      ),
    );
  }

  void _onPositionPersisting(Map<String, dynamic> payload) {
    _applyPositionPersisting(payload);
  }

  void _applyPositionPersisting(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final requestedByUserId = payload['requested_by_user_id'];
    final request = _state.currentRequest;
    if (requestId is! String ||
        requestedByUserId is! String ||
        request == null ||
        request.requestId != requestId ||
        request.requestedByUserId != requestedByUserId ||
        _state.status != SyncStatus.turning ||
        !_handledExecuteIds.contains(requestId)) {
      return;
    }
    _cancelTimeout();
    _updateState(_state.copyWith(clearError: true));
  }

  void _applyPositionCommit(PagePositionCommit commit) {
    if (_disposed || !_handledCommitIds.add(commit.requestId)) return;
    _positionCommit = commit;
    _positionAckUserIds.clear();
    _startTimeout(commit.requestId);
    _updateState(
      PageSyncState(
        status: SyncStatus.turning,
        currentRequest: _state.currentRequest,
      ),
    );
    onPositionCommit?.call(commit);
  }

  void _onPagePositionAck(Map<String, dynamic> payload) {
    final requestId = payload['request_id'];
    final userId = payload['user_id'];
    final targetCfi = payload['target_cfi'];
    if (requestId is! String || userId is! String || targetCfi is! String) {
      return;
    }
    _applyPositionAck(
      requestId: requestId,
      userId: userId,
      targetCfi: targetCfi,
    );
  }

  void _applyPositionAck({
    required String requestId,
    required String userId,
    required String targetCfi,
  }) {
    if (_disposed) return;
    final request = _state.currentRequest;
    final commit = _positionCommit;
    if (request == null ||
        commit == null ||
        request.requestId != requestId ||
        commit.requestId != requestId ||
        commit.targetCfi != targetCfi ||
        !request.requiredUserIds.contains(userId)) {
      return;
    }

    _positionAckUserIds.add(userId);
    _checkDisplayCompletion(request, commit);
  }

  void _checkDisplayCompletion(
    PageTurnRequest request,
    PagePositionCommit commit,
  ) {
    if (request.requestedByUserId == _currentUserId &&
        request.requiredUserIds.every(_positionAckUserIds.contains)) {
      unawaited(_completePageTurn(request, commit));
    }
  }

  Future<void> _completePageTurn(
    PageTurnRequest request,
    PagePositionCommit commit,
  ) async {
    if (_handledCompleteIds.contains(request.requestId) ||
        !_completeInFlightIds.add(request.requestId)) {
      return;
    }
    try {
      await _transport.broadcast(
        event: 'page_turn_complete',
        payload: {
          ...commit.toJson(),
          'completed_by_user_id': request.requestedByUserId,
        },
      );
      _applyPageTurnComplete(request, commit);
    } catch (error) {
      _failRequest(request, 'Could not complete the page turn: $error');
    } finally {
      _completeInFlightIds.remove(request.requestId);
    }
  }

  void _onPageTurnComplete(Map<String, dynamic> payload) {
    if (_disposed) return;
    final requestId = payload['request_id'];
    final requestedByUserId = payload['requested_by_user_id'];
    final completedByUserId = payload['completed_by_user_id'];
    final direction = pageTurnDirectionFromWire(payload['direction']);
    final fromCfi = payload['from_cfi'];
    final targetCfi = payload['target_cfi'];
    final request = _state.currentRequest;
    final commit = _positionCommit;

    if (requestId is! String ||
        requestedByUserId is! String ||
        completedByUserId is! String ||
        direction == null ||
        fromCfi is! String ||
        targetCfi is! String ||
        request == null ||
        commit == null ||
        request.requestId != requestId ||
        request.requestedByUserId != requestedByUserId ||
        requestedByUserId != completedByUserId ||
        request.direction != direction ||
        request.fromCfi != fromCfi ||
        commit.targetCfi != targetCfi) {
      return;
    }

    _applyPageTurnComplete(request, commit);
  }

  void _applyPageTurnComplete(
    PageTurnRequest request,
    PagePositionCommit commit,
  ) {
    if (_disposed || !_handledCompleteIds.add(request.requestId)) return;
    _cancelTimeout();
    _currentCfi = commit.targetCfi;
    _clearActivePositionState(request.requestId);
    _updateState(const PageSyncState.idle());
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
    _failRequest(current, describeCancelReason(reason));
  }

  void _onPresenceChange(Map<String, dynamic> event) {
    if (_disposed) return;
    final eventType = event['event'];
    if (eventType == 'sync') {
      _presenceSynchronized = true;
    }
    if (eventType != 'leave' && eventType != 'sync') return;

    final current = _state.currentRequest;
    final onlineUsers = _transport.getOnlineUsers();
    _recordEnteredReaders(onlineUsers);
    if (eventType == 'leave') {
      final departedReaders = _enteredReaderParticipantIds.where((userId) {
        return !_isReadingParticipantOnline(userId, onlineUsers);
      }).toSet();
      _enteredReaderParticipantIds.removeAll(departedReaders);
      _expectedParticipantUserIds.removeAll(departedReaders);
    }
    // A participant who never opened the reader was previously unremovable: it
    // stayed in the quorum even after disconnecting from the room entirely,
    // which blocked every later page turn for everyone else. Presence absence
    // is observed identically by all clients, so pruning on it keeps the
    // rosters convergent. Re-entry is restored by _recordEnteredReaders.
    _expectedParticipantUserIds.removeAll(
      _expectedParticipantUserIds.where((userId) {
        return userId != _currentUserId && !_isInRoom(userId, onlineUsers);
      }).toSet(),
    );
    if (current == null) return;
    final isExecuting = _handledExecuteIds.contains(current.requestId);
    final remainingRequired = current.requiredUserIds.where((userId) {
      return isExecuting
          ? _isReadingParticipantOnline(userId, onlineUsers)
          : _isReadyReaderOnline(userId, onlineUsers);
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
    _updateState(_state.copyWith(currentRequest: updated, clearError: true));
    final commit = _positionCommit;
    if (commit != null && commit.requestId == updated.requestId) {
      _checkDisplayCompletion(updated, commit);
    } else {
      _checkConsensus(updated);
    }
  }

  void _onReadingSessionLeave(Map<String, dynamic> payload) {
    if (_disposed || payload['session_id'] != _readingSessionId) return;
    final userId = payload['user_id'];
    if (userId is! String || !_sessionParticipantUserIds.contains(userId)) {
      return;
    }
    _explicitlyLeftParticipantUserIds.add(userId);
    _expectedParticipantUserIds.remove(userId);
    _enteredReaderParticipantIds.remove(userId);

    final current = _state.currentRequest;
    if (current == null || !current.requiredUserIds.contains(userId)) return;
    if (current.requestedByUserId == userId) {
      unawaited(_cancelRequest(current, 'requester_left_reading_session'));
      return;
    }

    final remainingRequired = Set<String>.from(current.requiredUserIds)
      ..remove(userId);
    if (remainingRequired.isEmpty ||
        !remainingRequired.contains(current.requestedByUserId)) {
      unawaited(_cancelRequest(current, 'reading_session_ended'));
      return;
    }
    final updated = current.copyWith(requiredUserIds: remainingRequired);
    _updateState(_state.copyWith(currentRequest: updated, clearError: true));
    final commit = _positionCommit;
    if (commit != null && commit.requestId == updated.requestId) {
      _checkDisplayCompletion(updated, commit);
    } else {
      _checkConsensus(updated);
    }
  }

  void _checkConsensus(PageTurnRequest request) {
    if (!request.isConsensusReached ||
        request.requestedByUserId != _currentUserId ||
        _executeInFlightIds.contains(request.requestId) ||
        _handledExecuteIds.contains(request.requestId)) {
      return;
    }
    if (!_isRequestQuorumStillReady(request)) {
      unawaited(_cancelRequest(request, 'required_reader_not_ready'));
      return;
    }
    unawaited(_executePageTurn(request));
  }

  Future<void> _executePageTurn(PageTurnRequest request) async {
    if (!_executeInFlightIds.add(request.requestId)) return;
    _updateState(
      PageSyncState(status: SyncStatus.turning, currentRequest: request),
    );

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
      _failRequest(request, 'Could not execute the page turn: $error');
    } finally {
      _executeInFlightIds.remove(request.requestId);
    }
  }

  Future<void> _cancelRequest(PageTurnRequest request, String reason) async {
    try {
      await _broadcastCancel(request, reason);
    } catch (error) {
      _failRequest(request, 'Could not cancel the page turn: $error');
      return;
    }
    if (_state.currentRequest?.requestId == request.requestId) {
      _failRequest(request, describeCancelReason(reason));
    }
  }

  Future<void> _broadcastCancel(PageTurnRequest request, String reason) {
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

    _recordEnteredReaders(users);
    final usersById = {
      for (final user in users)
        if (user['user_id'] is String) user['user_id'] as String: user,
    };
    final readyUserIds = <String>{};
    final unreadyUserIds = <String>[];
    for (final userId in _expectedParticipantUserIds) {
      final user = usersById[userId];
      final isReady = user != null &&
          user['is_reading'] == true &&
          user['reader_ready'] == true &&
          (userId != _currentUserId || _readerReady);
      if (isReady) {
        readyUserIds.add(userId);
      } else {
        // The participant roster is frozen by the start-reading event. A
        // slower client stays pending even while it still reports lobby state.
        unreadyUserIds.add(userId);
      }
    }

    if (unreadyUserIds.isNotEmpty) {
      return _ReadyReaderQuorum.error(
        _unreadyReaderMessage(unreadyUserIds, usersById),
      );
    }
    if (!readyUserIds.contains(_currentUserId)) {
      return const _ReadyReaderQuorum.error(
        'This reader is not present and ready',
      );
    }
    return _ReadyReaderQuorum(readyUserIds);
  }

  /// Names the readers still holding up the quorum.
  ///
  /// "Waiting for every reader to become ready" gives the user nothing to act
  /// on when one participant is stuck in the lobby; naming them does.
  String _unreadyReaderMessage(
    List<String> unreadyUserIds,
    Map<String, Map<String, dynamic>> usersById,
  ) {
    if (unreadyUserIds.length == 1 &&
        unreadyUserIds.single == _currentUserId) {
      return 'Waiting for this reader to become ready';
    }
    final names = unreadyUserIds
        .where((userId) => userId != _currentUserId)
        .map((userId) {
          final nickname = usersById[userId]?['nickname'];
          return nickname is String && nickname.trim().isNotEmpty
              ? nickname.trim()
              : null;
        })
        .whereType<String>()
        .toList()
      ..sort();
    if (names.isEmpty || names.length != unreadyUserIds.length) {
      return 'Waiting for every reader to become ready';
    }
    return 'Waiting for ${names.join(', ')} to become ready';
  }

  void _recordEnteredReaders(List<Map<String, dynamic>> users) {
    for (final user in users) {
      final userId = user['user_id'];
      if (userId is String &&
          _sessionParticipantUserIds.contains(userId) &&
          !_explicitlyLeftParticipantUserIds.contains(userId) &&
          user['is_reading'] == true) {
        _enteredReaderParticipantIds.add(userId);
        // A temporary Presence disconnect removes an entered reader from the
        // active roster so the in-flight turn can finish. Re-add that reader
        // after reconnection; otherwise clients permanently disagree about the
        // quorum for every later page turn in the same reading session.
        _expectedParticipantUserIds.add(userId);
      }
    }
  }

  bool _isReadyReaderOnline(String userId, List<Map<String, dynamic>> users) {
    return users.any((user) {
      if (user['user_id'] != userId || user['is_reading'] != true) return false;
      if (userId == _currentUserId) return _readerReady;
      return user['reader_ready'] == true;
    });
  }

  bool _isReadingParticipantOnline(
    String userId,
    List<Map<String, dynamic>> users,
  ) {
    return users.any(
      (user) => user['user_id'] == userId && user['is_reading'] == true,
    );
  }

  /// Present on the room channel at all, whether reading or still in the lobby.
  bool _isInRoom(String userId, List<Map<String, dynamic>> users) {
    return users.any((user) => user['user_id'] == userId);
  }

  bool _isRequestQuorumStillReady(PageTurnRequest request) {
    final quorum = _buildReadyReaderQuorum();
    return quorum.error == null &&
        request.requiredUserIds.length == quorum.userIds.length &&
        request.requiredUserIds.every(quorum.userIds.contains) &&
        _readerReady &&
        _currentCfi == request.fromCfi;
  }

  void _startTimeout(String requestId) {
    _cancelTimeout();
    _timeoutTimer = Timer(_requestTimeout, () {
      if (_disposed || _state.currentRequest?.requestId != requestId) return;
      final request = _state.currentRequest!;
      unawaited(_sendTimeoutCancel(request));
      _failRequest(request, 'Page turn timed out');
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

  void _failRequest(PageTurnRequest request, String message) {
    if (_state.currentRequest?.requestId != request.requestId) return;
    _cancelTimeout();
    final needsRecovery =
        _handledExecuteIds.contains(request.requestId) ||
        _positionCommit?.requestId == request.requestId;
    if (needsRecovery) {
      // Once the requester has published a commit, that CFI is authoritative
      // (and may already be persisted). Ack/complete failures must converge to
      // it instead of rolling some readers back to the pre-turn page.
      final positionWasCommitted =
          _positionCommit?.requestId == request.requestId;
      final recoveryCfi = positionWasCommitted
          ? _positionCommit!.targetCfi
          : request.fromCfi;
      _currentCfi = recoveryCfi;
      onPositionRecovery?.call(recoveryCfi, positionWasCommitted);
    }
    _clearActivePositionState(request.requestId);
    _updateState(PageSyncState.error(message));
  }

  void _clearActivePositionState(String requestId) {
    if (_positionCommit?.requestId == requestId) _positionCommit = null;
    _positionAckUserIds.clear();
    _ackInFlightIds.remove(requestId);
    _sentAckIds.remove(requestId);
    _completeInFlightIds.remove(requestId);
  }

  void _updateState(PageSyncState newState) {
    if (_disposed) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
    _scheduleErrorAutoClear(newState);
  }

  /// Returns a failed state to idle so the status bar stops reporting a
  /// finished failure as if the reader were still blocked on it.
  void _scheduleErrorAutoClear(PageSyncState newState) {
    _errorAutoClearTimer?.cancel();
    _errorAutoClearTimer = null;
    if (newState.errorMessage == null || newState.currentRequest != null) {
      return;
    }
    _errorAutoClearTimer = Timer(_errorAutoClearDelay, () {
      _errorAutoClearTimer = null;
      if (_disposed ||
          !identical(_state, newState) ||
          _state.currentRequest != null) {
        return;
      }
      _updateState(const PageSyncState.idle());
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelTimeout();
    _errorAutoClearTimer?.cancel();
    _errorAutoClearTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    onPageTurn = null;
    onPositionCommit = null;
    onPositionRecovery = null;
    await _stateController.close();
  }
}

/// Turns a wire cancel reason into something a reader can act on.
///
/// The raw codes are protocol identifiers; they were previously rendered
/// verbatim in the status bar as e.g. "Page turn cancelled:
/// declined_by_Bob".
String describeCancelReason(String reason) {
  const messages = <String, String>{
    'timeout': 'Page turn timed out waiting for the other readers',
    'stale_page_position': 'Page turn cancelled: your page moved',
    'reader_became_unready': 'Page turn cancelled: this reader is still loading',
    'required_reader_not_ready':
        'Page turn cancelled: a reader is not ready yet',
    'invalid_or_stale_request': 'Page turn cancelled: readers were out of sync',
    'requester_left': 'Page turn cancelled: the requester left',
    'requester_left_reading_session':
        'Page turn cancelled: the requester left the book',
    'reading_session_ended': 'Page turn cancelled: the reading session ended',
    'persistence_coordination_failed':
        'Page turn cancelled: could not save the new page',
  };

  final known = messages[reason];
  if (known != null) return known;

  const declinePrefix = 'declined_by_';
  if (reason.startsWith(declinePrefix)) {
    final nickname = reason.substring(declinePrefix.length).trim();
    return nickname.isEmpty
        ? 'A reader asked to wait on this page'
        : '$nickname asked to wait on this page';
  }
  return 'Page turn cancelled';
}

class _ReadyReaderQuorum {
  final Set<String> userIds;
  final String? error;

  const _ReadyReaderQuorum(this.userIds) : error = null;

  const _ReadyReaderQuorum.error(this.error) : userIds = const {};
}

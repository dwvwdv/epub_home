import 'dart:async';

import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mergePresenceUsers deduplicates sessions by user_id', () {
    final users = mergePresenceUsers([
      {
        'user_id': 'alice',
        'nickname': 'Old Alice',
        'has_book': false,
        'is_reading': true,
        'reader_ready': false,
        'online_at': '2026-08-12T01:00:00Z',
      },
      {
        'user_id': 'alice',
        'nickname': 'Alice',
        'has_book': true,
        'book_hash': 'book-a',
        'is_reading': false,
        'reader_ready': true,
        'online_at': '2026-08-12T02:00:00Z',
      },
      {
        'user_id': 'bob',
        'nickname': 'Bob',
        'has_book': false,
        'online_at': '2026-08-12T03:00:00Z',
      },
      {'nickname': 'invalid'},
    ]);

    expect(users, hasLength(2));
    final alice = users.singleWhere((user) => user['user_id'] == 'alice');
    expect(alice['nickname'], 'Alice');
    expect(alice['session_count'], 2);
    expect(alice['has_book'], isTrue);
    expect(alice['ready_book_hashes'], ['book-a']);
    expect(alice['is_reading'], isTrue);
    expect(alice['reader_ready'], isTrue);
  });

  test('reader readiness is explicit and clears on reader exit', () async {
    final realtime = _RecordingRealtimeService();
    final notifier = PresenceNotifier(realtime);

    await notifier.joinRoom(
      roomCode: 'ABC234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 1,
    );
    await notifier.updateIsReading(true);
    expect(realtime.lastPresence['is_reading'], isTrue);
    expect(realtime.lastPresence['reader_ready'], isFalse);

    await notifier.updateReaderReady(true);
    expect(realtime.lastPresence['reader_ready'], isTrue);

    await notifier.updateIsReading(false);
    expect(realtime.lastPresence['is_reading'], isFalse);
    expect(realtime.lastPresence['reader_ready'], isFalse);

    notifier.dispose();
    await realtime.close();
  });

  test('leaving announcement is sent before clearing room identity', () async {
    final realtime = _RecordingRealtimeService();
    final notifier = PresenceNotifier(realtime);

    await notifier.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 1,
    );
    await notifier.announceLeaving();

    expect(realtime.lastBroadcastEvent, 'membership_changed');
    expect(realtime.lastBroadcastPayload, {
      'action': 'leaving',
      'room_code': 'ABC234',
      'user_id': 'alice',
    });

    await notifier.leaveRoom();
    notifier.dispose();
    await realtime.close();
  });

  test('a join announcement waits for the channel to subscribe', () async {
    final realtime = _DeferredConnectionRealtimeService();
    final notifier = PresenceNotifier(realtime);

    // joinRoom returns once subscribe() has been *called*, not once the
    // channel is subscribed, so the transport is still connecting here.
    await notifier.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 1,
    );

    await notifier.announceJoining();
    expect(realtime.broadcasts, isEmpty);

    realtime.emitConnected();
    await Future<void>.delayed(Duration.zero);

    // Sending on the still-connecting channel dropped the join silently, and
    // the other clients kept a roster without this member.
    expect(realtime.broadcasts.single.event, 'membership_changed');
    expect(realtime.broadcasts.single.payload, {
      'action': 'joined',
      'room_code': 'ABC234',
      'user_id': 'alice',
    });

    notifier.dispose();
    await realtime.disposeFake();
    await realtime.close();
  });

  test('a queued join announcement survives a slow subscription', () async {
    final realtime = _DeferredConnectionRealtimeService();
    final notifier = PresenceNotifier(realtime);

    await notifier.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 1,
    );
    await notifier.announceJoining();

    // However long the subscription takes, the announcement must not be lost:
    // on a same-user rejoin the lingering metas merge to one row, so the
    // Presence-ID listener gives the peers no other signal.
    realtime.emitReconnecting();
    await Future<void>.delayed(Duration.zero);
    expect(realtime.broadcasts, isEmpty);

    realtime.emitConnected();
    await Future<void>.delayed(Duration.zero);

    expect(realtime.broadcasts.single.payload['action'], 'joined');

    notifier.dispose();
    await realtime.disposeFake();
    await realtime.close();
  });

  test('a failed join announcement retries while still connected', () async {
    final realtime = _DeferredConnectionRealtimeService()..failNextBroadcast = true;
    final notifier = PresenceNotifier(
      realtime,
      joinAnnouncementRetryDelay: const Duration(milliseconds: 10),
    );

    await notifier.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 1,
    );
    await notifier.announceJoining();

    realtime.emitConnected();
    await Future<void>.delayed(Duration.zero);
    expect(realtime.broadcasts, isEmpty);

    // The channel never left 'connected', so no further connection event will
    // arrive to carry the retry.
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(realtime.broadcasts.single.payload['action'], 'joined');

    notifier.dispose();
    await realtime.disposeFake();
    await realtime.close();
  });

  test('a queued join announcement is dropped when the room is left', () async {
    final realtime = _DeferredConnectionRealtimeService();
    final notifier = PresenceNotifier(realtime);

    await notifier.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 1,
    );
    await notifier.announceJoining();
    await notifier.leaveRoom();

    realtime.emitConnected();
    await Future<void>.delayed(Duration.zero);

    expect(realtime.broadcasts, isEmpty);

    notifier.dispose();
    await realtime.disposeFake();
    await realtime.close();
  });
}

class _RecordedBroadcast {
  final String event;
  final Map<String, dynamic> payload;

  const _RecordedBroadcast(this.event, this.payload);
}

/// Mirrors the real service: joinRoom completes while still connecting, and
/// the connected event arrives later from the subscribe callback.
class _DeferredConnectionRealtimeService extends RealtimeService {
  final _connection = StreamController<RealtimeConnectionEvent>.broadcast();
  final broadcasts = <_RecordedBroadcast>[];
  bool failNextBroadcast = false;
  bool _connected = false;

  _DeferredConnectionRealtimeService()
    : super(channelFactory: (_, __) => throw StateError('not used'));

  @override
  bool get isConnected => _connected;

  @override
  Stream<RealtimeConnectionEvent> get connectionStream => _connection.stream;

  @override
  Future<void> joinRoom({
    required String roomCode,
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    String? roomTopicId,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
  }) async {}

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    if (failNextBroadcast) {
      failNextBroadcast = false;
      throw StateError('transient send failure');
    }
    broadcasts.add(
      _RecordedBroadcast(event, Map<String, dynamic>.from(payload)),
    );
  }

  void emitConnected() {
    _connected = true;
    _connection.add(
      const RealtimeConnectionEvent(RealtimeConnectionStatus.connected),
    );
  }

  void emitReconnecting() {
    _connection.add(
      const RealtimeConnectionEvent(RealtimeConnectionStatus.reconnecting),
    );
  }

  Future<void> disposeFake() => _connection.close();
}

class _RecordingRealtimeService extends RealtimeService {
  Map<String, dynamic> lastPresence = {};
  String? lastBroadcastEvent;
  Map<String, dynamic>? lastBroadcastPayload;

  _RecordingRealtimeService()
    : super(channelFactory: (_, __) => throw StateError('not used'));

  @override
  bool get isConnected => true;

  @override
  Future<void> joinRoom({
    required String roomCode,
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    String? roomTopicId,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
  }) async {
    _record(
      userId: userId,
      hasBook: hasBook,
      bookHash: bookHash,
      isReading: isReading,
      readerReady: readerReady,
    );
  }

  @override
  Future<void> updatePresence({
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
  }) async {
    _record(
      userId: userId,
      hasBook: hasBook,
      bookHash: bookHash,
      isReading: isReading,
      readerReady: readerReady,
    );
  }

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    lastBroadcastEvent = event;
    lastBroadcastPayload = Map<String, dynamic>.from(payload);
  }

  void _record({
    required String userId,
    required bool hasBook,
    required String? bookHash,
    required bool isReading,
    required bool readerReady,
  }) {
    lastPresence = {
      'user_id': userId,
      'has_book': hasBook,
      'book_hash': bookHash,
      'is_reading': isReading,
      'reader_ready': readerReady,
    };
  }
}

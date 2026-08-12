import 'package:cotime_book/services/realtime_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<_FakeRoomChannel> channels;
  late RealtimeService service;

  setUp(() {
    channels = [];
    service = RealtimeService(
      channelFactory: (name, presenceKey) {
        final channel = _FakeRoomChannel(name, presenceKey);
        channels.add(channel);
        return channel;
      },
    );
  });

  tearDown(() async {
    await service.close();
  });

  test('room event registry includes lifecycle and commit events', () {
    expect(
      RealtimeService.roomEvents,
      containsAll([
        'page_position_commit',
        'page_position_ack',
        'page_turn_complete',
        'reading_session_leave',
        'membership_changed',
        'room_closed',
      ]),
    );
  });

  test('same-room join is idempotent and updates presence', () async {
    await service.joinRoom(
      roomCode: 'abc234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 2,
      hasBook: false,
    );
    expect(channels, hasLength(1));
    expect(service.isConnected, isFalse);

    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);
    expect(service.isConnected, isTrue);
    expect(channels.single.tracked.single['has_book'], isFalse);

    await service.joinRoom(
      roomCode: 'ABC234',
      userId: 'alice',
      nickname: 'Alice',
      avatarColorIndex: 2,
      hasBook: true,
      readerReady: true,
    );

    expect(channels, hasLength(1));
    expect(channels.single.tracked.last['has_book'], isTrue);
    expect(channels.single.tracked.last['reader_ready'], isTrue);
  });

  test('concurrent same-room joins share one channel', () async {
    await Future.wait([
      _join(service, 'AAA234'),
      _join(service, 'AAA234'),
      _join(service, 'aaa234'),
    ]);

    expect(channels, hasLength(1));
  });

  test(
    'same room with a different authenticated user replaces channel',
    () async {
      await _join(service, 'AAA234');
      channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
      await Future<void>.delayed(Duration.zero);

      await service.joinRoom(
        roomCode: 'AAA234',
        userId: 'bob',
        nickname: 'Bob',
        avatarColorIndex: 1,
        hasBook: false,
      );

      expect(channels, hasLength(2));
      expect(channels.first.untrackCount, 1);
      expect(channels.first.removeCount, 1);
      expect(channels.last.presenceKey, 'bob');
    },
  );

  test('cross-room join completely removes old channel', () async {
    await _join(service, 'AAA234');
    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);

    await _join(service, 'BBB234');

    expect(channels, hasLength(2));
    expect(channels.first.untrackCount, 1);
    expect(channels.first.removeCount, 1);
    expect(service.roomCode, 'BBB234');
  });

  test('channel removal still runs when presence untrack fails', () async {
    await _join(service, 'AAA234');
    channels.single.emitStatus(RealtimeSubscribeStatus.subscribed);
    await Future<void>.delayed(Duration.zero);
    channels.single.untrackError = StateError('socket closed');

    await expectLater(service.leaveRoom(), throwsStateError);

    expect(channels.single.untrackCount, 1);
    expect(channels.single.removeCount, 1);
    expect(service.roomCode, isNull);
  });

  test('callbacks from an obsolete generation are ignored', () async {
    final received = <Map<String, dynamic>>[];
    final subscription = service
        .broadcastStream('book_shared')
        .listen(received.add);

    await _join(service, 'AAA234');
    final oldChannel = channels.single;
    await _join(service, 'BBB234');
    final currentChannel = channels.last;

    oldChannel.emitBroadcast('book_shared', {'room': 'old'});
    currentChannel.emitBroadcast('book_shared', {'room': 'new'});
    await Future<void>.delayed(Duration.zero);

    expect(received, [
      {'room': 'new'},
    ]);
    await subscription.cancel();
  });

  test('presence sync exposes current generation payloads', () async {
    final events = <Map<String, dynamic>>[];
    final subscription = service.presenceStream.listen(events.add);
    await _join(service, 'AAA234');
    channels.single.presences = [
      {'user_id': 'alice'},
      {'user_id': 'bob'},
    ];

    channels.single.emitPresenceSync();
    await Future<void>.delayed(Duration.zero);

    expect(events.single['event'], 'sync');
    expect(events.single['state'], hasLength(2));
    await subscription.cancel();
  });
}

Future<void> _join(RealtimeService service, String code) {
  return service.joinRoom(
    roomCode: code,
    userId: 'alice',
    nickname: 'Alice',
    avatarColorIndex: 0,
    hasBook: false,
  );
}

class _FakeRoomChannel implements RoomRealtimeChannel {
  final String name;
  final String presenceKey;
  VoidCallback? _sync;
  ValueChanged<dynamic>? _join;
  ValueChanged<dynamic>? _leave;
  void Function(RealtimeSubscribeStatus, Object?)? _status;
  final callbacks = <String, ValueChanged<Map<String, dynamic>>>{};
  final tracked = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> presences = [];
  int untrackCount = 0;
  int removeCount = 0;
  Object? untrackError;

  _FakeRoomChannel(this.name, this.presenceKey);

  @override
  void onPresenceSync(VoidCallback callback) => _sync = callback;

  @override
  void onPresenceJoin(ValueChanged<dynamic> callback) => _join = callback;

  @override
  void onPresenceLeave(ValueChanged<dynamic> callback) => _leave = callback;

  @override
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback) {
    callbacks[event] = callback;
  }

  @override
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  ) {
    _status = callback;
  }

  @override
  Future<void> track(Map<String, dynamic> payload) async {
    tracked.add(Map<String, dynamic>.from(payload));
  }

  @override
  Future<void> untrack() async {
    untrackCount++;
    final error = untrackError;
    if (error != null) throw error;
  }

  @override
  Future<void> sendBroadcast(String event, Map<String, dynamic> payload) async {
    emitBroadcast(event, payload);
  }

  @override
  List<Map<String, dynamic>> presencePayloads() => presences;

  @override
  Future<void> remove() async => removeCount++;

  void emitStatus(RealtimeSubscribeStatus status, [Object? error]) {
    _status?.call(status, error);
  }

  void emitPresenceJoin(dynamic payload) => _join?.call(payload);

  void emitPresenceLeave(dynamic payload) => _leave?.call(payload);

  void emitPresenceSync() => _sync?.call();

  void emitBroadcast(String event, Map<String, dynamic> payload) {
    callbacks[event]?.call(payload);
  }
}

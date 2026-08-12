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

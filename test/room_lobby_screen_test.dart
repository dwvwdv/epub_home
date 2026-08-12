import 'package:cotime_book/screens/room_lobby_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bookHash = 'book-hash';

  Map<String, dynamic> readyUser(String userId) {
    return {
      'user_id': userId,
      'has_book': true,
      'ready_book_hashes': [bookHash],
    };
  }

  test('ready-book roster requires exact DB and Presence membership', () {
    expect(
      hasExactReadyBookRoster(
        memberUserIds: const ['host'],
        onlineUsers: [readyUser('host'), readyUser('joining-guest')],
        currentBookHash: bookHash,
      ),
      isFalse,
    );
    expect(
      hasExactReadyBookRoster(
        memberUserIds: const ['host', 'offline-guest'],
        onlineUsers: [readyUser('host')],
        currentBookHash: bookHash,
      ),
      isFalse,
    );
    expect(
      hasExactReadyBookRoster(
        memberUserIds: const ['host', 'guest'],
        onlineUsers: [readyUser('host'), readyUser('guest')],
        currentBookHash: bookHash,
      ),
      isTrue,
    );
  });

  test('ready-book roster requires the current shared book hash', () {
    final guest = readyUser('guest')
      ..['ready_book_hashes'] = ['previous-book'];

    expect(
      hasExactReadyBookRoster(
        memberUserIds: const ['host', 'guest'],
        onlineUsers: [readyUser('host'), guest],
        currentBookHash: bookHash,
      ),
      isFalse,
    );
  });
}

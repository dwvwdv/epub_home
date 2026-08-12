import 'dart:async';

import 'package:cotime_book/models/room.dart';
import 'package:cotime_book/models/room_member.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/services/room_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RoomNotifier', () {
    test('revoked heartbeat clears local room session and runs teardown', () async {
      final service = FakeRoomService()..heartbeatError =
          const RoomSessionRevokedException('membership expired');
      var teardownCalls = 0;
      final notifier = RoomNotifier(
        service,
        onSessionRevoked: () async {
          teardownCalls++;
        },
      );
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      await expectLater(
        notifier.heartbeat(),
        throwsA(isA<RoomSessionRevokedException>()),
      );

      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.members, isEmpty);
      expect(notifier.state.error, 'membership expired');
      expect(teardownCalls, 1);
    });

    test('transient heartbeat failure preserves the active session', () async {
      final service = FakeRoomService()
        ..heartbeatError = StateError('temporary network failure');
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      await expectLater(notifier.heartbeat(), throwsStateError);

      expect(notifier.state.currentRoom?.id, room?.id);
      expect(notifier.state.error, contains('temporary network failure'));
    });

    test('revoked CFI write also tears down the cached session', () async {
      final service = FakeRoomService()
        ..cfiError = const RoomSessionRevokedException('membership expired');
      var teardownCalls = 0;
      final notifier = RoomNotifier(
        service,
        onSessionRevoked: () async {
          teardownCalls++;
        },
      );
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      await expectLater(
        notifier.updateCfiForRoom(
          roomId: room!.id,
          cfi: 'epubcfi(/6/8)',
        ),
        throwsA(isA<RoomSessionRevokedException>()),
      );

      expect(notifier.state.currentRoom, isNull);
      expect(notifier.state.error, 'membership expired');
      expect(teardownCalls, 1);
    });

    test('room-specific CFI writes cannot update a later room session', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final roomA = await notifier.createRoom('Alice');
      final delayedWrite = Completer<Room>();
      service.cfiWrite = delayedWrite;
      final write = notifier.updateCfiForRoom(
        roomId: roomA!.id,
        cfi: 'epubcfi(/6/8)',
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.nextRoom = testRoom(id: 'room-b', code: 'BBBBBB');
      await notifier.createRoom('Alice');
      delayedWrite.complete(
        roomA.copyWith(currentCfi: 'epubcfi(/6/8)'),
      );
      await expectLater(
        write,
        throwsA(isA<RoomSessionChangedException>()),
      );

      expect(notifier.state.currentRoom?.id, 'room-b');
      expect(notifier.state.currentRoom?.currentCfi, isNull);
      await expectLater(
        notifier.updateCfiForRoom(
          roomId: roomA.id,
          cfi: 'epubcfi(/6/10)',
        ),
        throwsA(isA<RoomSessionChangedException>()),
      );
    });

    test('a delayed CFI write cannot cross a same-room rejoin', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      final delayedWrite = Completer<Room>();
      service.cfiWrite = delayedWrite;
      final write = notifier.updateCfiForRoom(
        roomId: room!.id,
        cfi: 'epubcfi(/6/14)',
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.nextRoom = testRoom(id: room.id, code: room.code);
      await notifier.joinRoom(room.code, 'Alice');
      delayedWrite.complete(room.copyWith(currentCfi: 'epubcfi(/6/14)'));

      await expectLater(
        write,
        throwsA(isA<RoomSessionChangedException>()),
      );
      expect(notifier.state.currentRoom?.id, room.id);
      expect(notifier.state.currentRoom?.currentCfi, isNull);
      expect(service.lastCfiExpectedRevision, 0);
    });

    test('a delayed member refresh cannot overwrite a later room', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final delayedMembers = Completer<List<RoomMember>>();
      service.memberRead = delayedMembers;
      final refresh = notifier.refreshMembers();
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.memberRead = null;
      service.nextRoom = testRoom(id: 'room-b', code: 'BBBBBB');
      await notifier.createRoom('Alice');
      delayedMembers.complete([testMember(roomId: 'room-a')]);
      await refresh;

      expect(notifier.state.currentRoom?.id, 'room-b');
      expect(notifier.state.members, isEmpty);
    });

    test('a delayed member snapshot cannot overwrite newer presence', () async {
      final service = FakeRoomService()
        ..members = [testMember(roomId: 'room-a')];
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final delayedMembers = Completer<List<RoomMember>>();
      service.memberRead = delayedMembers;
      final refresh = notifier.refreshMembers();
      await Future<void>.delayed(Duration.zero);

      notifier.updateMembersFromPresence([
        {
          'user_id': 'user-a',
          'has_book': true,
        },
      ]);
      delayedMembers.complete([testMember(roomId: 'room-a')]);
      await refresh;

      expect(notifier.state.members.single.hasBook, isTrue);
      expect(notifier.state.members.single.isOnline, isTrue);
    });

    test('a delayed room refresh cannot resurrect a previous session', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final roomA = await notifier.createRoom('Alice');
      final delayedRoom = Completer<Room?>();
      service.roomRead = delayedRoom;
      final refresh = notifier.refreshRoom();
      await Future<void>.delayed(Duration.zero);

      await notifier.leaveRoom();
      service.roomRead = null;
      service.nextRoom = testRoom(id: 'room-b', code: 'BBBBBB');
      await notifier.createRoom('Alice');
      delayedRoom.complete(roomA!.copyWith(currentCfi: 'epubcfi(/6/18)'));
      await refresh;

      expect(notifier.state.currentRoom?.id, 'room-b');
      expect(notifier.state.currentRoom?.currentCfi, isNull);
    });

    test('a delayed room snapshot cannot overwrite a newer local event', () async {
      final service = FakeRoomService();
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      final delayedRoom = Completer<Room?>();
      service.roomRead = delayedRoom;
      final refresh = notifier.refreshRoom();
      await Future<void>.delayed(Duration.zero);

      notifier.onBookSharedReceived(
        bookTitle: 'New book',
        bookHash: List.filled(64, 'a').join(),
      );
      delayedRoom.complete(room);
      await refresh;

      expect(notifier.state.currentRoom?.currentBookTitle, 'New book');
      expect(
        notifier.state.currentRoom?.currentBookHash,
        List.filled(64, 'a').join(),
      );
    });

    test('CFI write refreshes and retries one room revision conflict', () async {
      final service = FakeRoomService()
        ..cfiConflicts = 1
        ..conflictRoom = testRoom(revision: 4);
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      final room = await notifier.createRoom('Alice');
      await notifier.updateCfiForRoom(
        roomId: room!.id,
        cfi: 'epubcfi(/6/22)',
      );

      expect(service.cfiExpectedRevisions, [0, 4]);
      expect(notifier.state.currentRoom?.revision, 5);
      expect(notifier.state.currentRoom?.currentCfi, 'epubcfi(/6/22)');
    });

    test('book share refreshes and retries one room revision conflict', () async {
      final service = FakeRoomService()
        ..bookConflicts = 1
        ..conflictRoom = testRoom(revision: 7);
      final notifier = RoomNotifier(service);
      addTearDown(notifier.dispose);

      await notifier.createRoom('Alice');
      final bookHash = List.filled(64, 'b').join();
      await notifier.updateBookShared(
        bookTitle: 'Concurrent Book',
        bookHash: bookHash,
      );

      expect(service.bookExpectedRevisions, [0, 7]);
      expect(notifier.state.currentRoom?.revision, 8);
      expect(notifier.state.currentRoom?.currentBookHash, bookHash);
    });
  });
}

Room testRoom({
  String id = 'room-a',
  String code = 'AAAAAA',
  int revision = 0,
}) {
  final now = DateTime.utc(2026, 8, 12);
  return Room(
    id: id,
    code: code,
    hostUserId: 'user-a',
    revision: revision,
    createdAt: now,
    updatedAt: now,
  );
}

RoomMember testMember({required String roomId}) {
  return RoomMember(
    id: 'member-a',
    roomId: roomId,
    userId: 'user-a',
    nickname: 'Alice',
    joinedAt: DateTime.utc(2026, 8, 12),
  );
}

class FakeRoomService extends RoomService {
  Room nextRoom = testRoom();
  Object? heartbeatError;
  Object? cfiError;
  Completer<Room>? cfiWrite;
  Completer<List<RoomMember>>? memberRead;
  Completer<Room?>? roomRead;
  int? lastCfiExpectedRevision;
  List<RoomMember> members = const [];
  int cfiConflicts = 0;
  int bookConflicts = 0;
  Room conflictRoom = testRoom();
  final List<int> cfiExpectedRevisions = [];
  final List<int> bookExpectedRevisions = [];

  @override
  Future<Room> createRoom({required String nickname}) async => nextRoom;

  @override
  Future<Room> joinRoom({
    required String code,
    required String nickname,
  }) async => nextRoom;

  @override
  Future<List<RoomMember>> getRoomMembers(String roomId) async {
    return memberRead?.future ?? members;
  }

  @override
  Future<Room?> getRoom(String roomId) async {
    return roomRead?.future ?? nextRoom;
  }

  @override
  Future<Room> heartbeatRoom(String roomId) async {
    final error = heartbeatError;
    if (error != null) throw error;
    return nextRoom;
  }

  @override
  Future<Room> updateRoomCfi({
    required String roomId,
    required String cfi,
    required int expectedRevision,
  }) async {
    lastCfiExpectedRevision = expectedRevision;
    cfiExpectedRevisions.add(expectedRevision);
    if (cfiConflicts > 0) {
      cfiConflicts--;
      throw RoomRevisionConflictException(conflictRoom);
    }
    final error = cfiError;
    if (error != null) throw error;
    final pending = cfiWrite;
    if (pending != null) return pending.future;
    return nextRoom.copyWith(
      currentCfi: cfi,
      revision: expectedRevision + 1,
    );
  }

  @override
  Future<Room> updateRoomBook({
    required String roomId,
    required String bookTitle,
    required String bookHash,
    required int expectedRevision,
  }) async {
    bookExpectedRevisions.add(expectedRevision);
    if (bookConflicts > 0) {
      bookConflicts--;
      throw RoomRevisionConflictException(conflictRoom);
    }
    return nextRoom.copyWith(
      currentBookTitle: bookTitle,
      currentBookHash: bookHash,
      revision: expectedRevision + 1,
    );
  }

  @override
  Future<Map<String, dynamic>> leaveRoom({required String roomId}) async {
    return {'left': true};
  }
}

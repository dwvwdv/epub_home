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
    });
  });
}

Room testRoom({String id = 'room-a', String code = 'AAAAAA'}) {
  final now = DateTime.utc(2026, 8, 12);
  return Room(
    id: id,
    code: code,
    hostUserId: 'user-a',
    createdAt: now,
    updatedAt: now,
  );
}

class FakeRoomService extends RoomService {
  Room nextRoom = testRoom();
  Object? heartbeatError;
  Object? cfiError;
  Completer<Room>? cfiWrite;

  @override
  Future<Room> createRoom({required String nickname}) async => nextRoom;

  @override
  Future<List<RoomMember>> getRoomMembers(String roomId) async => const [];

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
  }) async {
    final error = cfiError;
    if (error != null) throw error;
    final pending = cfiWrite;
    if (pending != null) return pending.future;
    return nextRoom.copyWith(currentCfi: cfi);
  }

  @override
  Future<Map<String, dynamic>> leaveRoom({required String roomId}) async {
    return {'left': true};
  }
}

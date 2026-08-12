import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/room.dart';
import '../models/room_member.dart';
import 'supabase_service.dart';

class RoomSessionRevokedException implements Exception {
  final String message;

  const RoomSessionRevokedException(this.message);

  @override
  String toString() => message;
}

class RoomSessionChangedException implements Exception {
  final String roomId;

  const RoomSessionChangedException(this.roomId);

  @override
  String toString() => 'Room session changed before CFI could be saved';
}

class RoomService {
  SupabaseQuerySchema get _database => SupabaseService.database;

  Future<Room> createRoom({required String nickname}) async {
    if (SupabaseService.currentUserId == null) {
      throw Exception('Not authenticated');
    }

    final roomData = await _database.rpc('create_room', params: {
      'p_nickname': nickname,
      'p_avatar_color_index': Random.secure().nextInt(8),
    }).single();

    return Room.fromJson(roomData);
  }

  Future<Room> joinRoom({
    required String code,
    required String nickname,
  }) async {
    if (SupabaseService.currentUserId == null) {
      throw Exception('Not authenticated');
    }

    final roomData = await _database.rpc('join_room', params: {
      'p_code': code.toUpperCase(),
      'p_nickname': nickname,
      'p_avatar_color_index': Random.secure().nextInt(8),
    }).single();

    return Room.fromJson(roomData);
  }

  Future<List<RoomMember>> getRoomMembers(String roomId) async {
    final data = await _database
        .from('room_members')
        .select()
        .eq('room_id', roomId)
        .order('joined_at');

    return data.map((json) => RoomMember.fromJson(json)).toList();
  }

  Future<void> updateMemberBookStatus({
    required String roomId,
    required String userId,
    required bool hasBook,
  }) async {
    final updatedMember = await _database
        .from('room_members')
        .update({'has_book': hasBook})
        .eq('room_id', roomId)
        .eq('user_id', userId)
        .select('id')
        .maybeSingle();

    if (updatedMember == null) {
      throw StateError('Room membership is inactive or no longer exists');
    }
  }

  Future<Room> updateRoomBook({
    required String roomId,
    required String bookTitle,
    required String bookHash,
  }) async {
    final roomData = await _database
        .from('rooms')
        .update({
          'current_book_title': bookTitle,
          'current_book_hash': bookHash,
        })
        .eq('id', roomId)
        .select()
        .single();

    return Room.fromJson(roomData);
  }

  Future<Room> updateRoomCfi({
    required String roomId,
    required String cfi,
  }) async {
    try {
      final roomData = await _database
          .from('rooms')
          .update({'current_cfi': cfi})
          .eq('id', roomId)
          .select()
          .maybeSingle();
      if (roomData == null) {
        throw const RoomSessionRevokedException(
          'This room membership is inactive or has expired.',
        );
      }
      return Room.fromJson(roomData);
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException(
          'This room membership is inactive or has expired.',
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> leaveRoom({required String roomId}) async {
    final result = await _database.rpc(
      'leave_room',
      params: {'p_room_id': roomId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Room> heartbeatRoom(String roomId) async {
    try {
      final roomData = await _database.rpc(
        'heartbeat_room',
        params: {'p_room_id': roomId},
      ).single();

      return Room.fromJson(roomData);
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'P0002') {
        throw const RoomSessionRevokedException(
          'This room membership is inactive or has expired.',
        );
      }
      rethrow;
    }
  }

  Future<Room?> getRoom(String roomId) async {
    final data = await _database
        .from('rooms')
        .select()
        .eq('id', roomId)
        .maybeSingle();

    return data != null ? Room.fromJson(data) : null;
  }
}

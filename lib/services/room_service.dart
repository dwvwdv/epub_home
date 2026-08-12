import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/room.dart';
import '../models/room_member.dart';
import 'supabase_service.dart';

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
    final roomData = await _database
        .from('rooms')
        .update({'current_cfi': cfi})
        .eq('id', roomId)
        .select()
        .single();

    return Room.fromJson(roomData);
  }

  Future<Map<String, dynamic>> leaveRoom({required String roomId}) async {
    final result = await _database.rpc(
      'leave_room',
      params: {'p_room_id': roomId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Room> heartbeatRoom(String roomId) async {
    final roomData = await _database.rpc(
      'heartbeat_room',
      params: {'p_room_id': roomId},
    ).single();

    return Room.fromJson(roomData);
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

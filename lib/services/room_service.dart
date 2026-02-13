import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_constants.dart';
import '../models/room.dart';
import '../models/room_member.dart';
import 'supabase_service.dart';

class RoomService {
  final SupabaseClient _client = SupabaseService.client;

  String _generateRoomCode() {
    final random = Random.secure();
    return List.generate(
      AppConstants.roomCodeLength,
      (_) => AppConstants.roomCodeChars[
          random.nextInt(AppConstants.roomCodeChars.length)],
    ).join();
  }

  Future<Room> createRoom({required String nickname}) async {
    final userId = SupabaseService.currentUserId;
    if (userId == null) throw Exception('Not authenticated');

    // Generate unique room code with collision check
    String code;
    bool exists = true;
    do {
      code = _generateRoomCode();
      final result = await _client
          .from('rooms')
          .select('id')
          .eq('code', code)
          .eq('is_active', true)
          .maybeSingle();
      exists = result != null;
    } while (exists);

    final now = DateTime.now().toIso8601String();

    // Create room
    final roomData = await _client
        .from('rooms')
        .insert({
          'code': code,
          'host_user_id': userId,
          'is_active': true,
          'created_at': now,
          'updated_at': now,
        })
        .select()
        .single();

    final room = Room.fromJson(roomData);

    // Add creator as member
    await _client.from('room_members').insert({
      'room_id': room.id,
      'user_id': userId,
      'nickname': nickname,
      'avatar_color_index': Random().nextInt(8),
      'has_book': false,
      'joined_at': now,
    });

    return room;
  }

  Future<Room> joinRoom({
    required String code,
    required String nickname,
  }) async {
    final userId = SupabaseService.currentUserId;
    if (userId == null) throw Exception('Not authenticated');

    // Find room by code
    final roomData = await _client
        .from('rooms')
        .select()
        .eq('code', code.toUpperCase())
        .eq('is_active', true)
        .maybeSingle();

    if (roomData == null) {
      throw Exception('Room not found or no longer active');
    }

    final room = Room.fromJson(roomData);

    // Check if already a member
    final existing = await _client
        .from('room_members')
        .select('id')
        .eq('room_id', room.id)
        .eq('user_id', userId)
        .maybeSingle();

    if (existing == null) {
      await _client.from('room_members').insert({
        'room_id': room.id,
        'user_id': userId,
        'nickname': nickname,
        'avatar_color_index': Random().nextInt(8),
        'has_book': false,
        'joined_at': DateTime.now().toIso8601String(),
      });
    }

    return room;
  }

  Future<List<RoomMember>> getRoomMembers(String roomId) async {
    final data = await _client
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
    await _client
        .from('room_members')
        .update({'has_book': hasBook})
        .eq('room_id', roomId)
        .eq('user_id', userId);
  }

  Future<void> updateRoomBook({
    required String roomId,
    required String bookTitle,
    required String bookHash,
  }) async {
    await _client.from('rooms').update({
      'current_book_title': bookTitle,
      'current_book_hash': bookHash,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', roomId);
  }

  Future<void> updateRoomCfi({
    required String roomId,
    required String cfi,
  }) async {
    await _client.from('rooms').update({
      'current_cfi': cfi,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', roomId);
  }

  Future<void> leaveRoom({
    required String roomId,
    required String userId,
  }) async {
    await _client
        .from('room_members')
        .delete()
        .eq('room_id', roomId)
        .eq('user_id', userId);

    // Check if room is now empty
    final remaining = await _client
        .from('room_members')
        .select('id')
        .eq('room_id', roomId);

    if ((remaining as List).isEmpty) {
      await _client.from('rooms').update({
        'is_active': false,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', roomId);
    }
  }

  Future<Room?> getRoom(String roomId) async {
    final data = await _client
        .from('rooms')
        .select()
        .eq('id', roomId)
        .maybeSingle();

    return data != null ? Room.fromJson(data) : null;
  }
}

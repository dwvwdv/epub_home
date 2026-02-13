import 'package:flutter/material.dart';
import '../models/room_member.dart';
import 'user_avatar.dart';

class MemberList extends StatelessWidget {
  final List<RoomMember> members;
  final String? currentUserId;

  const MemberList({
    super.key,
    required this.members,
    this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return const Center(
        child: Text(
          'No members yet',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: members.length,
      itemBuilder: (context, index) {
        final member = members[index];
        final isMe = member.userId == currentUserId;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              UserAvatar(
                nickname: member.nickname,
                colorIndex: member.avatarColorIndex,
                isOnline: member.isOnline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          member.nickname,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        if (isMe)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Text(
                              '(You)',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                    Text(
                      member.isOnline ? 'Online' : 'Offline',
                      style: TextStyle(
                        color: member.isOnline ? Colors.green : Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (member.hasBook)
                const Icon(
                  Icons.book,
                  color: Colors.green,
                  size: 20,
                )
              else
                const Icon(
                  Icons.book_outlined,
                  color: Colors.white38,
                  size: 20,
                ),
            ],
          ),
        );
      },
    );
  }
}

-- CoTime Book - Initial Database Schema
-- Run this in your Supabase SQL Editor to set up the database.

-- ============================================================
-- Tables
-- ============================================================

-- Rooms table
CREATE TABLE IF NOT EXISTS rooms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(6) NOT NULL,
  host_user_id UUID NOT NULL,
  current_book_title TEXT,
  current_book_hash VARCHAR(64),
  current_cfi TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_rooms_code_active
  ON rooms(code) WHERE is_active = true;

-- Room members table
CREATE TABLE IF NOT EXISTS room_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id UUID REFERENCES rooms(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  nickname VARCHAR(30) NOT NULL,
  avatar_color_index INT DEFAULT 0,
  has_book BOOLEAN DEFAULT false,
  joined_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(room_id, user_id)
);

-- Profiles table (minimal, for anonymous auth)
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nickname VARCHAR(30),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Row Level Security
-- ============================================================

-- Enable RLS
ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Rooms policies
CREATE POLICY "Anyone can read active rooms"
  ON rooms FOR SELECT
  USING (is_active = true);

CREATE POLICY "Authenticated users can create rooms"
  ON rooms FOR INSERT
  WITH CHECK (auth.uid() = host_user_id);

CREATE POLICY "Host can update room"
  ON rooms FOR UPDATE
  USING (auth.uid() = host_user_id);

-- Allow any room member to update CFI and book info
CREATE POLICY "Members can update room reading state"
  ON rooms FOR UPDATE
  USING (
    id IN (
      SELECT room_id FROM room_members WHERE user_id = auth.uid()
    )
  );

-- Room members policies
-- Allow reading members of any active room (since active rooms are public)
CREATE POLICY "Anyone can read members of active rooms"
  ON room_members FOR SELECT
  USING (
    room_id IN (
      SELECT id FROM rooms WHERE is_active = true
    )
  );

CREATE POLICY "Users can join rooms"
  ON room_members FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own membership"
  ON room_members FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can leave rooms"
  ON room_members FOR DELETE
  USING (auth.uid() = user_id);

-- Profiles policies
CREATE POLICY "Users can read own profile"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can create own profile"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING (auth.uid() = id);

-- ============================================================
-- Realtime
-- ============================================================

-- Enable realtime for rooms table (for room state changes)
ALTER PUBLICATION supabase_realtime ADD TABLE rooms;

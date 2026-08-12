# CoTime Book

A collaborative reading app built with Flutter and Supabase.

## 🚀 Quick Start

### Prerequisites

- Flutter SDK (3.0 or higher)
- A Supabase account and project

### 1. Set Up Supabase Database

The database uses a dedicated `cotime_book` schema. To create or upgrade it:

1. Go to your [Supabase Dashboard](https://app.supabase.com)
2. Select your project
3. Click on **SQL Editor** in the left sidebar
4. Click **New Query**
5. Run every file in `supabase/migrations/` in filename order
6. Confirm the `cotime_book` schema is listed under **Data API → Exposed Schemas**

This Supabase project is shared by multiple apps. CoTime Book channels are already
private and protected by Realtime RLS. Do not change the project-wide **Allow public
access to channels** setting unless every app sharing the project has been audited.

This will create:
- `rooms` - Stores reading rooms
- `room_members` - Tracks who is in each room
- `profiles` - User profile information
- Least-privilege grants and Row Level Security (RLS) policies
- Private Realtime Broadcast and Presence authorization

### 2. Get Your Supabase Credentials

1. In your Supabase Dashboard, go to **Settings** → **API**
2. Copy your:
   - **Project URL** (looks like `https://xxxxx.supabase.co`)
   - **Anon/Public Key** (starts with `eyJxxx...`)

### 3. Run the App

Run the app with your Supabase credentials:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key-here
```

**Tip:** Create a `.env` file or a launch script to avoid typing this every time:

```bash
#!/bin/bash
# run.sh
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key-here
```

Then run: `chmod +x run.sh && ./run.sh`

## 📱 Features

- Create and join reading rooms with 6-character codes
- Collaborative reading with synchronized page positions
- Real-time updates when room members change pages
- Anonymous authentication (no sign-up required)
- EPUB book support

## 🛠️ Development

### Project Structure

```
lib/
├── config/          # App configuration (theme, Supabase)
├── models/          # Data models (Room, RoomMember, etc.)
├── providers/       # State management (Riverpod)
├── screens/         # UI screens
├── services/        # Backend services (Supabase)
└── widgets/         # Reusable UI components

supabase/
└── migrations/      # Database schema migrations
```

### Troubleshooting

**Error: "The schema must be one of the following: public"**
- Run the latest migration and reload the Data API configuration
- Confirm `cotime_book` is in **Data API → Exposed Schemas**

**Error: "relation 'cotime_book.rooms' does not exist"**
- You need to run the SQL migration file in Supabase (see step 1 above)

**Error: "Supabase not configured"**
- Make sure you're running the app with `--dart-define` flags (see step 3 above)

**Button not responding / No error messages**
- Check your internet connection
- Verify your Supabase credentials are correct
- Check the Supabase Dashboard for any API issues

## 📄 License

MIT License

-- CarCom Supabase Schema (Complete)
-- Run this in Supabase SQL Editor after creating a new project
-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================
-- PROFILES
-- =============================================
DROP TABLE IF EXISTS profiles CASCADE;
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  avatar_url TEXT,
  phone TEXT UNIQUE,
  preferred_language TEXT DEFAULT 'ar' CHECK (preferred_language IN ('ar', 'en')),
  car_model TEXT,
  car_year INTEGER,
  car_color TEXT,
  modifications TEXT[] DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Profiles are viewable by everyone"
  ON profiles FOR SELECT USING (true);
CREATE POLICY "Users can update their own profile"
  ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users can insert their own profile"
  ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

-- Trigger: auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.profiles (id, name, phone, preferred_language)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data->>'name', 'مستخدم'),
    new.phone,
    COALESCE(new.raw_user_meta_data->>'preferred_language', 'ar')
  );
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =============================================
-- COMMUNITIES
-- =============================================
DROP TABLE IF EXISTS communities CASCADE;
CREATE TABLE communities (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  description TEXT,
  car_model TEXT NOT NULL,
  cover_image_url TEXT,
  visibility TEXT DEFAULT 'public' CHECK (visibility IN ('public', 'private')),
  invite_code TEXT UNIQUE DEFAULT UPPER(SUBSTRING(MD5(RANDOM()::TEXT), 1, 8)),
  rules TEXT,
  member_count INTEGER DEFAULT 1,
  created_by UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE communities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public communities viewable by everyone"
  ON communities FOR SELECT
  USING (visibility = 'public' OR created_by = auth.uid());
CREATE POLICY "Authenticated users can create communities"
  ON communities FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
CREATE POLICY "Creator can update community"
  ON communities FOR UPDATE USING (created_by = auth.uid());
CREATE POLICY "Creator can delete community"
  ON communities FOR DELETE USING (created_by = auth.uid());

-- =============================================
-- COMMUNITY MEMBERS
-- =============================================
DROP TABLE IF EXISTS community_members CASCADE;
CREATE TABLE community_members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  community_id UUID NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT DEFAULT 'member' CHECK (role IN ('organizer', 'member', 'admin')),
  status TEXT DEFAULT 'approved' CHECK (status IN ('pending', 'approved', 'blocked')),
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(community_id, user_id)
);

ALTER TABLE community_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members viewable by community members"
  ON community_members FOR SELECT
  USING (
    community_id IN (SELECT id FROM communities WHERE visibility = 'public')
    OR community_id IN (SELECT community_id FROM community_members WHERE user_id = auth.uid())
    OR community_id IN (SELECT id FROM communities WHERE created_by = auth.uid())
  );
CREATE POLICY "Users can join communities"
  ON community_members FOR INSERT
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can leave communities"
  ON community_members FOR DELETE
  USING (auth.uid() = user_id OR community_id IN (SELECT id FROM communities WHERE created_by = auth.uid()));
CREATE POLICY "Creator can manage members"
  ON community_members FOR UPDATE
  USING (community_id IN (SELECT id FROM communities WHERE created_by = auth.uid()));

-- Trigger: increment member_count
CREATE OR REPLACE FUNCTION increment_community_member_count()
RETURNS trigger AS $$
BEGIN
  UPDATE communities SET member_count = member_count + 1 WHERE id = NEW.community_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_community_member_added ON community_members;
CREATE TRIGGER on_community_member_added
  AFTER INSERT ON community_members
  FOR EACH ROW EXECUTE FUNCTION increment_community_member_count();

-- Trigger: decrement member_count
CREATE OR REPLACE FUNCTION decrement_community_member_count()
RETURNS trigger AS $$
BEGIN
  UPDATE communities SET member_count = GREATEST(0, member_count - 1) WHERE id = OLD.community_id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_community_member_removed ON community_members;
CREATE TRIGGER on_community_member_removed
  AFTER DELETE ON community_members
  FOR EACH ROW EXECUTE FUNCTION decrement_community_member_count();

-- =============================================
-- TRIPS
-- =============================================
DROP TABLE IF EXISTS trips CASCADE;
CREATE TABLE trips (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  community_id UUID REFERENCES communities(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  description TEXT,
  category TEXT CHECK (category IN ('scenic', 'camping', 'offroad', 'city_meetup')),
  destination JSONB NOT NULL DEFAULT '{"name": "", "lat": 0, "lng": 0}',
  meeting_point JSONB NOT NULL DEFAULT '{"name": "", "lat": 0, "lng": 0}',
  route_stops JSONB[] DEFAULT '{}',
  date DATE NOT NULL,
  departure_time TIME NOT NULL,
  estimated_return TIME,
  participant_limit INTEGER NOT NULL DEFAULT 10,
  current_participants INTEGER DEFAULT 1,
  estimated_cost NUMERIC DEFAULT 0,
  cost_currency TEXT DEFAULT 'SAR',
  status TEXT DEFAULT 'published' CHECK (status IN ('draft', 'published', 'cancelled', 'completed')),
  itinerary TEXT,
  preparation_checklist TEXT[] DEFAULT '{}',
  created_by UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE trips ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Published trips viewable by everyone"
  ON trips FOR SELECT
  USING (status = 'published' OR created_by = auth.uid());
CREATE POLICY "Authenticated users can create trips"
  ON trips FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
CREATE POLICY "Creator can update trip"
  ON trips FOR UPDATE USING (created_by = auth.uid());
CREATE POLICY "Creator can delete trip"
  ON trips FOR DELETE USING (created_by = auth.uid());

-- =============================================
-- TRIP PARTICIPANTS
-- =============================================
DROP TABLE IF EXISTS trip_participants CASCADE;
CREATE TABLE trip_participants (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT DEFAULT 'going' CHECK (status IN ('going', 'declined', 'waitlisted')),
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(trip_id, user_id)
);

ALTER TABLE trip_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Participants viewable by trip members"
  ON trip_participants FOR SELECT
  USING (
    trip_id IN (SELECT id FROM trips WHERE status = 'published')
    OR user_id = auth.uid()
    OR trip_id IN (SELECT id FROM trips WHERE created_by = auth.uid())
  );
CREATE POLICY "Users can join trips"
  ON trip_participants FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can leave trips"
  ON trip_participants FOR DELETE USING (auth.uid() = user_id);

-- Trigger: increment participant count
CREATE OR REPLACE FUNCTION increment_trip_participant_count()
RETURNS trigger AS $$
BEGIN
  UPDATE trips SET current_participants = current_participants + 1 WHERE id = NEW.trip_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_trip_participant_added ON trip_participants;
CREATE TRIGGER on_trip_participant_added
  AFTER INSERT ON trip_participants
  FOR EACH ROW EXECUTE FUNCTION increment_trip_participant_count();

-- Trigger: decrement participant count
CREATE OR REPLACE FUNCTION decrement_trip_participant_count()
RETURNS trigger AS $$
BEGIN
  UPDATE trips SET current_participants = GREATEST(0, current_participants - 1) WHERE id = OLD.trip_id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_trip_participant_removed ON trip_participants;
CREATE TRIGGER on_trip_participant_removed
  AFTER DELETE ON trip_participants
  FOR EACH ROW EXECUTE FUNCTION decrement_trip_participant_count();

-- =============================================
-- EXPENSES
-- =============================================
DROP TABLE IF EXISTS expenses CASCADE;
CREATE TABLE expenses (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  amount NUMERIC NOT NULL,
  currency TEXT DEFAULT 'SAR',
  paid_by UUID NOT NULL REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Trip participants can view expenses"
  ON expenses FOR SELECT
  USING (
    trip_id IN (SELECT trip_id FROM trip_participants WHERE user_id = auth.uid())
    OR trip_id IN (SELECT id FROM trips WHERE created_by = auth.uid())
  );
CREATE POLICY "Trip participants can add expenses"
  ON expenses FOR INSERT
  WITH CHECK (
    auth.uid() = paid_by
    AND (
      trip_id IN (SELECT trip_id FROM trip_participants WHERE user_id = auth.uid())
      OR trip_id IN (SELECT id FROM trips WHERE created_by = auth.uid())
    )
  );

-- =============================================
-- EXPENSE SHARES
-- =============================================
DROP TABLE IF EXISTS expense_shares CASCADE;
CREATE TABLE expense_shares (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  expense_id UUID NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount_owed NUMERIC NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'failed', 'refunded')),
  paid_at TIMESTAMPTZ,
  UNIQUE(expense_id, user_id)
);

ALTER TABLE expense_shares ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own shares"
  ON expense_shares FOR SELECT USING (user_id = auth.uid());

-- =============================================
-- CHAT MESSAGES
-- =============================================
DROP TABLE IF EXISTS chat_messages CASCADE;
CREATE TABLE chat_messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  channel_id TEXT NOT NULL,
  channel_type TEXT NOT NULL CHECK (channel_type IN ('community', 'trip')),
  sender_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  media_url TEXT,
  reply_to UUID REFERENCES chat_messages(id),
  is_announcement BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Channel members can view messages"
  ON chat_messages FOR SELECT
  USING (
    (channel_type = 'community' AND channel_id::uuid IN (
      SELECT id FROM communities WHERE visibility = 'public'
      UNION
      SELECT community_id FROM community_members WHERE user_id = auth.uid()
    ))
    OR
    (channel_type = 'trip' AND channel_id::uuid IN (
      SELECT trip_id FROM trip_participants WHERE user_id = auth.uid()
      UNION
      SELECT id FROM trips WHERE created_by = auth.uid()
    ))
  );
CREATE POLICY "Channel members can send messages"
  ON chat_messages FOR INSERT
  WITH CHECK (
    auth.uid() = sender_id
    AND (
      (channel_type = 'community' AND channel_id::uuid IN (
        SELECT community_id FROM community_members WHERE user_id = auth.uid()
      ))
      OR
      (channel_type = 'trip' AND channel_id::uuid IN (
        SELECT trip_id FROM trip_participants WHERE user_id = auth.uid()
        UNION
        SELECT id FROM trips WHERE created_by = auth.uid()
      ))
    )
  );

-- =============================================
-- MESSAGE REACTIONS
-- =============================================
DROP TABLE IF EXISTS message_reactions CASCADE;
CREATE TABLE message_reactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  message_id UUID NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(message_id, user_id, emoji)
);

ALTER TABLE message_reactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can react to visible messages"
  ON message_reactions FOR ALL
  USING (message_id IN (SELECT id FROM chat_messages) AND auth.uid() = user_id);

-- =============================================
-- REPORTS
-- =============================================
DROP TABLE IF EXISTS reports CASCADE;
CREATE TABLE reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID NOT NULL REFERENCES profiles(id),
  reported_id UUID NOT NULL REFERENCES profiles(id),
  reason TEXT NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'actioned', 'dismissed')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can create reports"
  ON reports FOR INSERT WITH CHECK (auth.uid() = reporter_id);
CREATE POLICY "Users can view their own reports"
  ON reports FOR SELECT USING (auth.uid() = reporter_id);

-- =============================================
-- NOTIFICATIONS
-- =============================================
DROP TABLE IF EXISTS notifications CASCADE;
CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT,
  type TEXT NOT NULL CHECK (type IN ('trip_reminder', 'chat_message', 'community_update', 'payment_reminder', 'departure_alert')),
  data JSONB DEFAULT '{}',
  read BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own notifications"
  ON notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can update their own notifications"
  ON notifications FOR UPDATE USING (auth.uid() = user_id);

-- =============================================
-- USER LOCATIONS (for live location sharing)
-- =============================================
DROP TABLE IF EXISTS user_locations CASCADE;
CREATE TABLE user_locations (
  user_id UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  trip_id UUID,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE user_locations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Trip participants can view locations"
  ON user_locations FOR SELECT
  USING (
    trip_id IN (SELECT trip_id FROM trip_participants WHERE user_id = auth.uid())
    OR trip_id IN (SELECT id FROM trips WHERE created_by = auth.uid())
  );
CREATE POLICY "Users can update their own location"
  ON user_locations FOR ALL USING (auth.uid() = user_id);

-- =============================================
-- REALTIME PUBLICATION
-- =============================================
-- Enable realtime for chat and presence
DROP PUBLICATION IF EXISTS supabase_realtime;
CREATE PUBLICATION supabase_realtime;

ALTER PUBLICATION supabase_realtime ADD TABLE chat_messages;
ALTER PUBLICATION supabase_realtime ADD TABLE message_reactions;
ALTER PUBLICATION supabase_realtime ADD TABLE user_locations;
ALTER PUBLICATION supabase_realtime ADD TABLE trip_participants;
ALTER PUBLICATION supabase_realtime ADD TABLE community_members;

-- =============================================
-- SEED DATA (Saudi demo content - run after creating auth users)
-- =============================================
-- To seed demo data, create auth users first via Supabase Dashboard, then:
-- INSERT INTO profiles (id, name, car_model) VALUES ('user-uuid', 'عبدالله', 'Toyota Land Cruiser');
-- INSERT INTO communities (name, description, car_model, created_by) VALUES ('LC Club KSA', '...', 'Toyota Land Cruiser', 'user-uuid');

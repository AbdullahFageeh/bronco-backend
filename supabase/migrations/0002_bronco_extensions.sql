-- Bronco backend extensions: admin, subscriptions, pricing, sponsors, reviews,
-- SOS, support tickets, audit logs, voice calls.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin', 'superadmin'));

CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.admin_users WHERE id = auth.uid())
     OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin','superadmin'));
$$;

-- Plans / pricing / subscriptions
CREATE TABLE IF NOT EXISTS plans (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  description TEXT,
  price_sar NUMERIC NOT NULL DEFAULT 0,
  interval TEXT NOT NULL DEFAULT 'monthly' CHECK (interval IN ('monthly','yearly','one_time')),
  features JSONB DEFAULT '[]'::jsonb,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  plan_id UUID NOT NULL REFERENCES plans(id),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','cancelled','expired','past_due')),
  provider TEXT DEFAULT 'moyasar',
  provider_reference TEXT,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pricing (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  entity_type TEXT NOT NULL,
  entity_id UUID,
  price_sar NUMERIC NOT NULL,
  currency TEXT DEFAULT 'SAR',
  effective_from TIMESTAMPTZ DEFAULT NOW(),
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sponsors
CREATE TABLE IF NOT EXISTS sponsors (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  logo_url TEXT,
  website_url TEXT,
  placement TEXT DEFAULT 'home' CHECK (placement IN ('home','trip','community')),
  active BOOLEAN DEFAULT true,
  starts_at TIMESTAMPTZ DEFAULT NOW(),
  ends_at TIMESTAMPTZ,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Trip reviews
CREATE TABLE IF NOT EXISTS trip_reviews (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (trip_id, user_id)
);

-- SOS alerts
CREATE TABLE IF NOT EXISTS sos_alerts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  lat DOUBLE PRECISION NOT NULL,
  lng DOUBLE PRECISION NOT NULL,
  note TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','acknowledged','resolved')),
  acknowledged_by UUID REFERENCES profiles(id),
  resolved_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  resolved_at TIMESTAMPTZ
);

-- Support tickets
CREATE TABLE IF NOT EXISTS support_tickets (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','resolved','closed')),
  priority TEXT DEFAULT 'normal' CHECK (priority IN ('low','normal','high','urgent')),
  assigned_admin UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Admin users / permissions
CREATE TABLE IF NOT EXISTS admin_users (
  id UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'admin' CHECK (role IN ('superadmin','admin','support')),
  permissions TEXT[] NOT NULL DEFAULT '{}',
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Audit logs
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  actor_id UUID REFERENCES profiles(id),
  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Voice communication sessions (metadata only; media via WebRTC/Supabase Realtime)
CREATE TABLE IF NOT EXISTS voice_calls (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  channel_type TEXT NOT NULL CHECK (channel_type IN ('community','trip','direct')),
  channel_id TEXT NOT NULL,
  initiator_id UUID NOT NULL REFERENCES profiles(id),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('ringing','active','ended','missed')),
  started_at TIMESTAMPTZ DEFAULT NOW(),
  ended_at TIMESTAMPTZ
);

-- Enable RLS
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE pricing ENABLE ROW LEVEL SECURITY;
ALTER TABLE sponsors ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE sos_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE voice_calls ENABLE ROW LEVEL SECURITY;

-- Plans: public read, admin write
CREATE POLICY "Plans readable by everyone" ON plans FOR SELECT USING (true);
CREATE POLICY "Plans writable by admins" ON plans FOR ALL
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Subscriptions: own + admin
CREATE POLICY "Users view own subscriptions" ON subscriptions FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "Users create own subscriptions" ON subscriptions FOR INSERT
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Admins manage subscriptions" ON subscriptions FOR ALL
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Pricing: public read, admin write
CREATE POLICY "Pricing readable by everyone" ON pricing FOR SELECT USING (true);
CREATE POLICY "Pricing writable by admins" ON pricing FOR ALL
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Sponsors: public read active, admin write
CREATE POLICY "Active sponsors readable" ON sponsors FOR SELECT
  USING (active = true OR public.is_admin());
CREATE POLICY "Sponsors writable by admins" ON sponsors FOR ALL
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Trip reviews: trip participants can read/write
CREATE POLICY "Reviews readable by everyone" ON trip_reviews FOR SELECT USING (true);
CREATE POLICY "Users create own reviews" ON trip_reviews FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users update own reviews" ON trip_reviews FOR UPDATE USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "Admins delete reviews" ON trip_reviews FOR DELETE USING (public.is_admin());

-- SOS alerts: authenticated create; trip community? allow creators and admins view
CREATE POLICY "SOS readable by authenticated" ON sos_alerts FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "SOS create own" ON sos_alerts FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "SOS update by owner or admin" ON sos_alerts FOR UPDATE
  USING (auth.uid() = user_id OR public.is_admin());

-- Support tickets: own + admin
CREATE POLICY "Tickets view own or admin" ON support_tickets FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());
CREATE POLICY "Tickets create own" ON support_tickets FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Tickets update by owner or admin" ON support_tickets FOR UPDATE
  USING (auth.uid() = user_id OR public.is_admin());

-- Admin users: admin only
CREATE POLICY "Admin users view by admins" ON admin_users FOR SELECT USING (public.is_admin() OR auth.uid() = id);
CREATE POLICY "Admin users manage by superadmins" ON admin_users FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'superadmin'))
  WITH CHECK (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'superadmin'));

-- Audit logs: admin read, authenticated insert own actor
CREATE POLICY "Audit read by admins" ON audit_logs FOR SELECT USING (public.is_admin());
CREATE POLICY "Audit insert by authenticated" ON audit_logs FOR INSERT WITH CHECK (auth.uid() = actor_id OR public.is_admin());

-- Voice calls: channel participants similar to chat (permissive for authenticated)
CREATE POLICY "Voice calls readable by authenticated" ON voice_calls FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "Voice calls create by authenticated" ON voice_calls FOR INSERT WITH CHECK (auth.uid() = initiator_id);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_sos_status ON sos_alerts(status);
CREATE INDEX IF NOT EXISTS idx_support_status ON support_tickets(status);
CREATE INDEX IF NOT EXISTS idx_reviews_trip ON trip_reviews(trip_id);

-- Realtime for SOS
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE sos_alerts;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

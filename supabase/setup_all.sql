-- League Auction: tables, constraints and indexes.
create schema if not exists private;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Logins live here, not in Supabase Auth. Passwords are stored only as bcrypt hashes.
create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  username text not null unique check (username ~ '^[a-z0-9._-]{3,40}$'),
  password_hash text not null,
  display_name text,
  role text not null default 'team' check (role in ('admin','team')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Only a hash of each session token is stored, so a database leak does not expose live sessions.
create table public.user_sessions (
  token_hash text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index user_sessions_user_idx on public.user_sessions (user_id);

create table public.login_attempts (
  username text primary key,
  failed_count integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

create table public.tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  short_name text,
  logo_path text,
  is_active boolean not null default true,
  player_seq integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index tournaments_one_active on public.tournaments (is_active) where is_active;

create table public.tournament_settings (
  tournament_id uuid primary key references public.tournaments(id) on delete cascade,
  primary_color text not null default '#FFC629' check (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  accent_color text not null default '#19C9B5' check (accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  background_color text not null default '#071A24' check (background_color ~ '^#[0-9A-Fa-f]{6}$'),
  sound_enabled boolean not null default true,
  animation_intensity text not null default 'high' check (animation_intensity in ('low','medium','high')),
  intro_duration_seconds integer not null default 8 check (intro_duration_seconds between 3 and 30),
  bid_countdown_seconds integer not null default 30 check (bid_countdown_seconds between 0 and 600),
  last_call_seconds integer not null default 10 check (last_call_seconds between 3 and 120),
  sold_display_seconds integer not null default 8 check (sold_display_seconds between 2 and 60),
  show_stats boolean not null default true,
  registration_open boolean not null default true,
  currency_label text not null default 'pts' check (length(currency_label) between 1 and 8),
  default_base_price integer not null default 100 check (default_base_price >= 0),
  default_increment integer not null default 10 check (default_increment > 0),
  default_budget integer not null default 10000 check (default_budget >= 0),
  default_squad_limit integer not null default 15 check (default_squad_limit > 0),
  positions text[] not null default array['Goalkeeper','Defender','Midfielder','Forward'],
  categories text[] not null default array['Icon','Senior','Junior','Rookie'],
  updated_at timestamptz not null default now()
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  code text not null,
  full_name text not null check (length(trim(full_name)) between 2 and 80),
  photo_path text,
  primary_position text not null,
  secondary_position text,
  age integer check (age between 5 and 100),
  category text not null,
  description text check (length(description) <= 600),
  status text not null default 'pending' check (status in ('pending','approved','rejected','withdrawn')),
  base_price integer check (base_price >= 0),
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tournament_id, code)
);
create index players_status_idx on public.players (tournament_id, status);

-- Phone numbers live apart from players so no public read or realtime payload can reach them.
create table public.player_contacts (
  player_id uuid primary key references public.players(id) on delete cascade,
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  phone text not null,
  phone_normalized text not null,
  unique (tournament_id, phone_normalized)
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 60),
  short_name text check (length(short_name) <= 6),
  logo_path text,
  color text not null default '#FFC629' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tournament_id, name)
);

create table public.team_memberships (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index team_memberships_team_idx on public.team_memberships (team_id);

create table public.team_budgets (
  team_id uuid primary key references public.teams(id) on delete cascade,
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  starting_budget integer not null check (starting_budget >= 0),
  spent integer not null default 0 check (spent >= 0),
  squad_limit integer not null check (squad_limit > 0),
  updated_at timestamptz not null default now(),
  check (spent <= starting_budget)
);

create table public.auction_sessions (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null unique references public.tournaments(id) on delete cascade,
  status text not null default 'not_started' check (status in ('not_started','live','paused','ended')),
  phase text not null default 'idle' check (phase in ('idle','introduction','bidding','last_call','closed','sold','unsold')),
  current_auction_player_id uuid,
  last_result_auction_player_id uuid,
  version bigint not null default 1,
  phase_started_at timestamptz not null default now(),
  countdown_ends_at timestamptz,
  countdown_seconds integer,
  paused_remaining_ms integer,
  started_at timestamptz,
  ended_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.auction_players (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.auction_sessions(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  order_no bigserial,
  status text not null default 'queued' check (status in ('queued','active','sold','unsold','skipped','withdrawn')),
  base_price integer not null check (base_price >= 0),
  bid_increment integer not null check (bid_increment > 0),
  round integer not null default 1,
  high_bid integer,
  high_team_id uuid references public.teams(id),
  high_bid_id uuid,
  bid_count integer not null default 0,
  updated_at timestamptz not null default now(),
  unique (session_id, player_id)
);
create index auction_players_queue_idx on public.auction_players (session_id, status, order_no);
-- At most one player can be on the block at a time.
create unique index auction_players_one_active on public.auction_players (session_id) where status = 'active';

alter table public.auction_sessions
  add constraint sessions_current_fk foreign key (current_auction_player_id) references public.auction_players(id) on delete set null,
  add constraint sessions_result_fk foreign key (last_result_auction_player_id) references public.auction_players(id) on delete set null;

create table public.bids (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.auction_sessions(id) on delete cascade,
  auction_player_id uuid not null references public.auction_players(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  amount integer not null check (amount >= 0),
  round integer not null,
  placed_by uuid references public.profiles(id) on delete set null,
  source text not null default 'team' check (source in ('team','admin')),
  voided_at timestamptz,
  created_at timestamptz not null default now()
);
-- The database itself refuses two live bids at the same price for the same lot.
create unique index bids_one_per_amount on public.bids (auction_player_id, round, amount) where voided_at is null;
create index bids_recent_idx on public.bids (session_id, created_at desc);
create index bids_team_idx on public.bids (team_id);

create table public.player_sales (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  session_id uuid not null references public.auction_sessions(id) on delete cascade,
  auction_player_id uuid not null references public.auction_players(id) on delete cascade,
  player_id uuid not null references public.players(id),
  team_id uuid not null references public.teams(id),
  price integer not null check (price >= 0),
  winning_bid_id uuid references public.bids(id),
  confirmed_by uuid references public.profiles(id) on delete set null,
  confirmed_at timestamptz not null default now(),
  undone_at timestamptz,
  undone_by uuid references public.profiles(id) on delete set null,
  undo_reason text
);
-- A player can have only one standing sale.
create unique index player_sales_one_active on public.player_sales (player_id) where undone_at is null;
create index player_sales_team_idx on public.player_sales (team_id, confirmed_at desc);

create table public.team_squads (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  sale_id uuid not null unique references public.player_sales(id) on delete cascade,
  price integer not null,
  acquired_at timestamptz not null default now(),
  unique (tournament_id, player_id)
);
create index team_squads_team_idx on public.team_squads (team_id);

create table public.auction_events (
  id bigserial primary key,
  session_id uuid not null references public.auction_sessions(id) on delete cascade,
  type text not null,
  auction_player_id uuid references public.auction_players(id) on delete set null,
  team_id uuid references public.teams(id) on delete set null,
  amount integer,
  message text,
  payload jsonb not null default '{}',
  actor_id uuid,
  created_at timestamptz not null default now()
);
create index auction_events_recent_idx on public.auction_events (session_id, id desc);

create table public.admin_audit_logs (
  id bigserial primary key,
  tournament_id uuid references public.tournaments(id) on delete set null,
  actor_id uuid,
  action text not null,
  entity_type text,
  entity_id text,
  before_data jsonb,
  after_data jsonb,
  reason text,
  created_at timestamptz not null default now()
);
create index admin_audit_recent_idx on public.admin_audit_logs (tournament_id, id desc);

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 120),
  body text check (length(body) <= 800),
  is_published boolean not null default true,
  show_on_projector boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index announcements_recent_idx on public.announcements (tournament_id, created_at desc);
-- League Auction: all writes go through these functions. Clients have no direct write access.

---------------------------------------------------------------- helpers
-- The signed-in user comes from the session token the app sends in the x-league-session header.
create function private.uid() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select s.user_id from public.user_sessions s join public.profiles p on p.id = s.user_id
  where s.token_hash = encode(sha256(convert_to((nullif(current_setting('request.headers', true), '')::json)->>'x-league-session', 'utf8')), 'hex')
    and s.expires_at > now() and p.is_active;
$$;

create function private.is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.profiles where id = private.uid() and role = 'admin');
$$;

create function private.current_team() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select team_id from public.team_memberships where user_id = private.uid();
$$;

create function private.require_admin() returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not private.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
end $$;

create function private.active_tournament() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from public.tournaments where is_active limit 1;
$$;

create function private.require_tournament() returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t uuid := private.active_tournament();
begin
  if t is null then raise exception 'No active tournament. Run the bootstrap step in the setup guide.'; end if;
  return t;
end $$;

create function private.audit(p_action text, p_type text, p_id text, p_before jsonb, p_after jsonb, p_reason text default null) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.admin_audit_logs (tournament_id, actor_id, action, entity_type, entity_id, before_data, after_data, reason)
  values (private.active_tournament(), private.uid(), p_action, p_type, p_id, p_before, p_after, p_reason);
$$;

create function private.log_event(p_session uuid, p_type text, p_ap uuid, p_team uuid, p_amount integer, p_message text, p_payload jsonb default '{}') returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.auction_events (session_id, type, auction_player_id, team_id, amount, message, payload, actor_id)
  values (p_session, p_type, p_ap, p_team, p_amount, p_message, coalesce(p_payload, '{}'), private.uid());
$$;

-- Every change that clients must see bumps the version; realtime carries that bump.
create function private.touch_session(p_tournament uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.auction_sessions set version = version + 1, updated_at = now() where tournament_id = p_tournament;
$$;

-- All auction transitions take this row lock, which serialises bids, sales and undos.
create function private.lock_session() returns public.auction_sessions
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions;
begin
  select * into s from public.auction_sessions where tournament_id = private.require_tournament() for update;
  if not found then raise exception 'Auction session not found'; end if;
  return s;
end $$;

create function private.set_phase(p_session uuid, p_phase text, p_countdown integer default null, p_current uuid default null, p_keep_current boolean default true) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.auction_sessions set
    phase = p_phase,
    phase_started_at = now(),
    countdown_seconds = nullif(p_countdown, 0),
    countdown_ends_at = case when coalesce(p_countdown, 0) > 0 then now() + make_interval(secs => p_countdown) end,
    paused_remaining_ms = null,
    current_auction_player_id = case when p_keep_current then current_auction_player_id else p_current end,
    version = version + 1,
    updated_at = now()
  where id = p_session;
$$;

create function private.require_live(s public.auction_sessions) returns void
language plpgsql stable as $$
begin
  if s.status = 'paused' then raise exception 'The auction is paused. Resume it first.'; end if;
  if s.status <> 'live' then raise exception 'The auction is not running.'; end if;
end $$;

create function private.reset_lot(p_ap uuid, p_status text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.bids set voided_at = now() where auction_player_id = p_ap and voided_at is null;
  update public.auction_players set
    status = p_status, round = round + 1, high_bid = null, high_team_id = null, high_bid_id = null, bid_count = 0, updated_at = now()
  where id = p_ap;
end $$;

create function private.recalc_budget(p_team uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.team_budgets set
    spent = coalesce((select sum(price) from public.player_sales where team_id = p_team and undone_at is null), 0),
    updated_at = now()
  where team_id = p_team;
$$;

create function private.normalize_phone(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if length(d) not between 7 and 15 then raise exception 'Enter a valid phone number with 7 to 15 digits.'; end if;
  return d;
end $$;

create function private.enroll_player(p_player public.players) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare st public.tournament_settings; sid uuid;
begin
  select * into st from public.tournament_settings where tournament_id = p_player.tournament_id;
  select id into sid from public.auction_sessions where tournament_id = p_player.tournament_id;
  insert into public.auction_players (session_id, player_id, base_price, bid_increment)
  values (sid, p_player.id, coalesce(p_player.base_price, st.default_base_price), st.default_increment)
  on conflict (session_id, player_id) do update set
    status = case when public.auction_players.status = 'withdrawn' then 'queued' else public.auction_players.status end,
    base_price = case when public.auction_players.bid_count = 0 and public.auction_players.status <> 'sold' then excluded.base_price else public.auction_players.base_price end,
    updated_at = now();
end $$;

create function private.create_player(p_t uuid, p jsonb, p_status text) returns public.players
language plpgsql security definer set search_path = public, pg_temp as $$
declare st public.tournament_settings; r public.players; seq integer; norm text;
  v_name text := trim(p->>'full_name'); v_pos text := trim(p->>'primary_position'); v_cat text := trim(p->>'category');
  v_sec text := nullif(trim(coalesce(p->>'secondary_position', '')), '');
begin
  norm := private.normalize_phone(p->>'phone');
  if length(coalesce(v_name, '')) < 2 then raise exception 'Enter the player''s full name.'; end if;
  select * into st from public.tournament_settings where tournament_id = p_t;
  if v_pos is null or not (v_pos = any(st.positions)) then raise exception 'Choose a primary position from the list.'; end if;
  if v_sec is not null and not (v_sec = any(st.positions)) then raise exception 'Choose a secondary position from the list.'; end if;
  if v_sec = v_pos then raise exception 'The secondary position must differ from the primary position.'; end if;
  if v_cat is null or not (v_cat = any(st.categories)) then raise exception 'Choose a player category from the list.'; end if;
  if exists (select 1 from public.player_contacts where tournament_id = p_t and phone_normalized = norm) then
    raise exception 'This phone number is already registered for the tournament.' using errcode = '23505';
  end if;
  update public.tournaments set player_seq = player_seq + 1 where id = p_t returning player_seq into seq;
  insert into public.players (tournament_id, code, full_name, photo_path, primary_position, secondary_position, age, category, description, status, base_price, approved_at, approved_by)
  values (p_t, 'P-' || lpad(seq::text, 4, '0'), v_name, nullif(p->>'photo_path', ''), v_pos, v_sec,
    nullif(p->>'age', '')::integer, v_cat, nullif(trim(coalesce(p->>'description', '')), ''), p_status,
    nullif(p->>'base_price', '')::integer,
    case when p_status = 'approved' then now() end, case when p_status = 'approved' then private.uid() end)
  returning * into r;
  insert into public.player_contacts (player_id, tournament_id, phone, phone_normalized) values (r.id, p_t, trim(p->>'phone'), norm);
  if p_status = 'approved' then perform private.enroll_player(r); end if;
  return r;
end $$;

---------------------------------------------------------------- setup (SQL editor only)
create function private.check_credentials(p_username text, p_password text) returns text
language plpgsql immutable as $$
declare v text := lower(trim(coalesce(p_username, '')));
begin
  if v !~ '^[a-z0-9._-]{3,40}$' then raise exception 'Usernames need 3 to 40 characters: letters, numbers, dots, dashes or underscores.'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'Passwords need at least 8 characters.'; end if;
  return v;
end $$;

create function private.hash_password(p text) returns text
language sql volatile as $$ select extensions.crypt(p, extensions.gen_salt('bf', 10)); $$;

-- Run from the SQL editor. Creates an admin, or resets that admin's password if the username exists.
create function private.bootstrap_admin(p_username text, p_password text, p_tournament_name text default 'League Auction') returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text := private.check_credentials(p_username, p_password); t uuid; u uuid;
begin
  insert into public.profiles (username, password_hash, role) values (v, private.hash_password(p_password), 'admin')
    on conflict (username) do update set password_hash = excluded.password_hash, role = 'admin', is_active = true, updated_at = now()
    returning id into u;
  delete from public.user_sessions where user_id = u;
  delete from public.team_memberships where user_id = u;
  delete from public.login_attempts where username = v;
  t := private.active_tournament();
  if t is null then
    insert into public.tournaments (name) values (p_tournament_name) returning id into t;
    insert into public.tournament_settings (tournament_id) values (t);
    insert into public.auction_sessions (tournament_id) values (t);
  end if;
  return 'Admin ready: ' || v;
end $$;

---------------------------------------------------------------- sign-in
create function public.login(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text := lower(trim(coalesce(p_username, ''))); u public.profiles; a public.login_attempts; tok text; ok boolean;
begin
  select * into a from login_attempts where username = v;
  if a.locked_until > now() then
    return jsonb_build_object('ok', false, 'message', 'Too many failed attempts. Try again in a minute.');
  end if;
  select * into u from profiles where username = v and is_active;
  -- A dummy hash keeps the response time the same for unknown usernames.
  ok := extensions.crypt(coalesce(p_password, ''), coalesce(u.password_hash, '$2a$10$abcdefghijklmnopqrstuuH4yXbCwUmXRaAl7GPy2SvWhAoEZWxG6')) = u.password_hash;
  if ok is not true then
    if u.id is not null then
      insert into login_attempts (username, failed_count, updated_at) values (v, 1, now())
      on conflict (username) do update set
        failed_count = case when login_attempts.failed_count >= 9 then 0 else login_attempts.failed_count + 1 end,
        locked_until = case when login_attempts.failed_count >= 9 then now() + interval '1 minute' else null end,
        updated_at = now();
    end if;
    return jsonb_build_object('ok', false, 'message', 'That username and password do not match.');
  end if;
  delete from login_attempts where username = v;
  delete from user_sessions where expires_at < now();
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into user_sessions (token_hash, user_id, expires_at)
  values (encode(sha256(convert_to(tok, 'utf8')), 'hex'), u.id, now() + interval '30 days');
  return jsonb_build_object('ok', true, 'token', tok);
end $$;

create function public.logout() returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from public.user_sessions where token_hash = encode(sha256(convert_to((nullif(current_setting('request.headers', true), '')::json)->>'x-league-session', 'utf8')), 'hex');
$$;

create function public.change_password(p_current text, p_new text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles;
begin
  select * into u from profiles where id = private.uid();
  if not found then raise exception 'Sign in again.' using errcode = '42501'; end if;
  if extensions.crypt(coalesce(p_current, ''), u.password_hash) <> u.password_hash then raise exception 'The current password is wrong.'; end if;
  perform private.check_credentials(u.username, p_new);
  update profiles set password_hash = private.hash_password(p_new), updated_at = now() where id = u.id;
  -- Every other device is signed out.
  delete from user_sessions where user_id = u.id and token_hash <> encode(sha256(convert_to((nullif(current_setting('request.headers', true), '')::json)->>'x-league-session', 'utf8')), 'hex');
end $$;

create function private.block_audit_change() returns trigger language plpgsql as $$
begin raise exception 'Audit logs are append-only'; end $$;
create trigger audit_logs_immutable before update or delete on public.admin_audit_logs
  for each row execute function private.block_audit_change();

---------------------------------------------------------------- public reads
create function public.get_my_context() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('user_id', p.id, 'username', p.username, 'display_name', p.display_name,
    'role', p.role, 'team_id', (select m.team_id from team_memberships m where m.user_id = p.id))
  from profiles p where p.id = private.uid() and p.is_active;
$$;

create function public.get_auction_state() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t public.tournaments; st public.tournament_settings; s public.auction_sessions;
  ap public.auction_players; pl public.players; res jsonb; stats jsonb; next_bid integer;
begin
  select * into t from tournaments where is_active limit 1;
  if not found then return null; end if;
  select * into st from tournament_settings where tournament_id = t.id;
  select * into s from auction_sessions where tournament_id = t.id;
  select * into ap from auction_players where id = s.current_auction_player_id;
  if ap.id is not null then
    select * into pl from players where id = ap.player_id;
    next_bid := case when ap.high_bid is null then ap.base_price else ap.high_bid + ap.bid_increment end;
  end if;

  select jsonb_build_object(
    'registered', (select count(*) from players where tournament_id = t.id and status <> 'rejected'),
    'sold', count(*) filter (where a.status = 'sold'),
    'unsold', count(*) filter (where a.status = 'unsold'),
    'remaining', count(*) filter (where a.status in ('queued','active','skipped')),
    'progress', case when count(*) filter (where a.status <> 'withdrawn') = 0 then 0
      else round(100.0 * count(*) filter (where a.status in ('sold','unsold')) / count(*) filter (where a.status <> 'withdrawn'), 1) end,
    'teams', (select count(*) from teams where tournament_id = t.id and is_active))
  into stats from auction_players a where a.session_id = s.id;

  if s.last_result_auction_player_id is not null then
    select jsonb_build_object(
      'auction_player_id', a.id, 'status', a.status, 'player_id', p.id, 'code', p.code, 'full_name', p.full_name,
      'photo_path', p.photo_path, 'primary_position', p.primary_position, 'category', p.category,
      'price', sl.price, 'team_id', sl.team_id, 'team_name', tm.name, 'team_logo', tm.logo_path, 'team_color', tm.color,
      'team_spent', b.spent, 'team_remaining', b.starting_budget - b.spent, 'confirmed_at', sl.confirmed_at)
    into res
    from auction_players a join players p on p.id = a.player_id
    left join player_sales sl on sl.auction_player_id = a.id and sl.undone_at is null
    left join teams tm on tm.id = sl.team_id
    left join team_budgets b on b.team_id = sl.team_id
    where a.id = s.last_result_auction_player_id;
  end if;

  return jsonb_build_object(
    'server_now', now(),
    'tournament', jsonb_build_object('id', t.id, 'name', t.name, 'short_name', t.short_name, 'logo_path', t.logo_path),
    'settings', to_jsonb(st) - 'tournament_id' - 'updated_at',
    'session', jsonb_build_object('id', s.id, 'status', s.status, 'phase', s.phase, 'version', s.version,
      'phase_started_at', s.phase_started_at, 'countdown_ends_at', s.countdown_ends_at, 'countdown_seconds', s.countdown_seconds,
      'paused_remaining_ms', s.paused_remaining_ms),
    'current', case when ap.id is null then null else jsonb_build_object(
      'auction_player_id', ap.id, 'player_id', pl.id, 'code', pl.code, 'full_name', pl.full_name, 'photo_path', pl.photo_path,
      'primary_position', pl.primary_position, 'secondary_position', pl.secondary_position, 'category', pl.category,
      'description', pl.description, 'base_price', ap.base_price, 'bid_increment', ap.bid_increment, 'high_bid', ap.high_bid,
      'high_team_id', ap.high_team_id, 'bid_count', ap.bid_count, 'round', ap.round, 'status', ap.status, 'next_bid', next_bid) end,
    'recent_bids', case when ap.id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(x order by x.created_at desc) from (
        select b.id, b.team_id, tm.name as team_name, tm.logo_path as team_logo, tm.color as team_color, b.amount, b.created_at
        from bids b join teams tm on tm.id = b.team_id
        where b.auction_player_id = ap.id and b.voided_at is null order by b.created_at desc limit 8) x), '[]'::jsonb) end,
    'last_result', res,
    'stats', stats,
    'teams', coalesce((select jsonb_agg(x order by x.name) from (
        select tm.id, tm.name, tm.short_name, tm.logo_path, tm.color, tm.is_active, b.starting_budget, b.spent,
          b.starting_budget - b.spent as remaining, b.squad_limit,
          (select count(*) from team_squads q where q.team_id = tm.id) as squad_count
        from teams tm join team_budgets b on b.team_id = tm.id where tm.tournament_id = t.id) x), '[]'::jsonb),
    'announcements', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select id, title, body, show_on_projector, created_at from announcements
        where tournament_id = t.id and is_published order by created_at desc limit 10) x), '[]'::jsonb),
    'recent_sales', coalesce((select jsonb_agg(x order by x.confirmed_at desc) from (
        select sl.id, p.full_name, p.code, sl.price, tm.name as team_name, sl.confirmed_at
        from player_sales sl join players p on p.id = sl.player_id join teams tm on tm.id = sl.team_id
        where sl.tournament_id = t.id and sl.undone_at is null order by sl.confirmed_at desc limit 8) x), '[]'::jsonb)
  );
end $$;

create function public.get_team_dashboard(p_team uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_team uuid := coalesce(p_team, private.current_team());
begin
  if v_team is null then raise exception 'This login is not linked to a team.' using errcode = '42501'; end if;
  if not private.is_admin() and v_team is distinct from private.current_team() then
    raise exception 'You can only open your own team.' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'team', jsonb_build_object('id', tm.id, 'name', tm.name, 'short_name', tm.short_name, 'logo_path', tm.logo_path, 'color', tm.color, 'is_active', tm.is_active),
      'starting_budget', b.starting_budget, 'spent', b.spent, 'remaining', b.starting_budget - b.spent, 'squad_limit', b.squad_limit,
      'squad', coalesce((select jsonb_agg(x order by x.acquired_at desc) from (
          select q.price, q.acquired_at, p.id as player_id, p.code, p.full_name, p.photo_path, p.primary_position, p.secondary_position, p.category
          from team_squads q join players p on p.id = q.player_id where q.team_id = tm.id) x), '[]'::jsonb),
      'positions', coalesce((select jsonb_object_agg(pos, c) from (
          select p.primary_position as pos, count(*) as c from team_squads q join players p on p.id = q.player_id
          where q.team_id = tm.id group by 1) y), '{}'::jsonb))
    from teams tm join team_budgets b on b.team_id = tm.id where tm.id = v_team);
end $$;

---------------------------------------------------------------- registration
create function public.registration_precheck(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); norm text := private.normalize_phone(p_phone);
begin
  if not (select registration_open from tournament_settings where tournament_id = t) then
    return jsonb_build_object('ok', false, 'message', 'Registration is closed.');
  end if;
  if exists (select 1 from player_contacts where tournament_id = t and phone_normalized = norm) then
    return jsonb_build_object('ok', false, 'message', 'This phone number is already registered for the tournament.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.register_player(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); r public.players;
begin
  if not (select registration_open from tournament_settings where tournament_id = t) then
    raise exception 'Registration is closed.';
  end if;
  if coalesce(p->>'photo_path', '') !~ '^registrations/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then
    raise exception 'Add a player photograph.';
  end if;
  if nullif(p->>'age', '') is null then raise exception 'Enter the player''s age.'; end if;
  if (p->>'age')::integer not between 5 and 100 then raise exception 'Enter an age between 5 and 100.'; end if;
  r := private.create_player(t, p - 'base_price', 'pending');
  perform private.touch_session(t);
  return jsonb_build_object('code', r.code, 'full_name', r.full_name, 'status', r.status);
exception when unique_violation then
  raise exception 'This phone number is already registered for the tournament.';
end $$;

---------------------------------------------------------------- admin: players
create function public.admin_save_player(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); r public.players; b public.players; norm text; v_id uuid := nullif(p->>'id', '')::uuid; st public.tournament_settings;
begin
  perform private.require_admin();
  if v_id is null then
    r := private.create_player(t, p, 'approved');
    perform private.audit('player.create', 'player', r.id::text, null, to_jsonb(r));
  else
    select * into b from players where id = v_id and tournament_id = t for update;
    if not found then raise exception 'Player not found.'; end if;
    select * into st from tournament_settings where tournament_id = t;
    if not (p->>'primary_position' = any(st.positions)) then raise exception 'Choose a primary position from the list.'; end if;
    if not (p->>'category' = any(st.categories)) then raise exception 'Choose a player category from the list.'; end if;
    update players set
      full_name = trim(p->>'full_name'), primary_position = p->>'primary_position',
      secondary_position = nullif(trim(coalesce(p->>'secondary_position', '')), ''),
      age = nullif(p->>'age', '')::integer, category = p->>'category',
      description = nullif(trim(coalesce(p->>'description', '')), ''),
      photo_path = coalesce(nullif(p->>'photo_path', ''), photo_path),
      base_price = nullif(p->>'base_price', '')::integer, updated_at = now()
    where id = v_id returning * into r;
    if nullif(p->>'phone', '') is not null then
      norm := private.normalize_phone(p->>'phone');
      if exists (select 1 from player_contacts where tournament_id = t and phone_normalized = norm and player_id <> v_id) then
        raise exception 'This phone number already belongs to another player.';
      end if;
      insert into player_contacts (player_id, tournament_id, phone, phone_normalized) values (v_id, t, trim(p->>'phone'), norm)
      on conflict (player_id) do update set phone = excluded.phone, phone_normalized = excluded.phone_normalized;
    end if;
    if r.base_price is not null then
      update auction_players a set base_price = r.base_price, updated_at = now()
      where a.player_id = v_id and a.bid_count = 0 and a.status in ('queued','skipped','unsold','active');
    end if;
    perform private.audit('player.update', 'player', v_id::text, to_jsonb(b), to_jsonb(r));
  end if;
  perform private.touch_session(t);
  return to_jsonb(r);
end $$;

create function public.admin_set_player_status(p_player uuid, p_status text, p_base_price integer default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); s public.auction_sessions; b public.players; r public.players; ap public.auction_players;
begin
  perform private.require_admin();
  if p_status not in ('approved','rejected','withdrawn','pending') then raise exception 'Unknown status.'; end if;
  s := private.lock_session();
  select * into b from players where id = p_player and tournament_id = t for update;
  if not found then raise exception 'Player not found.'; end if;
  select * into ap from auction_players where player_id = p_player and session_id = s.id;
  if ap.status = 'sold' and p_status <> 'approved' then raise exception 'This player has been sold. Undo the sale first.'; end if;
  if ap.status = 'active' and p_status <> 'approved' then raise exception 'This player is on the block. Skip or close the lot first.'; end if;
  update players set status = p_status, base_price = coalesce(p_base_price, base_price), updated_at = now(),
    approved_at = case when p_status = 'approved' then now() else approved_at end,
    approved_by = case when p_status = 'approved' then private.uid() else approved_by end
  where id = p_player returning * into r;
  if p_status = 'approved' then
    perform private.enroll_player(r);
  elsif ap.id is not null then
    update auction_players set status = 'withdrawn', updated_at = now() where id = ap.id;
  end if;
  perform private.audit('player.status', 'player', p_player::text, to_jsonb(b), to_jsonb(r));
  perform private.touch_session(t);
  return to_jsonb(r);
end $$;

create function public.admin_delete_player(p_player uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); s public.auction_sessions; b public.players;
begin
  perform private.require_admin();
  s := private.lock_session();
  select * into b from players where id = p_player and tournament_id = t for update;
  if not found then raise exception 'Player not found.'; end if;
  if exists (select 1 from player_sales where player_id = p_player) then
    raise exception 'This player has sale history. Withdraw the player instead.';
  end if;
  if exists (select 1 from auction_players where player_id = p_player and status = 'active') then
    raise exception 'This player is on the block.';
  end if;
  delete from players where id = p_player;
  perform private.audit('player.delete', 'player', p_player::text, to_jsonb(b), null);
  perform private.touch_session(t);
end $$;

create function public.admin_import_players(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); r jsonb; i integer := 0; created integer := 0; errors jsonb := '[]';
begin
  perform private.require_admin();
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin
      perform private.create_player(t, r, 'approved');
      created := created + 1;
    exception when others then
      errors := errors || jsonb_build_object('row', i, 'name', r->>'full_name', 'message', sqlerrm);
    end;
  end loop;
  perform private.audit('player.import', 'player', null, null, jsonb_build_object('created', created, 'errors', jsonb_array_length(errors)));
  perform private.touch_session(t);
  return jsonb_build_object('created', created, 'errors', errors);
end $$;

---------------------------------------------------------------- admin: teams and logins
create function public.admin_save_team(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); st public.tournament_settings; r public.teams; bd public.team_budgets; be jsonb; v_id uuid := nullif(p->>'id', '')::uuid;
  v_count integer; v_budget integer; v_limit integer;
begin
  perform private.require_admin();
  perform private.lock_session();
  select * into st from tournament_settings where tournament_id = t;
  if v_id is null then
    insert into teams (tournament_id, name, short_name, logo_path, color, is_active)
    values (t, trim(p->>'name'), nullif(trim(coalesce(p->>'short_name', '')), ''), nullif(p->>'logo_path', ''),
      coalesce(nullif(p->>'color', ''), '#FFC629'), coalesce((p->>'is_active')::boolean, true))
    returning * into r;
    insert into team_budgets (team_id, tournament_id, starting_budget, squad_limit)
    values (r.id, t, coalesce(nullif(p->>'starting_budget', '')::integer, st.default_budget), coalesce(nullif(p->>'squad_limit', '')::integer, st.default_squad_limit));
    perform private.audit('team.create', 'team', r.id::text, null, to_jsonb(r));
  else
    select to_jsonb(x) || to_jsonb(y) into be from teams x join team_budgets y on y.team_id = x.id where x.id = v_id and x.tournament_id = t;
    if be is null then raise exception 'Team not found.'; end if;
    update teams set
      name = coalesce(nullif(trim(p->>'name'), ''), name),
      short_name = case when p ? 'short_name' then nullif(trim(p->>'short_name'), '') else short_name end,
      logo_path = case when p ? 'logo_path' then nullif(p->>'logo_path', '') else logo_path end,
      color = coalesce(nullif(p->>'color', ''), color),
      is_active = coalesce((p->>'is_active')::boolean, is_active), updated_at = now()
    where id = v_id returning * into r;
    select * into bd from team_budgets where team_id = v_id for update;
    v_budget := coalesce(nullif(p->>'starting_budget', '')::integer, bd.starting_budget);
    v_limit := coalesce(nullif(p->>'squad_limit', '')::integer, bd.squad_limit);
    select count(*) into v_count from team_squads where team_id = v_id;
    if v_budget < bd.spent then raise exception 'Budget cannot go below the % points this team has already spent.', bd.spent; end if;
    if v_limit < v_count then raise exception 'Squad limit cannot go below the % players this team already has.', v_count; end if;
    update team_budgets set starting_budget = v_budget, squad_limit = v_limit, updated_at = now() where team_id = v_id;
    perform private.audit('team.update', 'team', v_id::text, be, to_jsonb(r) || jsonb_build_object('starting_budget', v_budget, 'squad_limit', v_limit));
  end if;
  perform private.touch_session(t);
  return to_jsonb(r);
exception when unique_violation then
  raise exception 'A team with this name already exists.';
end $$;

create function public.admin_delete_team(p_team uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); b public.teams;
begin
  perform private.require_admin();
  perform private.lock_session();
  select * into b from teams where id = p_team and tournament_id = t;
  if not found then raise exception 'Team not found.'; end if;
  if exists (select 1 from bids where team_id = p_team) or exists (select 1 from player_sales where team_id = p_team) then
    raise exception 'This team has auction history. Mark it inactive instead.';
  end if;
  delete from profiles where id in (select user_id from team_memberships where team_id = p_team) and role = 'team';
  delete from teams where id = p_team;
  perform private.audit('team.delete', 'team', p_team::text, to_jsonb(b), null);
  perform private.touch_session(t);
end $$;

create function public.admin_list_team_logins() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform private.require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'team_id', m.team_id, 'username', p.username, 'created_at', m.created_at) order by m.created_at)
    from team_memberships m join profiles p on p.id = m.user_id join teams t on t.id = m.team_id where t.tournament_id = private.active_tournament()), '[]'::jsonb);
end $$;

create function public.admin_create_team_login(p_team uuid, p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid; v text;
begin
  perform private.require_admin();
  v := private.check_credentials(p_username, p_password);
  if not exists (select 1 from teams where id = p_team and tournament_id = private.require_tournament()) then raise exception 'Team not found.'; end if;
  if exists (select 1 from profiles where username = v) then raise exception 'The username % is already taken.', v; end if;
  insert into profiles (username, password_hash, role) values (v, private.hash_password(p_password), 'team') returning id into u;
  insert into team_memberships (team_id, user_id) values (p_team, u);
  perform private.audit('team_login.create', 'team', p_team::text, null, jsonb_build_object('username', v));
  return jsonb_build_object('user_id', u, 'username', v);
end $$;

create function public.admin_reset_team_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text;
begin
  perform private.require_admin();
  select username into v from profiles where id = p_user and role = 'team';
  if v is null then raise exception 'Team login not found.'; end if;
  perform private.check_credentials(v, p_password);
  update profiles set password_hash = private.hash_password(p_password), updated_at = now() where id = p_user;
  delete from user_sessions where user_id = p_user;
  delete from login_attempts where username = v;
  perform private.audit('team_login.reset_password', 'profile', p_user::text, null, jsonb_build_object('username', v));
end $$;

create function public.admin_remove_team_login(p_user uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text; v_team uuid;
begin
  perform private.require_admin();
  select p.username, m.team_id into v, v_team from profiles p left join team_memberships m on m.user_id = p.id where p.id = p_user and p.role = 'team';
  if v is null then raise exception 'Team login not found.'; end if;
  delete from profiles where id = p_user;
  perform private.audit('team_login.remove', 'team', v_team::text, null, jsonb_build_object('username', v));
end $$;

---------------------------------------------------------------- admin: settings and announcements
create function public.admin_save_tournament(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); b jsonb; a jsonb;
begin
  perform private.require_admin();
  select to_jsonb(x) || to_jsonb(y) into b from tournaments x join tournament_settings y on y.tournament_id = x.id where x.id = t;
  update tournaments set
    name = coalesce(nullif(trim(p->>'name'), ''), name),
    short_name = case when p ? 'short_name' then nullif(trim(p->>'short_name'), '') else short_name end,
    logo_path = case when p ? 'logo_path' then nullif(p->>'logo_path', '') else logo_path end,
    updated_at = now() where id = t;
  update tournament_settings set
    primary_color = coalesce(nullif(p->>'primary_color', ''), primary_color),
    accent_color = coalesce(nullif(p->>'accent_color', ''), accent_color),
    background_color = coalesce(nullif(p->>'background_color', ''), background_color),
    sound_enabled = coalesce((p->>'sound_enabled')::boolean, sound_enabled),
    animation_intensity = coalesce(p->>'animation_intensity', animation_intensity),
    intro_duration_seconds = coalesce((p->>'intro_duration_seconds')::integer, intro_duration_seconds),
    bid_countdown_seconds = coalesce((p->>'bid_countdown_seconds')::integer, bid_countdown_seconds),
    last_call_seconds = coalesce((p->>'last_call_seconds')::integer, last_call_seconds),
    sold_display_seconds = coalesce((p->>'sold_display_seconds')::integer, sold_display_seconds),
    show_stats = coalesce((p->>'show_stats')::boolean, show_stats),
    registration_open = coalesce((p->>'registration_open')::boolean, registration_open),
    currency_label = coalesce(nullif(p->>'currency_label', ''), currency_label),
    default_base_price = coalesce((p->>'default_base_price')::integer, default_base_price),
    default_increment = coalesce((p->>'default_increment')::integer, default_increment),
    default_budget = coalesce((p->>'default_budget')::integer, default_budget),
    default_squad_limit = coalesce((p->>'default_squad_limit')::integer, default_squad_limit),
    positions = case when jsonb_typeof(p->'positions') = 'array' and jsonb_array_length(p->'positions') > 0
      then array(select jsonb_array_elements_text(p->'positions')) else positions end,
    categories = case when jsonb_typeof(p->'categories') = 'array' and jsonb_array_length(p->'categories') > 0
      then array(select jsonb_array_elements_text(p->'categories')) else categories end,
    updated_at = now()
  where tournament_id = t;
  select to_jsonb(x) || to_jsonb(y) into a from tournaments x join tournament_settings y on y.tournament_id = x.id where x.id = t;
  perform private.audit('settings.update', 'tournament', t::text, b, a);
  perform private.touch_session(t);
end $$;

create function public.admin_save_announcement(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); v uuid := nullif(p->>'id', '')::uuid;
begin
  perform private.require_admin();
  if v is null then
    insert into announcements (tournament_id, title, body, is_published, show_on_projector, created_by)
    values (t, trim(p->>'title'), nullif(trim(coalesce(p->>'body', '')), ''), coalesce((p->>'is_published')::boolean, true), coalesce((p->>'show_on_projector')::boolean, false), private.uid())
    returning id into v;
  else
    update announcements set title = trim(p->>'title'), body = nullif(trim(coalesce(p->>'body', '')), ''),
      is_published = coalesce((p->>'is_published')::boolean, is_published),
      show_on_projector = coalesce((p->>'show_on_projector')::boolean, show_on_projector), updated_at = now()
    where id = v and tournament_id = t;
  end if;
  perform private.audit('announcement.save', 'announcement', v::text, null, p);
  perform private.touch_session(t);
  return v;
end $$;

create function public.admin_delete_announcement(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament();
begin
  perform private.require_admin();
  delete from announcements where id = p_id and tournament_id = t;
  perform private.audit('announcement.delete', 'announcement', p_id::text, null, null);
  perform private.touch_session(t);
end $$;

---------------------------------------------------------------- admin: lot configuration
create function public.admin_update_lot(p_ap uuid, p_base integer, p_increment integer) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; a public.auction_players;
begin
  perform private.require_admin();
  s := private.lock_session();
  select * into a from auction_players where id = p_ap and session_id = s.id for update;
  if not found then raise exception 'Player is not in the auction pool.'; end if;
  if a.status = 'sold' then raise exception 'This player has been sold.'; end if;
  if p_base is not null and a.bid_count > 0 then raise exception 'The base price is locked once bids exist.'; end if;
  if p_base < 0 then raise exception 'Base price cannot be negative.'; end if;
  if p_increment <= 0 then raise exception 'Bid increment must be above zero.'; end if;
  update auction_players set base_price = coalesce(p_base, base_price), bid_increment = coalesce(p_increment, bid_increment), updated_at = now() where id = p_ap;
  perform private.audit('lot.update', 'auction_player', p_ap::text, to_jsonb(a), jsonb_build_object('base_price', p_base, 'bid_increment', p_increment));
  perform private.touch_session(s.tournament_id);
end $$;

create function public.admin_apply_lot_defaults(p_increment integer) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; n integer;
begin
  perform private.require_admin();
  s := private.lock_session();
  if p_increment <= 0 then raise exception 'Bid increment must be above zero.'; end if;
  update auction_players set bid_increment = p_increment, updated_at = now() where session_id = s.id and status in ('queued','skipped','unsold');
  get diagnostics n = row_count;
  perform private.audit('lot.apply_increment', 'session', s.id::text, null, jsonb_build_object('bid_increment', p_increment, 'players', n));
  perform private.touch_session(s.tournament_id);
  return n;
end $$;

---------------------------------------------------------------- auction control
create function public.admin_start_auction() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions;
begin
  perform private.require_admin();
  s := private.lock_session();
  if s.status = 'live' then raise exception 'The auction is already running.'; end if;
  if s.status = 'paused' then raise exception 'The auction is paused. Use Resume.'; end if;
  update auction_sessions set status = 'live', started_at = coalesce(started_at, now()), ended_at = null, version = version + 1, updated_at = now() where id = s.id;
  perform private.log_event(s.id, 'auction_started', null, null, null, 'Auction started');
  perform private.audit('auction.start', 'session', s.id::text, null, null);
end $$;

create function public.admin_pause_auction() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions;
begin
  perform private.require_admin();
  s := private.lock_session();
  if s.status <> 'live' then raise exception 'The auction is not running.'; end if;
  update auction_sessions set status = 'paused',
    paused_remaining_ms = case when countdown_ends_at is null then null else greatest(0, (extract(epoch from countdown_ends_at - now()) * 1000)::integer) end,
    countdown_ends_at = null, version = version + 1, updated_at = now() where id = s.id;
  perform private.log_event(s.id, 'auction_paused', s.current_auction_player_id, null, null, 'Auction paused');
  perform private.audit('auction.pause', 'session', s.id::text, null, null);
end $$;

create function public.admin_resume_auction() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions;
begin
  perform private.require_admin();
  s := private.lock_session();
  if s.status <> 'paused' then raise exception 'The auction is not paused.'; end if;
  update auction_sessions set status = 'live',
    countdown_ends_at = case when paused_remaining_ms is null then null else now() + make_interval(secs => paused_remaining_ms / 1000.0) end,
    paused_remaining_ms = null, version = version + 1, updated_at = now() where id = s.id;
  perform private.log_event(s.id, 'auction_resumed', s.current_auction_player_id, null, null, 'Auction resumed');
  perform private.audit('auction.resume', 'session', s.id::text, null, null);
end $$;

create function public.admin_end_auction() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions;
begin
  perform private.require_admin();
  s := private.lock_session();
  if s.status = 'ended' then raise exception 'The auction has already ended.'; end if;
  if s.phase in ('introduction','bidding','last_call','closed') then raise exception 'Finish the current player first: confirm SOLD, mark UNSOLD or skip.'; end if;
  update auction_sessions set status = 'ended', phase = 'idle', current_auction_player_id = null, countdown_ends_at = null, countdown_seconds = null,
    paused_remaining_ms = null, ended_at = now(), phase_started_at = now(), version = version + 1, updated_at = now() where id = s.id;
  perform private.log_event(s.id, 'auction_ended', null, null, null, 'Auction ended');
  perform private.audit('auction.end', 'session', s.id::text, null, null);
end $$;

-- p_ap chooses a specific player; otherwise p_mode 'order' or 'random' picks from the queue.
create function public.admin_select_player(p_ap uuid default null, p_mode text default 'order') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; a public.auction_players; v_id uuid := p_ap;
begin
  perform private.require_admin();
  s := private.lock_session();
  perform private.require_live(s);
  if s.phase not in ('idle','sold','unsold') then raise exception 'Finish the current player before selecting the next one.'; end if;
  if v_id is null then
    select id into v_id from auction_players where session_id = s.id and status in ('queued','skipped')
    order by case status when 'queued' then 0 else 1 end, case when p_mode = 'random' then random() else 0 end, order_no limit 1;
    if v_id is null then raise exception 'No players are waiting in the queue.'; end if;
  end if;
  select * into a from auction_players where id = v_id and session_id = s.id for update;
  if not found then raise exception 'Player is not in the auction pool.'; end if;
  if a.status not in ('queued','skipped') then raise exception 'This player cannot be selected. Status: %.', a.status; end if;
  update auction_players set status = 'active', updated_at = now() where id = v_id;
  update auction_sessions set last_result_auction_player_id = null where id = s.id;
  perform private.set_phase(s.id, 'introduction', null, v_id, false);
  perform private.log_event(s.id, 'player_selected', v_id, null, null, 'Player introduced');
  perform private.audit('auction.select_player', 'auction_player', v_id::text, null, null);
  return v_id;
end $$;

create function public.admin_open_bidding() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; c integer;
begin
  perform private.require_admin();
  s := private.lock_session();
  perform private.require_live(s);
  if s.phase not in ('introduction','closed','last_call') then raise exception 'Bidding cannot be opened from this stage.'; end if;
  select bid_countdown_seconds into c from tournament_settings where tournament_id = s.tournament_id;
  perform private.set_phase(s.id, 'bidding', c);
  perform private.log_event(s.id, case when s.phase = 'introduction' then 'bidding_opened' else 'bidding_reopened' end, s.current_auction_player_id, null, null, 'Bidding open');
  perform private.audit('auction.open_bidding', 'auction_player', s.current_auction_player_id::text, null, null);
end $$;

create function public.admin_close_bidding() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions;
begin
  perform private.require_admin();
  s := private.lock_session();
  perform private.require_live(s);
  if s.phase not in ('bidding','last_call') then raise exception 'Bidding is not open.'; end if;
  perform private.set_phase(s.id, 'closed');
  perform private.log_event(s.id, 'bidding_closed', s.current_auction_player_id, null, null, 'Bidding closed');
  perform private.audit('auction.close_bidding', 'auction_player', s.current_auction_player_id::text, null, null);
end $$;

create function public.admin_last_call() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; c integer;
begin
  perform private.require_admin();
  s := private.lock_session();
  perform private.require_live(s);
  if s.phase not in ('bidding','closed') then raise exception 'Last call needs open bidding.'; end if;
  select last_call_seconds into c from tournament_settings where tournament_id = s.tournament_id;
  perform private.set_phase(s.id, 'last_call', c);
  perform private.log_event(s.id, 'last_call', s.current_auction_player_id, null, null, 'Last call');
  perform private.audit('auction.last_call', 'auction_player', s.current_auction_player_id::text, null, null);
end $$;

create function public.admin_confirm_sold(p_ap uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; a public.auction_players; b public.team_budgets; v_sale uuid; v_tid uuid; v_count integer;
begin
  perform private.require_admin();
  s := private.lock_session();
  perform private.require_live(s);
  if s.current_auction_player_id is distinct from p_ap then raise exception 'This player is no longer on the block.'; end if;
  if s.phase not in ('last_call','closed') then raise exception 'Trigger last call or close bidding before confirming a sale.'; end if;
  select * into a from auction_players where id = p_ap for update;
  if a.status <> 'active' then raise exception 'This player has already been resolved.'; end if;
  if a.high_team_id is null then raise exception 'There are no bids. Mark the player unsold instead.'; end if;
  select * into b from team_budgets where team_id = a.high_team_id for update;
  if b.starting_budget - b.spent < a.high_bid then raise exception 'The winning team no longer has enough points.'; end if;
  select count(*) into v_count from team_squads where team_id = a.high_team_id;
  if v_count >= b.squad_limit then raise exception 'The winning team''s squad is full.'; end if;

  v_tid := s.tournament_id;
  insert into player_sales (tournament_id, session_id, auction_player_id, player_id, team_id, price, winning_bid_id, confirmed_by)
  values (v_tid, s.id, p_ap, a.player_id, a.high_team_id, a.high_bid, a.high_bid_id, private.uid()) returning id into v_sale;
  insert into team_squads (tournament_id, team_id, player_id, sale_id, price) values (v_tid, a.high_team_id, a.player_id, v_sale, a.high_bid);
  perform private.recalc_budget(a.high_team_id);
  update auction_players set status = 'sold', updated_at = now() where id = p_ap;
  update auction_sessions set last_result_auction_player_id = p_ap where id = s.id;
  perform private.set_phase(s.id, 'sold');
  perform private.log_event(s.id, 'player_sold', p_ap, a.high_team_id, a.high_bid, 'Sold', jsonb_build_object('sale_id', v_sale));
  perform private.audit('auction.sold', 'player_sale', v_sale::text, null, jsonb_build_object('player_id', a.player_id, 'team_id', a.high_team_id, 'price', a.high_bid));
  return jsonb_build_object('sale_id', v_sale, 'price', a.high_bid, 'team_id', a.high_team_id);
end $$;

create function public.admin_mark_unsold(p_ap uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; a public.auction_players;
begin
  perform private.require_admin();
  s := private.lock_session();
  perform private.require_live(s);
  if s.current_auction_player_id is distinct from p_ap then raise exception 'This player is no longer on the block.'; end if;
  if s.phase not in ('introduction','bidding','last_call','closed') then raise exception 'This player has already been resolved.'; end if;
  select * into a from auction_players where id = p_ap for update;
  perform private.reset_lot(p_ap, 'unsold');
  update auction_sessions set last_result_auction_player_id = p_ap where id = s.id;
  perform private.set_phase(s.id, 'unsold');
  perform private.log_event(s.id, 'player_unsold', p_ap, null, a.high_bid, 'Unsold');
  perform private.audit('auction.unsold', 'auction_player', p_ap::text, to_jsonb(a), null);
end $$;

create function public.admin_skip_player(p_ap uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; a public.auction_players;
begin
  perform private.require_admin();
  s := private.lock_session();
  perform private.require_live(s);
  if s.current_auction_player_id is distinct from p_ap then raise exception 'This player is no longer on the block.'; end if;
  if s.phase not in ('introduction','bidding','last_call','closed') then raise exception 'This player has already been resolved.'; end if;
  select * into a from auction_players where id = p_ap for update;
  perform private.reset_lot(p_ap, 'skipped');
  perform private.set_phase(s.id, 'idle', null, null, false);
  perform private.log_event(s.id, 'player_skipped', p_ap, null, a.high_bid, 'Skipped');
  perform private.audit('auction.skip', 'auction_player', p_ap::text, to_jsonb(a), null);
end $$;

create function public.admin_reopen_unsold(p_ap uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; a public.auction_players;
begin
  perform private.require_admin();
  s := private.lock_session();
  select * into a from auction_players where id = p_ap and session_id = s.id for update;
  if not found or a.status not in ('unsold','skipped') then raise exception 'Only unsold or skipped players can be reopened.'; end if;
  update auction_players set status = 'queued', updated_at = now() where id = p_ap;
  if s.last_result_auction_player_id = p_ap then
    update auction_sessions set last_result_auction_player_id = null where id = s.id;
    if s.phase = 'unsold' then perform private.set_phase(s.id, 'idle', null, null, false); end if;
  end if;
  perform private.log_event(s.id, 'player_reopened', p_ap, null, null, 'Returned to queue');
  perform private.audit('auction.reopen_unsold', 'auction_player', p_ap::text, to_jsonb(a), null);
  perform private.touch_session(s.tournament_id);
end $$;

create function public.admin_undo_sale(p_sale uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; sl public.player_sales; v_was_current boolean;
begin
  perform private.require_admin();
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Give a reason for undoing this sale.'; end if;
  s := private.lock_session();
  select * into sl from player_sales where id = p_sale and tournament_id = s.tournament_id for update;
  if not found then raise exception 'Sale not found.'; end if;
  if sl.undone_at is not null then raise exception 'This sale has already been undone.'; end if;
  update player_sales set undone_at = now(), undone_by = private.uid(), undo_reason = trim(p_reason) where id = p_sale;
  delete from team_squads where sale_id = p_sale;
  perform private.recalc_budget(sl.team_id);
  perform private.reset_lot(sl.auction_player_id, 'queued');
  v_was_current := s.current_auction_player_id = sl.auction_player_id;
  if s.last_result_auction_player_id = sl.auction_player_id then
    update auction_sessions set last_result_auction_player_id = null where id = s.id;
  end if;
  if v_was_current and s.phase = 'sold' then
    perform private.set_phase(s.id, 'idle', null, null, false);
  else
    perform private.touch_session(s.tournament_id);
  end if;
  perform private.log_event(s.id, 'sale_undone', sl.auction_player_id, sl.team_id, sl.price, trim(p_reason), jsonb_build_object('sale_id', p_sale));
  perform private.audit('auction.undo_sale', 'player_sale', p_sale::text, to_jsonb(sl), null, trim(p_reason));
end $$;

---------------------------------------------------------------- bidding
create function private.reject_bid(p_session uuid, p_ap uuid, p_team uuid, p_amount integer, p_code text, p_message text, p_next integer default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.log_event(p_session, 'bid_rejected', p_ap, p_team, p_amount, p_message, jsonb_build_object('code', p_code));
  return jsonb_build_object('ok', false, 'code', p_code, 'message', p_message, 'next_bid', p_next);
end $$;

create function private.apply_bid(p_ap uuid, p_team uuid, p_amount integer, p_source text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.auction_sessions; a public.auction_players; b public.team_budgets; tm public.teams; v_next integer; v_bid uuid; v_count integer; v_cd integer;
begin
  s := private.lock_session();
  select * into tm from teams where id = p_team and tournament_id = s.tournament_id;
  if not found then raise exception 'Team not found.'; end if;
  select * into a from auction_players where id = p_ap and session_id = s.id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'unknown_player', 'message', 'This player is not in the auction.'); end if;
  v_next := case when a.high_bid is null then a.base_price else a.high_bid + a.bid_increment end;

  if not tm.is_active then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'team_inactive', 'This team is inactive.'); end if;
  if s.status = 'paused' then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'paused', 'The auction is paused.', v_next); end if;
  if s.status <> 'live' then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'not_running', 'The auction is not running.'); end if;
  if s.current_auction_player_id is distinct from p_ap then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'wrong_player', 'Bidding has moved to another player.'); end if;
  if s.phase not in ('bidding','last_call') then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'not_open', 'Bidding is not open.', v_next); end if;
  if s.phase = 'last_call' and s.countdown_ends_at <= now() then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'last_call_over', 'Last call has ended.', v_next); end if;
  if a.high_team_id = p_team then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'already_leading', 'Your team already has the highest bid.', v_next); end if;
  if p_amount is distinct from v_next then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'price_moved', 'The price moved. The next valid bid is ' || v_next || '.', v_next); end if;
  select * into b from team_budgets where team_id = p_team for update;
  if b.starting_budget - b.spent < p_amount then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'insufficient_points', 'Your team does not have enough points for this bid.', v_next); end if;
  select count(*) into v_count from team_squads where team_id = p_team;
  if v_count >= b.squad_limit then return private.reject_bid(s.id, p_ap, p_team, p_amount, 'squad_full', 'Your squad is full.', v_next); end if;

  insert into bids (session_id, auction_player_id, team_id, amount, round, placed_by, source)
  values (s.id, p_ap, p_team, p_amount, a.round, private.uid(), p_source) returning id into v_bid;
  update auction_players set high_bid = p_amount, high_team_id = p_team, high_bid_id = v_bid, bid_count = bid_count + 1, updated_at = now() where id = p_ap;

  select case when s.phase = 'last_call' then last_call_seconds else bid_countdown_seconds end into v_cd from tournament_settings where tournament_id = s.tournament_id;
  update auction_sessions set
    countdown_seconds = nullif(v_cd, 0),
    countdown_ends_at = case when v_cd > 0 then now() + make_interval(secs => v_cd) end,
    version = version + 1, updated_at = now()
  where id = s.id;
  perform private.log_event(s.id, 'bid_accepted', p_ap, p_team, p_amount, null, jsonb_build_object('bid_id', v_bid, 'source', p_source));
  return jsonb_build_object('ok', true, 'bid_id', v_bid, 'amount', p_amount, 'next_bid', p_amount + a.bid_increment);
end $$;

create function public.place_bid(p_auction_player_id uuid, p_amount integer) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_team uuid := private.current_team();
begin
  if v_team is null then raise exception 'Only team logins can bid.' using errcode = '42501'; end if;
  return private.apply_bid(p_auction_player_id, v_team, p_amount, 'team');
end $$;

create function public.admin_place_bid(p_auction_player_id uuid, p_team uuid, p_amount integer) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb;
begin
  perform private.require_admin();
  r := private.apply_bid(p_auction_player_id, p_team, p_amount, 'admin');
  if (r->>'ok')::boolean then
    perform private.audit('auction.admin_bid', 'bid', r->>'bid_id', null, jsonb_build_object('team_id', p_team, 'amount', p_amount));
  end if;
  return r;
end $$;

---------------------------------------------------------------- admin: lists and reports
create function public.admin_list(p_kind text, p_limit integer default 1000) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t uuid := private.require_tournament(); sid uuid; r jsonb;
begin
  perform private.require_admin();
  select id into sid from auction_sessions where tournament_id = t;
  if p_kind = 'players' then
    select jsonb_agg(to_jsonb(p) || jsonb_build_object('phone', c.phone, 'auction_player_id', a.id, 'auction_status', a.status,
        'lot_base_price', a.base_price, 'bid_increment', a.bid_increment) order by p.created_at desc) into r
    from players p left join player_contacts c on c.player_id = p.id left join auction_players a on a.player_id = p.id and a.session_id = sid
    where p.tournament_id = t;
  elsif p_kind = 'lots' then
    select jsonb_agg(jsonb_build_object('auction_player_id', a.id, 'status', a.status, 'order_no', a.order_no, 'base_price', a.base_price,
        'bid_increment', a.bid_increment, 'bid_count', a.bid_count, 'player_id', p.id, 'code', p.code, 'full_name', p.full_name,
        'photo_path', p.photo_path, 'primary_position', p.primary_position, 'category', p.category) order by a.order_no) into r
    from auction_players a join players p on p.id = a.player_id where a.session_id = sid;
  elsif p_kind = 'sales' then
    select jsonb_agg(jsonb_build_object('id', s.id, 'price', s.price, 'confirmed_at', s.confirmed_at, 'undone_at', s.undone_at, 'undo_reason', s.undo_reason,
        'player_id', p.id, 'code', p.code, 'full_name', p.full_name, 'photo_path', p.photo_path, 'primary_position', p.primary_position, 'category', p.category,
        'team_id', tm.id, 'team_name', tm.name) order by s.confirmed_at desc) into r
    from player_sales s join players p on p.id = s.player_id join teams tm on tm.id = s.team_id where s.tournament_id = t;
  elsif p_kind = 'events' then
    select jsonb_agg(x order by x.id desc) into r from (
      select e.id, e.type, e.amount, e.message, e.created_at, e.payload, e.team_id, tm.name as team_name, p.full_name, p.code
      from auction_events e left join teams tm on tm.id = e.team_id
      left join auction_players a on a.id = e.auction_player_id left join players p on p.id = a.player_id
      where e.session_id = sid order by e.id desc limit p_limit) x;
  elsif p_kind = 'bids' then
    select jsonb_agg(x order by x.created_at desc) into r from (
      select b.id, b.amount, b.round, b.source, b.voided_at, b.created_at, tm.name as team_name, p.full_name, p.code
      from bids b join teams tm on tm.id = b.team_id join auction_players a on a.id = b.auction_player_id join players p on p.id = a.player_id
      where b.session_id = sid order by b.created_at desc limit p_limit) x;
  elsif p_kind = 'audit' then
    select jsonb_agg(x order by x.id desc) into r from (
      select l.id, l.action, l.entity_type, l.entity_id, l.reason, l.created_at, pr.username as actor_username, l.before_data, l.after_data
      from admin_audit_logs l left join profiles pr on pr.id = l.actor_id
      where l.tournament_id = t order by l.id desc limit p_limit) x;
  elsif p_kind = 'squads' then
    select jsonb_agg(jsonb_build_object('team_name', tm.name, 'code', p.code, 'full_name', p.full_name, 'primary_position', p.primary_position,
        'category', p.category, 'price', q.price, 'acquired_at', q.acquired_at) order by tm.name, q.acquired_at) into r
    from team_squads q join teams tm on tm.id = q.team_id join players p on p.id = q.player_id where q.tournament_id = t;
  elsif p_kind = 'announcements' then
    select jsonb_agg(to_jsonb(a) order by a.created_at desc) into r from announcements a where a.tournament_id = t;
  else
    raise exception 'Unknown list: %', p_kind;
  end if;
  return coalesce(r, '[]'::jsonb);
end $$;
-- League Auction: privileges, row level security, storage and realtime.

-- Supabase grants broad table and function rights by default. Replace them with an explicit list.
do $$
declare r record;
begin
  execute 'revoke all on all tables in schema public from anon, authenticated';
  execute 'revoke all on all sequences in schema public from anon, authenticated';
  for r in select p.oid::regprocedure as f from pg_proc p where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace) loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
  end loop;
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', r.tablename);
    execute format('grant select on public.%I to anon, authenticated', r.tablename);
  end loop;
end $$;

-- Password hashes, sessions and login counters are reachable only through the functions.
revoke all on public.profiles, public.user_sessions, public.login_attempts from anon, authenticated;

grant usage on schema private to anon, authenticated;
grant execute on function private.is_admin(), private.current_team(), private.uid() to anon, authenticated;

-- Open to the public: registration and the read-only live state used by the projector.
grant execute on function public.get_auction_state(), public.registration_precheck(text), public.register_player(jsonb),
  public.login(text, text), public.logout() to anon, authenticated;

-- The API role is the same for everyone, so each of these functions checks the session and role itself.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like 'admin\_%' or p.proname in ('place_bid','get_team_dashboard','get_my_context','change_password')) loop
    execute format('grant execute on function %s to anon, authenticated', r.f);
  end loop;
end $$;

-- Read policies. There are no write policies: writes happen only through the functions above.
create policy "public read" on public.tournaments for select using (true);
create policy "public read" on public.tournament_settings for select using (true);
create policy "approved or admin" on public.players for select using (status = 'approved' or (select private.is_admin()));
create policy "admin only" on public.player_contacts for select using ((select private.is_admin()));
create policy "public read" on public.teams for select using (true);
create policy "self or admin" on public.team_memberships for select using (user_id = (select private.uid()) or (select private.is_admin()));
create policy "public read" on public.team_budgets for select using (true);
create policy "public read" on public.auction_sessions for select using (true);
create policy "public read" on public.auction_players for select using (true);
create policy "own team or admin" on public.bids for select using (team_id = (select private.current_team()) or (select private.is_admin()));
create policy "own team or admin" on public.player_sales for select using (team_id = (select private.current_team()) or (select private.is_admin()));
create policy "own team or admin" on public.team_squads for select using (team_id = (select private.current_team()) or (select private.is_admin()));
create policy "admin only" on public.auction_events for select using ((select private.is_admin()));
create policy "admin only" on public.admin_audit_logs for select using ((select private.is_admin()));
create policy "published or admin" on public.announcements for select using (is_published or (select private.is_admin()));

-- Storage: public images, in known folders only, with no overwriting or deleting.
-- Uploading alone changes nothing: only the checked functions can attach a file to a player, team or tournament.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('league-media', 'league-media', true, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

create policy "league media read" on storage.objects for select using (bucket_id = 'league-media');
create policy "league media upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'league-media' and (storage.foldername(name))[1] in ('registrations','players','teams','branding'));

-- Realtime: clients watch the session version, then fetch the state from the server.
alter publication supabase_realtime add table public.auction_sessions;

notify pgrst, 'reload schema';

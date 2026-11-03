-- League Auction: tables, constraints and indexes.
create schema if not exists private;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  role text not null default 'viewer' check (role in ('admin','team','viewer')),
  created_at timestamptz not null default now()
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
  approved_by uuid references auth.users(id) on delete set null,
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
  user_id uuid not null unique references auth.users(id) on delete cascade,
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
  placed_by uuid references auth.users(id) on delete set null,
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
  confirmed_by uuid references auth.users(id) on delete set null,
  confirmed_at timestamptz not null default now(),
  undone_at timestamptz,
  undone_by uuid references auth.users(id) on delete set null,
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
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index announcements_recent_idx on public.announcements (tournament_id, created_at desc);

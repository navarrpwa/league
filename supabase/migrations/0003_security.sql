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

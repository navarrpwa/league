-- DELETES ALL LEAGUE AUCTION DATA in this project. Run it only to replace an earlier setup,
-- then run setup_all.sql. Do not run it once real players or teams have been added.
drop trigger if exists on_auth_user_created on auth.users;
drop policy if exists "league media read" on storage.objects;
drop policy if exists "league media upload" on storage.objects;
drop policy if exists "league registration upload" on storage.objects;
drop policy if exists "league admin upload" on storage.objects;
drop policy if exists "league admin update" on storage.objects;
drop policy if exists "league admin delete" on storage.objects;
drop table if exists public.announcements, public.admin_audit_logs, public.auction_events, public.team_squads,
  public.player_sales, public.bids, public.auction_players, public.auction_sessions, public.team_budgets,
  public.team_memberships, public.teams, public.player_contacts, public.players, public.tournament_settings,
  public.tournaments, public.login_attempts, public.user_sessions, public.profiles cascade;
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p where p.pronamespace = 'public'::regnamespace
    and (p.proname like 'admin\_%' or p.proname in ('get_my_context','get_auction_state','get_team_dashboard','registration_precheck','register_player','place_bid','login','logout','change_password')) loop
    execute format('drop function %s', r.f);
  end loop;
end $$;
drop schema if exists private cascade;

-- The Frog permanent : un changement toutes les 168 heures, une victoire par jour.
-- Migration réexécutable, compatible avec la première version quotidienne.
begin;
create table if not exists public.frog_days (
  user_id uuid not null references auth.users on delete cascade,
  day date not null,
  habit_id uuid references public.habits on delete set null,
  habit_name text not null,
  selected_at timestamptz not null default now(),
  eaten_at timestamptz,
  primary key (user_id, day)
);
create table if not exists public.frog_choices (
  user_id uuid primary key references auth.users on delete cascade,
  habit_id uuid references public.habits on delete set null,
  habit_name text not null,
  selected_at timestamptz not null default now(),
  timezone text not null default 'America/Toronto'
);
alter table public.frog_days enable row level security;
alter table public.frog_choices enable row level security;
revoke all on public.frog_days, public.frog_choices from anon, authenticated;
grant select on public.frog_days, public.frog_choices to authenticated;
drop policy if exists "lecture frogs" on public.frog_days;
create policy "lecture frogs" on public.frog_days for select to authenticated using (true);
drop policy if exists "lecture choix frog" on public.frog_choices;
create policy "lecture choix frog" on public.frog_choices for select to authenticated using (true);

-- Si l'ancienne version a été utilisée, garder le choix le plus récent et tous les scores.
insert into public.frog_choices(user_id, habit_id, habit_name, selected_at)
select distinct on (user_id) user_id, habit_id, habit_name, selected_at
from public.frog_days order by user_id, day desc, selected_at desc
on conflict (user_id) do nothing;

-- Fonction interne : conserver la victoire déjà gagnée ou suivre le Frog courant.
create or replace function public.reconcile_frog_day(uid uuid, d date)
returns void language plpgsql security definer set search_path = '' as $$
declare
  previous public.frog_days;
  choice public.frog_choices;
  completion timestamptz;
  current_name text;
begin
  if not exists(select 1 from auth.users where id = uid) then return; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('frog:' || uid::text, 0));
  select * into previous from public.frog_days where user_id = uid and day = d for update;
  if previous.eaten_at is not null and (previous.habit_id is null or exists(
    select 1 from public.checks where user_id = uid and habit_id = previous.habit_id and day = d
  )) then return; end if;
  update public.frog_days set eaten_at = null where user_id = uid and day = d;
  select * into choice from public.frog_choices where user_id = uid;
  if choice.user_id is null or choice.habit_id is null or d < (choice.selected_at at time zone choice.timezone)::date then return; end if;
  select h.name into current_name from public.habits h
    where h.id = choice.habit_id and h.user_id = uid and (to_jsonb(h)->>'archived_at') is null;
  if not found then return; end if;
  select created_at into completion from public.checks
    where user_id = uid and habit_id = choice.habit_id and day = d;
  insert into public.frog_days(user_id, day, habit_id, habit_name, eaten_at)
    values(uid, d, choice.habit_id, current_name, completion)
    on conflict(user_id, day) do update set habit_id = excluded.habit_id,
      habit_name = excluded.habit_name, eaten_at = excluded.eaten_at;
end $$;
revoke all on function public.reconcile_frog_day(uuid, date) from public, anon, authenticated;

create or replace function public.set_frog(p_habit_id uuid, p_timezone text)
returns public.frog_choices language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  chosen public.habits;
  previous public.frog_choices;
  result public.frog_choices;
  instant timestamptz := clock_timestamp();
begin
  if uid is null then raise exception 'Connexion requise'; end if;
  if p_timezone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'Fuseau horaire invalide';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('frog:' || uid::text, 0));
  select h.* into chosen from public.habits h where h.id = p_habit_id and h.user_id = uid
    and (to_jsonb(h)->>'archived_at') is null;
  if not found then raise exception 'Choisis une de tes habitudes actives'; end if;
  select * into previous from public.frog_choices where user_id = uid for update;
  -- Réessayer le même choix ne repousse jamais la date de changement.
  if previous.habit_id = p_habit_id then return previous; end if;
  if previous.selected_at is not null and instant < previous.selected_at + interval '168 hours' then
    raise exception 'Tu dois attendre 7 jours entre deux changements de Frog';
  end if;
  insert into public.frog_choices(user_id, habit_id, habit_name, selected_at, timezone)
    values(uid, chosen.id, chosen.name, instant, p_timezone)
    on conflict(user_id) do update set habit_id = excluded.habit_id,
      habit_name = excluded.habit_name, selected_at = excluded.selected_at, timezone = excluded.timezone
    returning * into result;
  perform public.reconcile_frog_day(uid, (instant at time zone p_timezone)::date);
  return result;
end $$;
revoke all on function public.set_frog(uuid, text) from public, anon;
grant execute on function public.set_frog(uuid, text) to authenticated;

-- Compatibilité avec une ancienne fenêtre ouverte : impossible de contourner les 7 jours.
create or replace function public.choose_frog(p_habit_id uuid, p_day date, p_timezone text)
returns public.frog_days language plpgsql security definer set search_path = '' as $$
declare result public.frog_days;
begin
  if p_timezone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then raise exception 'Fuseau horaire invalide'; end if;
  if p_day is null or p_day <> (now() at time zone p_timezone)::date then raise exception 'Recharge l’application pour choisir ton Frog'; end if;
  perform public.set_frog(p_habit_id, p_timezone);
  select * into result from public.frog_days where user_id = auth.uid() and day = p_day;
  return result;
end $$;
revoke all on function public.choose_frog(uuid, date, text) from public, anon;
grant execute on function public.choose_frog(uuid, date, text) to authenticated;

create or replace function public.sync_frog_check()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform public.reconcile_frog_day(old.user_id, old.day); return old;
  else
    perform public.reconcile_frog_day(new.user_id, new.day); return new;
  end if;
end $$;
revoke all on function public.sync_frog_check() from public, anon, authenticated;
drop trigger if exists frog_check_sync on public.checks;
create trigger frog_check_sync after insert or delete on public.checks
  for each row execute function public.sync_frog_check();

create or replace function public.preserve_frog_history()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.frog_days set habit_id = null, habit_name = old.name where habit_id = old.id;
  update public.frog_choices set habit_id = null, habit_name = old.name where habit_id = old.id;
  return old;
end $$;
revoke all on function public.preserve_frog_history() from public, anon, authenticated;
drop trigger if exists frog_preserve_history on public.habits;
create trigger frog_preserve_history before delete on public.habits
  for each row execute function public.preserve_frog_history();

create or replace function public.frog_stats(p_day date)
returns table(user_id uuid, eaten_total bigint, eaten_30 bigint, chosen_30 bigint)
language sql stable security invoker set search_path = '' as $$
  select f.user_id,
    count(*) filter(where f.eaten_at is not null),
    count(*) filter(where f.eaten_at is not null and f.day between p_day - 29 and p_day),
    count(*) filter(where f.day between p_day - 29 and p_day)
  from public.frog_days f where f.day <= p_day group by f.user_id;
$$;
revoke all on function public.frog_stats(date) from public, anon;
grant execute on function public.frog_stats(date) to authenticated;
do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'frog_days') then
    alter publication supabase_realtime add table public.frog_days;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'frog_choices') then
    alter publication supabase_realtime add table public.frog_choices;
  end if;
end $$;
notify pgrst, 'reload schema';
commit;

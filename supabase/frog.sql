-- The Frog : un défi par personne et par jour, conservé après retrait d'une habitude.
-- À exécuter une fois dans le SQL Editor du projet Habitudes (réexécutable).
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
alter table public.frog_days enable row level security;
revoke all on public.frog_days from anon, authenticated;
grant select on public.frog_days to authenticated;
drop policy if exists "lecture frogs" on public.frog_days;
create policy "lecture frogs" on public.frog_days for select to authenticated using (true);

-- Les écritures passent par cette fonction : propriétaire, date locale et unicité vérifiés.
create or replace function public.choose_frog(p_habit_id uuid, p_day date, p_timezone text)
returns public.frog_days language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  chosen public.habits;
  previous public.frog_days;
  result public.frog_days;
  completion timestamptz;
begin
  if uid is null then raise exception 'Connexion requise'; end if;
  if p_timezone is null or not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'Fuseau horaire invalide';
  end if;
  if p_day is null or p_day <> (now() at time zone p_timezone)::date then
    raise exception 'Choisis ton Frog pour aujourd’hui';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('frog:' || uid::text, 0));
  select h.* into chosen from public.habits h where h.id = p_habit_id and h.user_id = uid
    and (to_jsonb(h)->>'archived_at') is null;
  if not found then raise exception 'Cette habitude ne t’appartient pas'; end if;
  select * into previous from public.frog_days where user_id = uid and day = p_day for update;
  if previous.eaten_at is not null then
    if previous.habit_id = p_habit_id then return previous; end if;
    raise exception 'Ton Frog a déjà été mangé aujourd’hui';
  end if;
  select created_at into completion from public.checks
    where habit_id = p_habit_id and user_id = uid and day = p_day;
  insert into public.frog_days(user_id, day, habit_id, habit_name, eaten_at)
    values(uid, p_day, chosen.id, chosen.name, completion)
    on conflict(user_id, day) do update set
      habit_id = excluded.habit_id, habit_name = excluded.habit_name,
      selected_at = now(), eaten_at = excluded.eaten_at
    returning * into result;
  return result;
end $$;
revoke all on function public.choose_frog(uuid, date, text) from public, anon;
grant execute on function public.choose_frog(uuid, date, text) to authenticated;

-- Une coche = eaten ; décocher corrige le score. Pas de double comptage.
create or replace function public.sync_frog_check()
returns trigger language plpgsql security definer set search_path = '' as $$
declare uid uuid; hid uuid; d date;
begin
  if tg_op = 'DELETE' then uid := old.user_id; hid := old.habit_id; d := old.day;
  else uid := new.user_id; hid := new.habit_id; d := new.day; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('frog:' || uid::text, 0));
  if tg_op = 'DELETE' then
    update public.frog_days set eaten_at = null where user_id = uid and habit_id = hid and day = d;
    return old;
  else
    update public.frog_days set eaten_at = new.created_at where user_id = uid and habit_id = hid and day = d;
    return new;
  end if;
end $$;
revoke all on function public.sync_frog_check() from public, anon, authenticated;
drop trigger if exists frog_check_sync on public.checks;
create trigger frog_check_sync after insert or delete on public.checks
  for each row execute function public.sync_frog_check();

-- Détacher l'archive AVANT la suppression en cascade des coches.
create or replace function public.preserve_frog_history()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.frog_days set habit_id = null, habit_name = old.name where habit_id = old.id;
  return old;
end $$;
revoke all on function public.preserve_frog_history() from public, anon, authenticated;
drop trigger if exists frog_preserve_history on public.habits;
create trigger frog_preserve_history before delete on public.habits
  for each row execute function public.preserve_frog_history();

-- Agrégation serveur : le total reste exact au-delà des limites de pagination et de 400 jours.
create or replace function public.frog_stats(p_day date)
returns table(user_id uuid, eaten_total bigint, eaten_30 bigint, chosen_30 bigint)
language sql stable security invoker set search_path = '' as $$
  select f.user_id,
    count(*) filter (where f.eaten_at is not null),
    count(*) filter (where f.eaten_at is not null and f.day between p_day - 29 and p_day),
    count(*) filter (where f.day between p_day - 29 and p_day)
  from public.frog_days f where f.day <= p_day group by f.user_id;
$$;
revoke all on function public.frog_stats(date) from public, anon;
grant execute on function public.frog_stats(date) to authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'frog_days') then
    alter publication supabase_realtime add table public.frog_days;
  end if;
end $$;
notify pgrst, 'reload schema';
commit;

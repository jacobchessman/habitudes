-- Exécuter après frog.sql. Fuseau commun au groupe : America/Toronto.
-- Les XP sont recalculés depuis les données, jamais fournis par le navigateur.
begin;
create table if not exists public.achievement_awards (
 user_id uuid references auth.users on delete cascade,
 achievement text not null, earned_on date not null,
 primary key(user_id,achievement)
);
create table if not exists public.gamification_profiles (
 user_id uuid primary key references auth.users on delete cascade,
 peak_xp bigint not null default 0,
 pinned text[] not null default '{}', check(cardinality(pinned)<=3)
);
alter table public.achievement_awards enable row level security;
alter table public.gamification_profiles enable row level security;
revoke all on public.achievement_awards,public.gamification_profiles from anon,authenticated;
grant select on public.achievement_awards,public.gamification_profiles to authenticated;
drop policy if exists "lecture achievements" on public.achievement_awards;
create policy "lecture achievements" on public.achievement_awards for select to authenticated using(true);
drop policy if exists "lecture rangs" on public.gamification_profiles;
create policy "lecture rangs" on public.gamification_profiles for select to authenticated using(true);
create index if not exists checks_user_day_idx on public.checks(user_id,day);

create or replace function public.gamification_user(uid uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 today date := (now() at time zone 'America/Toronto')::date;
 week_start date := date_trunc('week',now() at time zone 'America/Toronto')::date;
 month_start date := date_trunc('month',now() at time zone 'America/Toronto')::date;
 r record; a record; d date; prev date; prev_frog date; prev_perfect date;
 n bigint:=0; frogs bigint:=0; xp bigint:=0; weekly bigint:=0; monthly bigint:=0; last_week bigint:=0;
 run int:=0; frog_run int:=0; perfect_run int:=0;
 best_run int:=0; best_frog int:=0; best_perfect int:=0;
 dates jsonb:='{}'; awards jsonb; pin text[]; peak bigint; values_now jsonb;
 current_run int:=0; current_frog int:=0; current_perfect int:=0;
 today_done int:=0; today_total int:=0; comeback_ready boolean:=false;
begin
 -- Sérialise les calculs et les mises à jour de badges d'une même personne.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('gamification:'||uid::text,0));
 for r in
  with c as (select day,count(*)::int done from public.checks where user_id=uid and day<=today group by day),
  f as (select day,1 frog from public.frog_days where user_id=uid and eaten_at is not null and day<=today),
  days as (select day from c union select day from f)
  select days.day,coalesce(c.done,0) done,coalesce(f.frog,0) frog,
   (select count(*)::int from public.habits h where h.user_id=uid and
    ((h.created_at at time zone 'America/Toronto')::date<=days.day and
      ((to_jsonb(h)->>'archived_at') is null or ((to_jsonb(h)->>'archived_at')::timestamptz at time zone 'America/Toronto')::date>days.day)
    or exists(select 1 from public.checks ck where ck.user_id=uid and ck.habit_id=h.id and ck.day=days.day))) total
  from days left join c using(day) left join f using(day) order by days.day
 loop
  d:=r.day; n:=n+r.done; frogs:=frogs+r.frog; xp:=xp+r.done+r.frog;
  if d>=week_start then weekly:=weekly+r.done+r.frog; end if;
  if d>=month_start then monthly:=monthly+r.done+r.frog; end if;
  if d>=week_start-7 and d<week_start then last_week:=last_week+r.done+r.frog; end if;
  if r.done>0 then
   if prev is not null and d-prev>=4 and not dates?'comeback' then dates:=dates||jsonb_build_object('comeback',d); end if;
   run:=case when d=prev+1 then run+1 else 1 end; prev:=d; best_run:=greatest(best_run,run);
  end if;
  if r.frog>0 then frog_run:=case when d=prev_frog+1 then frog_run+1 else 1 end; prev_frog:=d; best_frog:=greatest(best_frog,frog_run); end if;
  if r.total>0 and r.done=r.total then
   perfect_run:=case when d=prev_perfect+1 then perfect_run+1 else 1 end; prev_perfect:=d; best_perfect:=greatest(best_perfect,perfect_run);
   if not dates?'clean' then dates:=dates||jsonb_build_object('clean',d); end if;
  end if;
  if d=today then today_done:=r.done; today_total:=r.total; end if;
  for a in select * from (values
    ('first',n>=1),('fire',run>=7),('showing',run>=30),('century',n>=100),
    ('perfect',perfect_run>=7),('bite',frogs>=1),('eater',frogs>=10),('hunter',frogs>=50),
    ('king',frogs>=100),('excuses',frog_run>=7)
  ) as goals(id,met) loop
    if a.met and not dates?a.id then dates:=dates||jsonb_build_object(a.id,d); end if;
  end loop;
 end loop;
 if prev>=today-1 then current_run:=run; end if;
 if prev_frog>=today-1 then current_frog:=frog_run; end if;
 if prev_perfect>=today-1 then current_perfect:=perfect_run; end if;
 comeback_ready:=prev is not null and today-prev>=4;
 if today_total=0 then select count(*) into today_total from public.habits h where h.user_id=uid and (to_jsonb(h)->>'archived_at') is null; end if;
 insert into public.achievement_awards(user_id,achievement,earned_on)
 select uid,key,value::date from jsonb_each_text(dates)
 on conflict(user_id,achievement) do update set earned_on=least(achievement_awards.earned_on,excluded.earned_on)
 where excluded.earned_on<achievement_awards.earned_on;
 insert into public.gamification_profiles(user_id,peak_xp) values(uid,xp)
 on conflict(user_id) do update set peak_xp=excluded.peak_xp where gamification_profiles.peak_xp<excluded.peak_xp;
 select peak_xp,pinned into peak,pin from public.gamification_profiles where user_id=uid;
 select coalesce(jsonb_object_agg(achievement,earned_on),'{}') into awards from public.achievement_awards where user_id=uid;
 values_now:=jsonb_build_object('first',least(n,1),'clean',today_done,'fire',current_run,'showing',current_run,
 'century',n,'perfect',current_perfect,'bite',frogs,'eater',frogs,'hunter',frogs,'king',frogs,'excuses',current_frog,'comeback',0);
 return jsonb_build_object('user_id',uid,'xp',xp,'week',weekly,'month',monthly,'previous_week',last_week,
 'peak_xp',peak,'checks',n,'frogs',frogs,'values',values_now,'awards',awards,'pinned',pin,
 'best_run',best_run,'best_frog',best_frog,'best_perfect',best_perfect,'today_total',today_total,
 'comeback_ready',comeback_ready);
end $$;
revoke all on function public.gamification_user(uuid) from public,anon,authenticated;

create or replace function public.gamification_snapshot()
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb:='[]'; p record;
begin
 if auth.uid() is null then raise exception 'Connexion requise'; end if;
 -- Ordre stable pour les verrous lors d'appels simultanés.
 for p in select id from public.profiles order by id loop
  result:=result||jsonb_build_array(public.gamification_user(p.id));
 end loop;
 return result;
end $$;
revoke all on function public.gamification_snapshot() from public,anon;
grant execute on function public.gamification_snapshot() to authenticated;

create or replace function public.pin_achievements(p_ids text[])
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'Connexion requise'; end if;
 perform public.gamification_user(uid);
 if p_ids is null or cardinality(p_ids)>3 or cardinality(p_ids)<>(select count(distinct x) from unnest(p_ids) x)
 or exists(select 1 from unnest(p_ids) x where x is null or not exists(select 1 from public.achievement_awards where user_id=uid and achievement=x)) then
 raise exception 'Choisis au maximum trois badges débloqués'; end if;
 update public.gamification_profiles set pinned=p_ids where user_id=uid;
end $$;
revoke all on function public.pin_achievements(text[]) from public,anon;
grant execute on function public.pin_achievements(text[]) to authenticated;
-- Enregistre les badges immédiatement, même si l'application est fermée après la coche.
create or replace function public.sync_gamification()
returns trigger language plpgsql security definer set search_path='' as $$
declare uid uuid;
begin
 uid:=case when tg_op='DELETE' then old.user_id else new.user_id end;
 if exists(select 1 from auth.users where id=uid) then perform public.gamification_user(uid); end if;
 return null;
end $$;
revoke all on function public.sync_gamification() from public,anon,authenticated;
drop trigger if exists zz_gamification_check on public.checks;
create trigger zz_gamification_check after insert or delete on public.checks for each row execute function public.sync_gamification();
drop trigger if exists zz_gamification_frog on public.frog_days;
create trigger zz_gamification_frog after insert or update or delete on public.frog_days for each row execute function public.sync_gamification();
notify pgrst,'reload schema';
commit;

-- Petites notes liées aux habitudes complétées. Réexécutable.
begin;
create table if not exists public.completion_notes (
 habit_id uuid not null,
 day date not null,
 user_id uuid not null references auth.users on delete cascade,
 body text not null check(char_length(body) between 1 and 60 and body=btrim(body)),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 primary key(habit_id,day),
 foreign key(habit_id,day) references public.checks(habit_id,day) on delete cascade
);
create index if not exists completion_notes_recent_idx on public.completion_notes(created_at desc);
alter table public.completion_notes enable row level security;
revoke all on public.completion_notes from public,anon,authenticated;
grant select on public.completion_notes to authenticated;
drop policy if exists "lecture notes du groupe" on public.completion_notes;
create policy "lecture notes du groupe" on public.completion_notes for select to authenticated using(true);
create or replace function public.set_completion_note(p_habit_id uuid,p_day date,p_body text)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); owner_id uuid; clean text;
begin
 if uid is null then raise exception 'Connexion requise'; end if;
 -- Verrouille la coche : une suppression simultanée ne laisse jamais de note orpheline.
 select user_id into owner_id from public.checks where habit_id=p_habit_id and day=p_day for update;
 if owner_id is null or owner_id<>uid then raise exception 'Tu peux écrire seulement sur tes habitudes complétées'; end if;
 clean:=btrim(regexp_replace(coalesce(p_body,''),'[[:space:]]+',' ','g'));
 if clean='' then delete from public.completion_notes where habit_id=p_habit_id and day=p_day and user_id=uid;return;end if;
 if p_day<>(now() at time zone 'America/Toronto')::date then raise exception 'Tu peux écrire ou modifier une note seulement le jour de la coche';end if;
 if char_length(clean)>60 then raise exception 'Ta note doit contenir au maximum 60 caractères';end if;
 insert into public.completion_notes(habit_id,day,user_id,body) values(p_habit_id,p_day,uid,clean)
 on conflict(habit_id,day) do update set body=excluded.body,updated_at=now();
end $$;
revoke all on function public.set_completion_note(uuid,date,text) from public,anon;
grant execute on function public.set_completion_note(uuid,date,text) to authenticated;
do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='completion_notes') then
 alter publication supabase_realtime add table public.completion_notes;
 end if;
end $$;
notify pgrst,'reload schema';
commit;

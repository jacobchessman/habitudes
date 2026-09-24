-- Chat du groupe: tout le monde lit, chacun écrit et retire seulement ses messages. En direct via Realtime.
create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_recent on public.chat_messages (created_at desc);
alter table public.chat_messages enable row level security;
drop policy if exists "chat lecture" on public.chat_messages;
create policy "chat lecture" on public.chat_messages for select to authenticated using (true);
drop policy if exists "chat écrire" on public.chat_messages;
create policy "chat écrire" on public.chat_messages for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "chat retirer" on public.chat_messages;
create policy "chat retirer" on public.chat_messages for delete to authenticated using (user_id = auth.uid());
-- Pas de modification après envoi (pas de règle update), et l'heure vient du serveur.
create or replace function public.chat_maintenant() returns trigger language plpgsql as $$
begin new.created_at := now(); new.user_id := auth.uid(); return new; end $$;
drop trigger if exists chat_maintenant on public.chat_messages;
create trigger chat_maintenant before insert on public.chat_messages for each row execute function public.chat_maintenant();
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'chat_messages') then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;
select 'ok' as resultat;

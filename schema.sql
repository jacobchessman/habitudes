-- Habitudes: schéma + règles de sécurité + temps réel.
-- Tout le monde (connecté) LIT tout; chacun n'ÉCRIT que ses propres lignes.

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null
);

create table if not exists public.habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.checks (
  habit_id uuid not null references public.habits on delete cascade,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  day date not null,
  created_at timestamptz not null default now(),
  primary key (habit_id, day)
);

alter table public.profiles enable row level security;
alter table public.habits   enable row level security;
alter table public.checks   enable row level security;

create policy "lecture profils"  on public.profiles for select to authenticated using (true);
create policy "mon profil"       on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "maj mon profil"   on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "lecture habitudes" on public.habits for select to authenticated using (true);
create policy "ajout habitude"    on public.habits for insert to authenticated with check (user_id = auth.uid());
create policy "maj habitude"      on public.habits for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "retrait habitude"  on public.habits for delete to authenticated using (user_id = auth.uid());

create policy "lecture cochés" on public.checks for select to authenticated using (true);
create policy "cocher" on public.checks for insert to authenticated with check (
  user_id = auth.uid()
  and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
);
create policy "décocher" on public.checks for delete to authenticated using (user_id = auth.uid());

alter publication supabase_realtime add table public.profiles, public.habits, public.checks;

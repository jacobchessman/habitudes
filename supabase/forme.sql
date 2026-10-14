-- Forme: gym, séries, alimentation, sommeil, créatine.
-- PRIVÉ: contrairement aux habitudes, personne d'autre ne lit ces lignes (lecture ET écriture = soi seulement).

create table if not exists public.fit_goals (
  user_id uuid primary key default auth.uid() references auth.users on delete cascade,
  kcal int not null default 2450 check (kcal between 800 and 8000),
  protein int not null default 140 check (protein between 0 and 600),
  carbs int not null default 315 check (carbs between 0 and 1500),
  fat int not null default 70 check (fat between 0 and 500),
  sleep_h numeric(3,1) not null default 7.5 check (sleep_h between 0 and 14),
  water_l numeric(3,1) not null default 3 check (water_l between 0 and 10),
  steps int not null default 7000 check (steps between 0 and 60000),
  unit text not null default 'lb' check (unit in ('lb','kg')),
  updated_at timestamptz not null default now()
);

create table if not exists public.fit_days (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  day date not null,
  kind text check (kind in ('gym','repos')),
  sleep_h numeric(3,1) check (sleep_h between 0 and 24),
  creatine boolean not null default false,
  water_l numeric(3,1) check (water_l between 0 and 20),
  steps int check (steps between 0 and 200000),
  weight numeric(5,1) check (weight between 0 and 1000),
  waist numeric(5,1) check (waist between 0 and 300),
  note text check (char_length(note) <= 1000),
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);

-- Aliments favoris: un tap = une entrée dans le journal.
create table if not exists public.fit_foods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  kcal int not null check (kcal between 0 and 10000),
  protein numeric(5,1) not null default 0 check (protein between 0 and 1000),
  carbs numeric(5,1) not null default 0 check (carbs between 0 and 2000),
  fat numeric(5,1) not null default 0 check (fat between 0 and 1000),
  sort int not null default 0,
  created_at timestamptz not null default now()
);

-- Journal alimentaire: valeurs pour UNE portion, multipliées par qty.
create table if not exists public.fit_meals (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  day date not null,
  name text not null check (char_length(name) between 1 and 80),
  qty numeric(4,2) not null default 1 check (qty > 0 and qty <= 20),
  kcal int not null check (kcal between 0 and 10000),
  protein numeric(5,1) not null default 0 check (protein between 0 and 1000),
  carbs numeric(5,1) not null default 0 check (carbs between 0 and 2000),
  fat numeric(5,1) not null default 0 check (fat between 0 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists fit_meals_user_day on public.fit_meals (user_id, day);

-- Une ligne = une série.
create table if not exists public.fit_sets (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  day date not null,
  exercise text not null check (char_length(exercise) between 1 and 60),
  weight numeric(6,1) not null check (weight between 0 and 2000),
  reps int not null check (reps between 1 and 100),
  created_at timestamptz not null default now()
);
create index if not exists fit_sets_user_day on public.fit_sets (user_id, day);
create index if not exists fit_sets_user_ex on public.fit_sets (user_id, exercise, day);

do $$
declare t text;
begin
  foreach t in array array['fit_goals','fit_days','fit_foods','fit_meals','fit_sets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "moi seulement" on public.%I', t);
    execute format('create policy "moi seulement" on public.%I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- Rappels Forme (2 par jour), lus par la fonction push: seulement ce qui n'est pas encore fait aujourd'hui.
alter table public.fit_goals
  add column if not exists notif boolean not null default true,
  add column if not exists notif_am int not null default 8 check (notif_am between 5 and 12),
  add column if not exists notif_pm int not null default 19 check (notif_pm between 13 and 23),
  add column if not exists gym_days int[] not null default '{1,3,5}'; -- 0 = dimanche … 6 = samedi

-- Pesée du soir (14 oct. 2026).
alter table public.fit_days add column if not exists weight_pm numeric(5,1) check (weight_pm between 0 and 1000);

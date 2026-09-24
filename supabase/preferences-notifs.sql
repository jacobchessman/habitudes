-- Centre de notifications: chacun choisit ce qu'il reçoit et à quelle heure.
create table if not exists public.notif_prefs (
  user_id uuid primary key default auth.uid() references auth.users on delete cascade,
  reminder boolean not null default true,       -- rappel du soir s'il reste des habitudes
  reminder_hour int not null default 21 check (reminder_hour between 17 and 23),
  streak boolean not null default true,         -- série en danger (envoyée à l'heure du rappel)
  perfect boolean not null default true,        -- quelqu'un du groupe finit sa journée
  updated_at timestamptz not null default now()
);
alter table public.notif_prefs enable row level security;
create policy "mes préférences (lecture)" on public.notif_prefs for select to authenticated using (user_id = auth.uid());
create policy "mes préférences (ajout)"   on public.notif_prefs for insert to authenticated with check (user_id = auth.uid());
create policy "mes préférences (maj)"     on public.notif_prefs for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Historique de ce que chacun a reçu (écrit par la fonction, lu par son destinataire).
create table if not exists public.notif_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  kind text not null,
  title text not null,
  body text,
  sent_at timestamptz not null default now()
);
create index if not exists notif_history_user on public.notif_history (user_id, sent_at desc);
alter table public.notif_history enable row level security;
revoke insert, update, delete on public.notif_history from anon, authenticated;
create policy "mon historique" on public.notif_history for select to authenticated using (user_id = auth.uid());

select 'ok' as resultat;

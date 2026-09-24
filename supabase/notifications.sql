-- Notifications Web Push: abonnements, config privée, journal anti-doublon, trigger et tâche horaire.
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- Les appareils de chacun. Chacun ne voit et ne gère que les siens.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
create policy "mes appareils (lecture)" on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
create policy "mes appareils (ajout)"   on public.push_subscriptions for insert to authenticated with check (user_id = auth.uid());
create policy "mes appareils (maj)"     on public.push_subscriptions for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "mes appareils (retrait)" on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());

-- Clés VAPID et jeton interne: RLS sans aucune règle = personne n'y touche sauf la fonction (service role).
create table if not exists public.push_config (
  id int primary key check (id = 1),
  vapid_public text,
  vapid_private text,
  token text not null
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (id, token) values (1, encode(extensions.gen_random_bytes(24), 'hex')) on conflict (id) do nothing;

-- Une notification par personne, par jour et par sorte.
create table if not exists public.push_log (
  user_id uuid not null references auth.users on delete cascade,
  day date not null,
  kind text not null,
  primary key (user_id, day, kind)
);
alter table public.push_log enable row level security;
revoke all on public.push_log from anon, authenticated;

-- Chaque coché prévient la fonction, qui décide s'il y a une journée parfaite à annoncer.
create or replace function public.notify_check() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform net.http_post(
    url := 'https://czsbliefehpiazhnetul.supabase.co/functions/v1/push',
    body := jsonb_build_object('action', 'check', 'user_id', new.user_id, 'day', new.day),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-token', (select token from public.push_config where id = 1))
  );
  return new;
end $$;
revoke execute on function public.notify_check() from public, anon, authenticated;
drop trigger if exists checks_notify on public.checks;
create trigger checks_notify after insert on public.checks for each row execute function public.notify_check();

-- Chaque heure; la fonction n'envoie qu'à 21 h, heure de Montréal (suit l'heure d'été toute seule).
select cron.schedule('rappel-habitudes', '0 * * * *', $$
  select net.http_post(
    url := 'https://czsbliefehpiazhnetul.supabase.co/functions/v1/push',
    body := '{"action":"cron"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-token', (select token from public.push_config where id = 1))
  )
$$);

select 'ok' as resultat;

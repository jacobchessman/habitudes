-- Le passé est figé: on ne coche et ne décoche que la journée en cours (heure de Montréal).
-- Une habitude retirée est archivée, jamais effacée: son historique reste dans les stats.

create or replace function public.aujourdhui() returns date
language sql stable as $$ select (now() at time zone 'America/Toronto')::date $$;

alter table public.habits add column if not exists archived_at timestamptz;

drop policy if exists "cocher" on public.checks;
create policy "cocher" on public.checks for insert to authenticated with check (
  user_id = auth.uid()
  and day = public.aujourdhui()
  and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid() and h.archived_at is null)
);

drop policy if exists "décocher" on public.checks;
create policy "décocher" on public.checks for delete to authenticated using (
  user_id = auth.uid() and day = public.aujourdhui()
);

-- Plus de suppression d'habitude (elle emporterait son historique): on archive à la place.
drop policy if exists "retrait habitude" on public.habits;

-- On peut renommer ou archiver, mais pas antidater: created_at ne bouge pas.
create or replace function public.habits_fige() returns trigger language plpgsql as $$
begin
  new.created_at := old.created_at;
  new.user_id := old.user_id;
  return new;
end $$;
drop trigger if exists habits_fige on public.habits;
create trigger habits_fige before update on public.habits for each row execute function public.habits_fige();

-- Une nouvelle habitude commence maintenant, pas dans le passé.
create or replace function public.habits_maintenant() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.archived_at := null;
  return new;
end $$;
drop trigger if exists habits_maintenant on public.habits;
create trigger habits_maintenant before insert on public.habits for each row execute function public.habits_maintenant();

-- L'heure d'un coché est celle du serveur (les badges Lève-tôt / Oiseau de nuit en dépendent).
create or replace function public.checks_maintenant() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  return new;
end $$;
drop trigger if exists checks_maintenant on public.checks;
create trigger checks_maintenant before insert on public.checks for each row execute function public.checks_maintenant();

select 'ok' as resultat, public.aujourdhui() as aujourdhui;

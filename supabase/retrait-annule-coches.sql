-- Retirer une habitude annule ses cochés des jours encore modifiables (aujourd'hui et hier).
-- Sinon: créer, cocher, retirer, recommencer gonflait le compte du jour (ex.: 5/8 alors que 2 cochés visibles).
-- L'historique plus ancien reste intact.
create or replace function public.habits_retrait_coches() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.archived_at is not null and old.archived_at is null then
    delete from public.checks where habit_id = new.id and day >= public.aujourdhui() - 1;
  end if;
  return new;
end $$;
revoke execute on function public.habits_retrait_coches() from public, anon, authenticated;
drop trigger if exists habits_retrait_coches on public.habits;
create trigger habits_retrait_coches after update of archived_at on public.habits
  for each row execute function public.habits_retrait_coches();

-- Nettoyage: cochés d'aujourd'hui et d'hier sur des habitudes déjà retirées.
with supprimes as (
  delete from public.checks c using public.habits h
  where c.habit_id = h.id and h.archived_at is not null and c.day >= public.aujourdhui() - 1
  returning c.habit_id
)
select count(*) as coches_retires from supprimes;

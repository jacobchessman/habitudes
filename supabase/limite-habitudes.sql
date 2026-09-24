-- Maximum 5 habitudes en cours par personne (les archivées ne comptent pas).
-- Vérifié par la base: impossible à contourner depuis le navigateur. Les personnes déjà au-delà gardent
-- leurs habitudes, mais ne peuvent plus en ajouter ni en désarchiver tant qu'elles dépassent.
create or replace function public.habits_maximum() returns trigger language plpgsql as $$
begin
  if new.archived_at is null and (tg_op = 'INSERT' or old.archived_at is not null) then
    if (select count(*) from public.habits where user_id = new.user_id and archived_at is null and id <> new.id) >= 5 then
      raise exception 'Maximum 5 habitudes. Retire-en une avant d''en ajouter une autre.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists habits_maximum on public.habits;
create trigger habits_maximum before insert or update of archived_at on public.habits
  for each row execute function public.habits_maximum();

select p.name, count(h.*) filter (where h.archived_at is null) as en_cours
from public.profiles p left join public.habits h on h.user_id = p.id group by p.name order by 2 desc;

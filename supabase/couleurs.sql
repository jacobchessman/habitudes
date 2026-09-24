-- Chaque personne garde sa couleur pour toujours (avant: couleur selon l'ordre des id, qui se décalait à chaque inscription).
alter table public.profiles add column if not exists color int check (color between 0 and 5);

-- Couleurs actuelles: Jacob en vert (demandé), les autres gardent celle qu'ils avaient à l'écran.
update public.profiles set color = 0 where name = 'Jacob';
update public.profiles set color = 2 where name = 'Vincent';
update public.profiles set color = 1 where name = 'Antoine';
update public.profiles set color = 3 where name = 'Alex' and color is null;

-- Nouvelle personne: la première couleur libre (sinon, on recommence la palette).
create or replace function public.profiles_couleur() returns trigger language plpgsql as $$
begin
  if new.color is null then
    select c into new.color from generate_series(0, 5) c
      where c not in (select color from public.profiles where color is not null) order by c limit 1;
    if new.color is null then new.color := (select count(*) from public.profiles) % 6; end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_couleur on public.profiles;
create trigger profiles_couleur before insert on public.profiles for each row execute function public.profiles_couleur();

-- Ceux qui n'ont pas encore de couleur en reçoivent une libre.
update public.profiles p set color = x.c from (
  select id, (select c from generate_series(0, 5) c where c not in (select color from public.profiles where color is not null) order by c limit 1) as c
  from public.profiles where color is null order by id limit 1
) x where p.id = x.id;

select name, color from public.profiles order by color;

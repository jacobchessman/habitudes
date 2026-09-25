-- Boutique: articles cosmétiques (chapeau, couleur du nom, emoji du nom, cadre de carte), achetés avec l'or.
-- Et le casino ne prend une mise que si toutes les habitudes du jour sont cochées.
begin;
create or replace function public.shop_catalog() returns table (id text, category text, name text, value text, price int)
language sql immutable set search_path = '' as $$
  select * from (values
    ('hat-cap',     'hat',   'Casquette',        '🧢',   40),
    ('hat-straw',   'hat',   'Chapeau de paille','👒',   60),
    ('hat-helmet',  'hat',   'Casque',           '⛑️',   70),
    ('hat-grad',    'hat',   'Mortier',          '🎓',   80),
    ('hat-top',     'hat',   'Haut-de-forme',    '🎩',  150),
    ('hat-crown',   'hat',   'Couronne',         '👑',  400),
    ('col-rouge',   'color', 'Rouge',            'rouge', 60),
    ('col-glace',   'color', 'Glace',            'glace',120),
    ('col-neon',    'color', 'Néon',             'neon', 150),
    ('col-or',      'color', 'Or',               'or',   250),
    ('col-feu',     'color', 'Feu',              'feu',  300),
    ('col-arc',     'color', 'Arc-en-ciel',      'arc',  500),
    ('emo-fire',    'emoji', 'Feu',              '🔥',   30),
    ('emo-muscle',  'emoji', 'Muscle',           '💪',   30),
    ('emo-cool',    'emoji', 'Cool',             '😎',   40),
    ('emo-frog',    'emoji', 'Frog',             '🐸',   40),
    ('emo-gorilla', 'emoji', 'Gorille',          '🦍',   60),
    ('emo-skull',   'emoji', 'Crâne',            '💀',   60),
    ('emo-rocket',  'emoji', 'Fusée',            '🚀',   80),
    ('emo-crown',   'emoji', 'Couronne',         '👑',  150),
    ('emo-goat',    'emoji', 'GOAT',             '🐐',  200),
    ('fr-neon',     'frame', 'Néon',             'neon', 150),
    ('fr-or',       'frame', 'Doré',             'or',   250),
    ('fr-flammes',  'frame', 'Flammes',          'flammes', 300),
    ('fr-galaxie',  'frame', 'Galaxie',          'galaxie', 400)
  ) as c(id, category, name, value, price)
$$;
grant execute on function public.shop_catalog() to authenticated;

create table if not exists public.inventory (
  user_id uuid not null references auth.users on delete cascade,
  item_id text not null,
  bought_at timestamptz not null default now(),
  primary key (user_id, item_id)
);
alter table public.inventory enable row level security;
revoke all on public.inventory from anon, authenticated;
grant select on public.inventory to authenticated;
drop policy if exists "mon inventaire" on public.inventory;
create policy "mon inventaire" on public.inventory for select to authenticated using (user_id = auth.uid());

-- Ce que chacun porte: visible par tout le groupe, modifiable seulement par les fonctions.
create table if not exists public.cosmetics (
  user_id uuid primary key references auth.users on delete cascade,
  hat text, color text, emoji text, frame text,
  updated_at timestamptz not null default now()
);
alter table public.cosmetics enable row level security;
revoke all on public.cosmetics from anon, authenticated;
grant select on public.cosmetics to authenticated;
drop policy if exists "cosmétiques visibles" on public.cosmetics;
create policy "cosmétiques visibles" on public.cosmetics for select to authenticated using (true);

create or replace function public.shop_set(uid uuid, p_cat text, p_item text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.cosmetics (user_id) values (uid) on conflict (user_id) do nothing;
  update public.cosmetics set
    hat   = case when p_cat = 'hat'   then p_item else hat end,
    color = case when p_cat = 'color' then p_item else color end,
    emoji = case when p_cat = 'emoji' then p_item else emoji end,
    frame = case when p_cat = 'frame' then p_item else frame end,
    updated_at = now()
  where user_id = uid;
end $$;
revoke all on function public.shop_set(uuid, text, text) from public, anon, authenticated;

create or replace function public.shop_buy(p_item text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); it record;
begin
  if uid is null then raise exception 'Connexion requise'; end if;
  select * into it from public.shop_catalog() c where c.id = p_item;
  if not found then raise exception 'Article inconnu'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('or:' || uid::text, 0));
  if exists (select 1 from public.inventory where user_id = uid and item_id = p_item) then raise exception 'Tu l''as déjà'; end if;
  if public.gold_balance(uid) < it.price then raise exception 'Pas assez d''or'; end if;
  insert into public.gold_ledger (user_id, delta, reason, meta) values (uid, -it.price, 'boutique · ' || it.name, jsonb_build_object('article', p_item));
  insert into public.inventory (user_id, item_id) values (uid, p_item);
  perform public.shop_set(uid, it.category, p_item); -- on l'enfile tout de suite
  return jsonb_build_object('balance', public.gold_balance(uid));
end $$;

create or replace function public.shop_equip(p_cat text, p_item text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Connexion requise'; end if;
  if p_cat not in ('hat', 'color', 'emoji', 'frame') then raise exception 'Catégorie inconnue'; end if;
  if p_item is not null and not exists (
    select 1 from public.inventory i join public.shop_catalog() c on c.id = i.item_id
    where i.user_id = uid and i.item_id = p_item and c.category = p_cat) then
    raise exception 'Tu ne possèdes pas cet article';
  end if;
  perform public.shop_set(uid, p_cat, p_item);
end $$;
revoke all on function public.shop_buy(text), public.shop_equip(text, text) from public, anon;
grant execute on function public.shop_buy(text), public.shop_equip(text, text) to authenticated;

-- Casino: fermé tant que toutes les habitudes du jour ne sont pas cochées.
create or replace function public.casino_mise(uid uuid, p_bet int, p_jeu text) returns void
language plpgsql security definer set search_path = '' as $$
declare g jsonb;
begin
  if uid is null then raise exception 'Connexion requise'; end if;
  if p_bet is null or p_bet < 1 or p_bet > 1000 then raise exception 'Mise entre 1 et 1000 pièces'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('or:' || uid::text, 0));
  g := public.gamification_user(uid);
  if coalesce((g->>'today_total')::int, 0) = 0 or coalesce((g->'values'->>'clean')::int, 0) < (g->>'today_total')::int then
    raise exception 'Le casino ouvre quand toutes tes habitudes du jour sont cochées';
  end if;
  if public.gold_balance(uid) < p_bet then raise exception 'Pas assez d''or'; end if;
  insert into public.gold_ledger (user_id, delta, reason) values (uid, -p_bet, p_jeu || ' · mise');
end $$;
revoke all on function public.casino_mise(uuid, int, text) from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'cosmetics') then
    alter publication supabase_realtime add table public.cosmetics;
  end if;
end $$;
notify pgrst, 'reload schema';
commit;
select 'ok' as resultat, (select count(*) from public.shop_catalog()) as articles;

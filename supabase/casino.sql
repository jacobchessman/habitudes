-- Or et casino. Tout se joue sur le serveur: le navigateur ne choisit ni le résultat ni son solde.
-- Or = XP gagnés (1 XP = 1 pièce) + somme du grand livre (gains du casino, mises).
begin;
create table if not exists public.gold_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  delta bigint not null,
  reason text not null,
  meta jsonb,
  created_at timestamptz not null default now()
);
create index if not exists gold_ledger_user on public.gold_ledger (user_id, created_at desc);
alter table public.gold_ledger enable row level security;
revoke all on public.gold_ledger from anon, authenticated;
grant select on public.gold_ledger to authenticated;
drop policy if exists "mon or" on public.gold_ledger;
create policy "mon or" on public.gold_ledger for select to authenticated using (user_id = auth.uid());

create or replace function public.gold_balance(uid uuid) returns bigint
language sql security definer set search_path = '' as $$
  select coalesce((public.gamification_user(uid)->>'xp')::bigint, 0)
       + coalesce((select sum(delta) from public.gold_ledger where user_id = uid), 0)
$$;
revoke all on function public.gold_balance(uuid) from public, anon, authenticated;

create or replace function public.gold_me() returns bigint
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  return public.gold_balance(auth.uid());
end $$;
revoke all on function public.gold_me() from public, anon;
grant execute on function public.gold_me() to authenticated;

-- Retire la mise (vérifie le solde, une partie à la fois par personne).
create or replace function public.casino_mise(uid uuid, p_bet int, p_jeu text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if uid is null then raise exception 'Connexion requise'; end if;
  if p_bet is null or p_bet < 1 or p_bet > 1000 then raise exception 'Mise entre 1 et 1000 pièces'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('or:' || uid::text, 0));
  if public.gold_balance(uid) < p_bet then raise exception 'Pas assez d''or'; end if;
  insert into public.gold_ledger (user_id, delta, reason) values (uid, -p_bet, p_jeu || ' · mise');
end $$;
revoke all on function public.casino_mise(uuid, int, text) from public, anon, authenticated;

create or replace function public.casino_gain(uid uuid, p_amount int, p_reason text, p_meta jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into public.gold_ledger (user_id, delta, reason, meta) select uid, p_amount, p_reason, p_meta where p_amount > 0
$$;
revoke all on function public.casino_gain(uuid, int, text, jsonb) from public, anon, authenticated;

-- 🎰 Machine à sous: 3 rouleaux; paire = mise remboursée, trois pareils = multiplicateur (retour ~92 %).
create or replace function public.casino_slots(p_bet int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  syms text[] := array['🍒','🍋','🔔','⭐','💎','7️⃣'];
  w int[] := array[30,25,20,13,8,4];
  mult int[] := array[5,8,12,20,40,100];
  reels int[] := '{}'; r int; acc int; pay int := 0;
begin
  perform public.casino_mise(uid, p_bet, 'machine à sous');
  for i in 1..3 loop
    r := floor(random() * 100)::int; acc := 0;
    for j in 1..6 loop acc := acc + w[j]; if r < acc then reels := reels || j; exit; end if; end loop;
  end loop;
  if reels[1] = reels[2] and reels[2] = reels[3] then pay := p_bet * mult[reels[1]];
  elsif reels[1] = reels[2] or reels[2] = reels[3] or reels[1] = reels[3] then pay := p_bet;
  end if;
  perform public.casino_gain(uid, pay, 'machine à sous · gain', jsonb_build_object('rouleaux', reels));
  return jsonb_build_object('reels', to_jsonb(array[syms[reels[1]], syms[reels[2]], syms[reels[3]]]), 'bet', p_bet, 'payout', pay, 'balance', public.gold_balance(uid));
end $$;

-- 🎡 Roulette européenne (0 à 36).
create or replace function public.casino_roulette(p_bet int, p_type text, p_number int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); n int; couleur text; win boolean := false; mult int := 0; pay int := 0;
  rouges int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
begin
  if p_type is null or p_type not in ('rouge','noir','pair','impair','manque','passe','d1','d2','d3','numero') then raise exception 'Pari inconnu'; end if;
  if p_type = 'numero' and (p_number is null or p_number < 0 or p_number > 36) then raise exception 'Choisis un numéro de 0 à 36'; end if;
  perform public.casino_mise(uid, p_bet, 'roulette');
  n := floor(random() * 37)::int;
  couleur := case when n = 0 then 'vert' when n = any(rouges) then 'rouge' else 'noir' end;
  case p_type
    when 'rouge' then win := couleur = 'rouge'; mult := 2;
    when 'noir' then win := couleur = 'noir'; mult := 2;
    when 'pair' then win := n > 0 and n % 2 = 0; mult := 2;
    when 'impair' then win := n % 2 = 1; mult := 2;
    when 'manque' then win := n between 1 and 18; mult := 2;
    when 'passe' then win := n between 19 and 36; mult := 2;
    when 'd1' then win := n between 1 and 12; mult := 3;
    when 'd2' then win := n between 13 and 24; mult := 3;
    when 'd3' then win := n between 25 and 36; mult := 3;
    else win := n = p_number; mult := 36;
  end case;
  if win then pay := p_bet * mult; end if;
  perform public.casino_gain(uid, pay, 'roulette · gain', jsonb_build_object('numero', n, 'pari', p_type));
  return jsonb_build_object('number', n, 'color', couleur, 'win', win, 'bet', p_bet, 'payout', pay, 'balance', public.gold_balance(uid));
end $$;

-- 🃏 Blackjack: la main vit sur le serveur (la carte cachée du croupier n'est jamais envoyée avant la fin).
create table if not exists public.blackjack_hands (
  user_id uuid primary key references auth.users on delete cascade,
  bet int not null, deck int[] not null, player int[] not null, dealer int[] not null,
  status text not null, result text, payout int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.blackjack_hands enable row level security;
revoke all on public.blackjack_hands from anon, authenticated; -- aucune règle: personne ne lit le paquet

create or replace function public.bj_value(cards int[]) returns int
language plpgsql immutable set search_path = '' as $$
declare t int := 0; aces int := 0; c int; r int;
begin
  foreach c in array cards loop
    r := c % 13;                       -- 0 = As, 1..8 = 2..9, 9 = 10, 10..12 = J Q K
    if r = 0 then aces := aces + 1; t := t + 11;
    elsif r >= 9 then t := t + 10;
    else t := t + r + 1; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end $$;

create or replace function public.bj_view(h public.blackjack_hands) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare playing boolean := h.status = 'playing'; shown int[];
begin
  shown := case when playing then h.dealer[1:1] else h.dealer end;
  return jsonb_build_object('status', h.status, 'result', h.result, 'bet', h.bet, 'payout', h.payout,
    'player', to_jsonb(h.player), 'player_value', public.bj_value(h.player),
    'dealer', to_jsonb(shown), 'dealer_value', public.bj_value(shown), 'hidden', playing,
    'can_double', playing and cardinality(h.player) = 2, 'balance', public.gold_balance(h.user_id));
end $$;
revoke all on function public.bj_view(public.blackjack_hands) from public, anon, authenticated;

create or replace function public.bj_settle(uid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare h public.blackjack_hands; pv int; dv int; pay int := 0; res text;
begin
  select * into h from public.blackjack_hands where user_id = uid for update;
  pv := public.bj_value(h.player);
  if pv <= 21 then
    while public.bj_value(h.dealer) < 17 loop h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:]; end loop;
  end if;
  dv := public.bj_value(h.dealer);
  if pv > 21 then res := 'perdu';
  elsif dv > 21 or pv > dv then res := 'gagné'; pay := h.bet * 2;
  elsif pv = dv then res := 'égalité'; pay := h.bet;
  else res := 'perdu'; end if;
  perform public.casino_gain(uid, pay, 'blackjack · ' || res, null);
  update public.blackjack_hands set dealer = h.dealer, deck = h.deck, status = 'done', result = res, payout = pay, updated_at = now()
    where user_id = uid returning * into h;
  return public.bj_view(h);
end $$;
revoke all on function public.bj_settle(uuid) from public, anon, authenticated;

create or replace function public.bj_start(p_bet int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); h public.blackjack_hands; d int[]; pv int; dv int; pay int := 0; res text;
begin
  select * into h from public.blackjack_hands where user_id = uid;
  if found and h.status = 'playing' then return public.bj_view(h); end if;
  perform public.casino_mise(uid, p_bet, 'blackjack');
  d := array(select g from generate_series(0, 51) g order by random());
  insert into public.blackjack_hands (user_id, bet, deck, player, dealer, status, result, payout)
    values (uid, p_bet, d[5:], array[d[1], d[3]], array[d[2], d[4]], 'playing', null, 0)
    on conflict (user_id) do update set bet = excluded.bet, deck = excluded.deck, player = excluded.player, dealer = excluded.dealer,
      status = 'playing', result = null, payout = 0, updated_at = now()
    returning * into h;
  pv := public.bj_value(h.player); dv := public.bj_value(h.dealer);
  if pv = 21 or dv = 21 then
    if pv = 21 and dv = 21 then res := 'égalité'; pay := h.bet;
    elsif pv = 21 then res := 'blackjack!'; pay := (h.bet * 5) / 2;
    else res := 'perdu'; end if;
    perform public.casino_gain(uid, pay, 'blackjack · ' || res, null);
    update public.blackjack_hands set status = 'done', result = res, payout = pay, updated_at = now() where user_id = uid returning * into h;
  end if;
  return public.bj_view(h);
end $$;

create or replace function public.bj_action(p_action text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); h public.blackjack_hands;
begin
  if uid is null then raise exception 'Connexion requise'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('or:' || uid::text, 0));
  select * into h from public.blackjack_hands where user_id = uid for update;
  if not found or h.status <> 'playing' then raise exception 'Aucune main en cours'; end if;
  if p_action = 'hit' then
    h.player := h.player || h.deck[1]; h.deck := h.deck[2:];
    update public.blackjack_hands set player = h.player, deck = h.deck, updated_at = now() where user_id = uid;
    if public.bj_value(h.player) >= 21 then return public.bj_settle(uid); end if;
    return public.bj_view(h);
  elsif p_action = 'stand' then
    return public.bj_settle(uid);
  elsif p_action = 'double' then
    if cardinality(h.player) <> 2 then raise exception 'On double seulement sur les 2 premières cartes'; end if;
    perform public.casino_mise(uid, h.bet, 'blackjack · double');
    h.player := h.player || h.deck[1]; h.deck := h.deck[2:];
    update public.blackjack_hands set bet = h.bet * 2, player = h.player, deck = h.deck, updated_at = now() where user_id = uid;
    return public.bj_settle(uid);
  else raise exception 'Action inconnue'; end if;
end $$;

create or replace function public.bj_current() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare h public.blackjack_hands;
begin
  select * into h from public.blackjack_hands where user_id = auth.uid() and status = 'playing';
  if not found then return null; end if;
  return public.bj_view(h);
end $$;

revoke all on function public.casino_slots(int), public.casino_roulette(int, text, int), public.bj_start(int), public.bj_action(text), public.bj_current() from public, anon;
grant execute on function public.casino_slots(int), public.casino_roulette(int, text, int), public.bj_start(int), public.bj_action(text), public.bj_current() to authenticated;
notify pgrst, 'reload schema';
commit;
select 'ok' as resultat;

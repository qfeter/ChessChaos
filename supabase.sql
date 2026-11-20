-- ============================================================================
--  ШАХМАТЫ · РУЛЕТКА — база данных, версия 2
--  Запусти ВЕСЬ файл один раз: Supabase -> SQL Editor -> New query -> вставить -> Run.
--  Ничего не удаляет (кроме старых лишних правил доступа), можно запускать повторно.
--  Если в проекте уже стояла версия 1, она обновится на месте: монеты и покупки сохранятся.
-- ============================================================================

-- ---------- 1. профили ----------
create table if not exists public.profiles (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  nick     text not null,
  nick_key text not null unique,
  coins    integer not null default 50 check (coins >= 0),
  owned    text[]  not null default '{}',
  equip    text,
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists equip_q    text not null default 'q';
alter table public.profiles add column if not exists skin       text;
alter table public.profiles add column if not exists xp         integer not null default 0;
alter table public.profiles add column if not exists wins       integer not null default 0;
alter table public.profiles add column if not exists losses     integer not null default 0;
alter table public.profiles add column if not exists draws      integer not null default 0;
alter table public.profiles add column if not exists games      integer not null default 0;
alter table public.profiles add column if not exists last_seen  timestamptz;
alter table public.profiles add column if not exists last_claim timestamptz;
alter table public.profiles add column if not exists day        date;
alter table public.profiles add column if not exists day_coins  integer not null default 0;
alter table public.profiles alter column coins set default 50;

alter table public.profiles enable row level security;
drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select to authenticated using (auth.uid() = user_id);
create policy "profiles_update_own" on public.profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Игрок сам может менять ТОЛЬКО надетое (способность, фигура вместо ферзя, скин). Монеты, покупки, статистику меняют только функции ниже.
revoke insert, update, delete on public.profiles from anon, authenticated;
revoke all on public.profiles from anon;
grant select on public.profiles to authenticated;
grant update (equip, equip_q, skin) on public.profiles to authenticated;

create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare em text;
begin
  if tg_op = 'INSERT' then
    select email into em from auth.users where id = new.user_id;
    if em is distinct from ('u' || encode(convert_to(new.nick_key, 'UTF8'), 'hex') || '@fchess.app') then
      raise exception 'nick does not match account';
    end if;
  else
    new.nick := old.nick; new.nick_key := old.nick_key; new.user_id := old.user_id;
    -- надеть можно только то, что куплено
    if new.equip is not null and not (new.equip = any(new.owned)) then new.equip := old.equip; end if;
    if new.equip_q is null or (new.equip_q <> 'q' and not (new.equip_q = any(new.owned))) then new.equip_q := 'q'; end if;
    if new.skin is not null and not (new.skin = any(new.owned)) then new.skin := null; end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard_trg on public.profiles;
create trigger profiles_guard_trg before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- ---------- 2. админские способности (Hollow Purple) ----------
create table if not exists public.grants (
  nick      text primary key,              -- ник МАЛЕНЬКИМИ буквами
  abilities text[] not null default '{}'   -- например {purple}
);
alter table public.grants enable row level security;
drop policy if exists "grants_select_own_nick" on public.grants;
create policy "grants_select_own_nick" on public.grants for select to authenticated
  using (nick = (select p.nick_key from public.profiles p where p.user_id = auth.uid()));

-- ---------- 3. магазин ----------
create table if not exists public.shop_items (
  id          text primary key,             -- для скина это имя папки в хранилище skins
  kind        text not null check (kind in ('ability','queen','skin')),
  name        text not null,
  descr       text not null default '',
  price       integer not null check (price >= 0),
  sale_price  integer check (sale_price >= 0),   -- цена по акции
  sale_from   timestamptz,                       -- акция с (пусто = сразу)
  sale_until  timestamptz,                       -- акция до (пусто = бессрочно)
  avail_from  timestamptz,                       -- товар в продаже с
  avail_until timestamptz,                       -- товар в продаже до (временная продажа)
  active      boolean not null default true,     -- false = убрать из магазина
  sort        integer not null default 100,
  meta        jsonb   not null default '{}'::jsonb,   -- для скина {"ext":"png"}
  created_at  timestamptz not null default now()
);
alter table public.shop_items enable row level security;
revoke all on public.shop_items from anon, authenticated;

insert into public.shop_items (id, kind, name, descr, price, sort) values
('call', 'ability', 'Звонок маме', 'Мама звонит сопернику: у него −30 секунд на часах.', 60, 160),
('magic', 'ability', 'Фокус-покус', 'Случайная пешка врага исчезает в шляпе фокусника.', 150, 250),
('draft', 'ability', 'Сквозняк', 'Случайная фигура врага (не король) простужается и стоит 2 его хода.', 100, 200),
('jackpot', 'ability', 'Халява', 'Сразу получаешь ещё одну способность из рулетки.', 250, 350),
('clown', 'ability', 'Клоун-обмен', 'Твой ферзь и ферзь врага меняются местами.', 200, 300),
('mirror', 'ability', 'Зеркало', 'Получаешь копию последней способности, которую использовал враг (кроме Зеркала).', 350, 450),
('pirate', 'ability', 'Пират', 'Крадёшь случайную способность из запаса врага.', 450, 550),
('dynamite', 'ability', 'Динамит', 'Нажми любую клетку доски. Из всех фигур в радиусе 3 клеток (кроме королей) взорвутся 2 случайные. Свои тоже могут пострадать.', 650, 750),
('pg', 'queen', 'Пегас', 'Вместо ферзя. Пегас ходит как слон и конь.', 200, 300),
('ce', 'queen', 'Кентавр', 'Вместо ферзя. Кентавр ходит как ладья и конь.', 1000, 1100),
('gn', 'queen', 'Генерал', 'Вместо ферзя. Генерал ходит как король и конь.', 1250, 1350),
('vk', 'queen', 'Валькирия', 'Вместо ферзя. Валькирия ходит как ферзь и конь.', 2500, 2600)
on conflict (id) do nothing;

-- ---------- 4. история партий ----------
create table if not exists public.games (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  result     text not null check (result in ('win','loss','draw')),
  mode       text not null,
  level      integer not null default 0,
  minutes    integer not null default 10,
  moves      integer not null default 0,
  opp        text,
  coins      integer not null default 0,
  hist       jsonb
);
create index if not exists games_user_idx on public.games (user_id, created_at desc);
alter table public.games enable row level security;
revoke all on public.games from anon, authenticated;

-- ---------- 5. друзья, приглашения, открытые комнаты ----------
create table if not exists public.friends (
  a uuid not null references auth.users(id) on delete cascade,   -- кто отправил заявку
  b uuid not null references auth.users(id) on delete cascade,
  accepted boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (a, b)
);
alter table public.friends enable row level security;
revoke all on public.friends from anon, authenticated;

create table if not exists public.invites (
  id bigint generated always as identity primary key,
  from_uid uuid not null references auth.users(id) on delete cascade,
  to_uid   uuid not null references auth.users(id) on delete cascade,
  code     text not null,
  minutes  integer not null default 10,
  created_at timestamptz not null default now()
);
alter table public.invites enable row level security;
revoke all on public.invites from anon, authenticated;

create table if not exists public.lobby (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code    text not null,
  minutes integer not null default 10,
  updated_at timestamptz not null default now()
);
alter table public.lobby enable row level security;
revoke all on public.lobby from anon, authenticated;

-- ---------- 6. функции (всё важное считает сервер) ----------
create or replace function public.pub_profile(r public.profiles) returns jsonb
language sql immutable as $$
  select jsonb_build_object('nick', r.nick, 'coins', r.coins, 'owned', to_jsonb(r.owned), 'equip', r.equip, 'equip_q', r.equip_q, 'skin', r.skin,
    'xp', r.xp, 'wins', r.wins, 'losses', r.losses, 'draws', r.draws, 'games', r.games);
$$;

create or replace function public.ensure_profile(p_nick text) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare em text; k text; r public.profiles;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select email into em from auth.users where id = auth.uid();
  -- ник-ключ берём из самого аккаунта (так же, как считает приложение), а не от клиента
  k := convert_from(decode(substring(em from 2 for position('@' in em) - 2), 'hex'), 'UTF8');
  insert into public.profiles (user_id, nick, nick_key)
    values (auth.uid(), left(trim(coalesce(nullif(p_nick, ''), k)), 14), k)
    on conflict (user_id) do nothing;
  update public.profiles set last_seen = now() where user_id = auth.uid() returning * into r;
  return public.pub_profile(r);
end $$;

create or replace function public.heartbeat() returns boolean
language sql security definer set search_path = public as $$
  update public.profiles set last_seen = now() where user_id = auth.uid() returning true;
$$;

create or replace function public.shop_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('now', now(),
    'items', coalesce(jsonb_agg(to_jsonb(s) - 'created_at' order by s.sort, s.price), '[]'::jsonb))
  from public.shop_items s where s.active;
$$;

create or replace function public.buy_item(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare it public.shop_items; r public.profiles; price int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into it from public.shop_items where id = p_id and active;
  if not found then raise exception 'Товар не найден'; end if;
  if (it.avail_from is not null and it.avail_from > now()) or (it.avail_until is not null and it.avail_until <= now()) then
    raise exception 'Этот товар сейчас не продаётся';
  end if;
  select * into r from public.profiles where user_id = auth.uid() for update;
  if not found then raise exception 'Нет профиля'; end if;
  if p_id = any(r.owned) then return public.pub_profile(r); end if;
  price := it.price;
  if it.sale_price is not null and it.sale_price < it.price
     and (it.sale_from is null or it.sale_from <= now()) and (it.sale_until is null or it.sale_until > now()) then
    price := it.sale_price;
  end if;
  if r.coins < price then raise exception 'Не хватает монет: нужно ещё %', price - r.coins; end if;
  update public.profiles set coins = coins - price, owned = array_append(owned, p_id)
    where user_id = auth.uid() returning * into r;
  return public.pub_profile(r);
end $$;

-- Награда за партию. Формула такая же, как в приложении (calcReward).
-- Защита от накрутки: не чаще раза в 25 секунд и не больше 250 монет в сутки.
create or replace function public.claim_game(p_result text, p_mode text, p_level int, p_minutes int, p_moves int, p_lost int, p_opp text, p_hist jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.profiles; base int := 0; total int := 0; xpv int; award int; capped boolean; dc int; limited boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_result not in ('win','loss','draw') or p_mode not in ('bot','online') then raise exception 'bad args'; end if;
  p_level   := greatest(0, least(6,   coalesce(p_level, 0)));
  p_moves   := greatest(0, least(400, coalesce(p_moves, 0)));
  p_lost    := greatest(0, least(200, coalesce(p_lost, 0)));
  p_minutes := greatest(1, least(60,  coalesce(p_minutes, 10)));
  if p_hist is not null and length(p_hist::text) > 150000 then p_hist := null; end if;
  select * into r from public.profiles where user_id = auth.uid() for update;
  if not found then raise exception 'Нет профиля'; end if;

  if p_result = 'win' then
    if p_moves < 6 then base := 3;
    else
      base := 20
        + case when p_moves <= 15 then 10 when p_moves <= 25 then 6 when p_moves <= 35 then 3 else 0 end
        + case when p_lost = 0 then 10 when p_lost <= 3 then 6 when p_lost <= 8 then 3 else 0 end;
    end if;
  elsif p_result = 'draw' then
    if p_moves >= 6 then base := 6; end if;
  else
    if p_moves >= 6 then base := 3; end if;
  end if;
  total := base;
  if p_mode = 'bot' then
    if p_result <> 'win' then total := 0;
    else total := round(base * (array[0, 0.1, 0.2, 0.35, 0.5, 0.7, 1.0])[p_level + 1])::int; end if;
  end if;

  limited := r.last_claim is not null and r.last_claim > now() - interval '25 seconds';
  if limited then total := 0; end if;
  dc := case when r.day = current_date then r.day_coins else 0 end;
  award := least(total, greatest(0, 250 - dc));
  capped := award < total;

  xpv := case p_result when 'win' then 30 when 'draw' then 15 else 10 end;
  if p_mode = 'bot' then xpv := round(xpv / 2.0)::int; end if;
  if limited then xpv := 0; end if;

  if p_mode = 'bot' then
    -- бои с ботами не идут в статистику, опыт и историю: только монеты
    update public.profiles set coins = coins + award, last_claim = now(), day = current_date, day_coins = dc + award
      where user_id = auth.uid() returning * into r;
    return public.pub_profile(r) || jsonb_build_object('awarded', award, 'capped', capped);
  end if;

  update public.profiles set
    coins = coins + award, xp = xp + xpv, games = games + 1,
    wins = wins + (p_result = 'win')::int, losses = losses + (p_result = 'loss')::int, draws = draws + (p_result = 'draw')::int,
    last_claim = now(), day = current_date, day_coins = dc + award
  where user_id = auth.uid() returning * into r;

  insert into public.games (user_id, result, mode, level, minutes, moves, opp, coins, hist)
    values (auth.uid(), p_result, p_mode, p_level, p_minutes, p_moves, left(coalesce(p_opp, ''), 30), award, p_hist);
  delete from public.games where user_id = auth.uid()
    and id not in (select id from public.games where user_id = auth.uid() order by created_at desc limit 30);

  return public.pub_profile(r) || jsonb_build_object('awarded', award, 'capped', capped);
end $$;

create or replace function public.games_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'created_at', g.created_at, 'result', g.result, 'mode', g.mode,
    'opp', g.opp, 'minutes', g.minutes, 'moves', g.moves, 'level', g.level, 'coins', g.coins) order by g.created_at desc), '[]'::jsonb)
  from (select * from public.games where user_id = auth.uid() order by created_at desc limit 30) g;
$$;

create or replace function public.game_get(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(g) - 'user_id' from public.games g where g.id = p_id and g.user_id = auth.uid();
$$;

-- друзья
create or replace function public.friend_request(p_key text) returns boolean
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select user_id into t from public.profiles where nick_key = trim(p_key);
  if t is null then raise exception 'not found'; end if;
  if t = auth.uid() then raise exception 'Это ты'; end if;
  if exists (select 1 from public.friends where a = t and b = auth.uid()) then
    update public.friends set accepted = true where a = t and b = auth.uid();
  elsif not exists (select 1 from public.friends where a = auth.uid() and b = t) then
    insert into public.friends (a, b) values (auth.uid(), t);
  end if;
  return true;
end $$;

create or replace function public.friends_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(s.x), '[]'::jsonb) from (
    select jsonb_build_object('uid', p.user_id, 'nick', p.nick,
      'status', case when f.accepted then 'friend' when f.a = auth.uid() then 'outgoing' else 'incoming' end,
      'online', coalesce(p.last_seen > now() - interval '90 seconds', false),
      'last_seen', p.last_seen) as x
    from public.friends f
    join public.profiles p on p.user_id = case when f.a = auth.uid() then f.b else f.a end
    where f.a = auth.uid() or f.b = auth.uid()
  ) s;
$$;

create or replace function public.friend_respond(p_uid uuid, p_accept boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_accept then update public.friends set accepted = true where a = p_uid and b = auth.uid();
  else delete from public.friends where a = p_uid and b = auth.uid(); end if;
  return true;
end $$;

create or replace function public.friend_remove(p_uid uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  delete from public.friends where (a = auth.uid() and b = p_uid) or (a = p_uid and b = auth.uid());
  return true;
end $$;

-- приглашения в бой
create or replace function public.send_invite(p_to uuid, p_code text, p_minutes int) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_code !~ '^[A-Z0-9]{4,6}$' then raise exception 'bad code'; end if;
  if not exists (select 1 from public.friends where accepted and ((a = auth.uid() and b = p_to) or (a = p_to and b = auth.uid()))) then
    raise exception 'Вы не друзья';
  end if;
  delete from public.invites where from_uid = auth.uid() and to_uid = p_to;
  delete from public.invites where created_at < now() - interval '10 minutes';
  insert into public.invites (from_uid, to_uid, code, minutes) values (auth.uid(), p_to, p_code, greatest(1, least(60, coalesce(p_minutes, 10))));
  return true;
end $$;

create or replace function public.my_invites() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'from_nick', p.nick, 'code', i.code, 'minutes', i.minutes) order by i.id), '[]'::jsonb)
  from public.invites i join public.profiles p on p.user_id = i.from_uid
  where i.to_uid = auth.uid() and i.created_at > now() - interval '90 seconds';
$$;

create or replace function public.invite_done(p_id bigint) returns boolean
language sql security definer set search_path = public as $$
  delete from public.invites where id = p_id and to_uid = auth.uid() returning true;
$$;

-- открытые комнаты (поиск соперника)
create or replace function public.lobby_publish(p_code text, p_minutes int) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_code !~ '^[A-Z0-9]{4,6}$' then raise exception 'bad code'; end if;
  insert into public.lobby (user_id, code, minutes, updated_at) values (auth.uid(), p_code, greatest(1, least(60, coalesce(p_minutes, 10))), now())
    on conflict (user_id) do update set code = excluded.code, minutes = excluded.minutes, updated_at = now();
  return true;
end $$;

create or replace function public.lobby_remove() returns boolean
language sql security definer set search_path = public as $$
  delete from public.lobby where user_id = auth.uid() returning true;
$$;

create or replace function public.lobby_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', l.code, 'minutes', l.minutes, 'nick', p.nick, 'nick_key', p.nick_key, 'xp', p.xp) order by l.updated_at desc), '[]'::jsonb)
  from (select * from public.lobby where updated_at > now() - interval '50 seconds' and user_id <> auth.uid() order by updated_at desc limit 20) l
  join public.profiles p on p.user_id = l.user_id;
$$;

-- ---------- 7. права на вызов функций ----------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('pub_profile','ensure_profile','heartbeat','shop_catalog','buy_item','claim_game','games_list','game_get',
      'friend_request','friends_list','friend_respond','friend_remove','send_invite','my_invites','invite_done','lobby_publish','lobby_remove','lobby_list')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname <> 'pub_profile' then execute format('grant execute on function %s to authenticated', f.sig); end if;
    if f.proname = 'shop_catalog' then execute format('grant execute on function %s to anon', f.sig); end if;
  end loop;
end $$;

-- ---------- 8. хранилище скинов (картинки фигур) ----------
insert into storage.buckets (id, name, public) values ('skins', 'skins', true)
  on conflict (id) do update set public = true;

-- ============================================================================
--  ПОДСКАЗКИ (это просто комментарии, ничего не выполняется)
--
--  Hollow Purple себе (ник МАЛЕНЬКИМИ буквами):
--    insert into public.grants (nick, abilities) values ('mynick', '{purple}')
--      on conflict (nick) do update set abilities = excluded.abilities;
--
--  Новый скин. 1) Storage -> skins -> создать папку purple_neon -> залить 24 PNG (wk, wq, wr, wb, wn, wp, bk, bq, br, bb, bn, bp
--  и по желанию wpg wvk wce wgn bpg bvk bce bgn). 2) добавить товар:
--    insert into public.shop_items (id, kind, name, descr, price, meta)
--    values ('purple_neon', 'skin', 'Неон', 'Светящиеся фигуры', 300, '{"ext":"png"}');
--
--  Акция на 3 дня (цена 100 вместо 200, считает сервер, подделать нельзя):
--    update public.shop_items set sale_price = 100, sale_from = now(), sale_until = now() + interval '3 days' where id = 'pg';
--
--  Временная продажа (товар исчезнет через 48 часов):
--    update public.shop_items set avail_until = now() + interval '48 hours' where id = 'purple_neon';
--
--  Убрать товар из магазина: update public.shop_items set active = false where id = 'purple_neon';
-- ============================================================================

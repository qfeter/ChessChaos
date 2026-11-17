-- Запусти ВЕСЬ этот файл один раз: Supabase -> SQL Editor -> New query -> вставить -> Run.
-- Ничего не удаляет, можно запускать повторно.

create table if not exists public.profiles (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  nick     text not null,
  nick_key text not null unique,
  coins    integer not null default 100 check (coins >= 0),
  owned    text[]  not null default '{}',
  equip    text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select to authenticated using (auth.uid() = user_id);
create policy "profiles_insert_own" on public.profiles for insert to authenticated with check (auth.uid() = user_id);
create policy "profiles_update_own" on public.profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- Защита: ник в профиле обязан совпадать с ником, на который зарегистрирован аккаунт (иначе можно было бы
-- записать чужой ник и подсмотреть чужие админ-способности), и ник нельзя менять после создания.
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare em text;
begin
  select email into em from auth.users where id = new.user_id;
  if tg_op = 'INSERT' then
    if em is distinct from ('u' || encode(convert_to(new.nick_key, 'UTF8'), 'hex') || '@fchess.app') then
      raise exception 'nick does not match account';
    end if;
  else
    new.nick := old.nick; new.nick_key := old.nick_key; new.user_id := old.user_id;
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard_trg on public.profiles;
create trigger profiles_guard_trg before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- Админские способности по нику. Менять ТОЛЬКО ты, в Table Editor (там ты владелец, RLS тебя не касается).
create table if not exists public.grants (
  nick      text primary key,              -- ник МАЛЕНЬКИМИ буквами
  abilities text[] not null default '{}'   -- например {purple}
);

alter table public.grants enable row level security;

drop policy if exists "grants_select_own_nick" on public.grants;
-- игрок видит только строку со своим ником
create policy "grants_select_own_nick" on public.grants for select to authenticated
  using (nick = (select p.nick_key from public.profiles p where p.user_id = auth.uid()));

-- как выдать себе Hollow Purple (подставь свой ник маленькими буквами):
-- insert into public.grants (nick, abilities) values ('mynick', '{purple}')
--   on conflict (nick) do update set abilities = excluded.abilities;

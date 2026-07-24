-- ============================================================
--  SABAI — konfiguracja bazy danych (Supabase)
--
--  CO TO ROBI: tworzy dwie tabele (wejscia na strone + zapisy),
--  ustawia reguly dostepu (RLS) tak, ze:
--    - kazdy odwiedzajacy moze ZAPISAC sie i wygenerowac zdarzenie,
--    - CZYTAC dane (panel) moze wylacznie Ty, po zalogowaniu swoim e-mailem.
--
--  JAK URUCHOMIC: Supabase -> SQL Editor -> New query ->
--  wklej CALOSC -> najpierw podmien e-mail w punkcie 2 -> Run.
--  Mozna uruchomic ponownie w razie potrzeby — nie kasuje danych.
-- ============================================================


-- ---------- 1. TABELE ----------
create table if not exists public.events (
  id           bigint generated always as identity primary key,
  name         text not null,
  session_id   text,
  device       text,
  referrer     text,
  utm_source   text,
  utm_campaign text,
  created_at   timestamptz not null default now()
);
create index if not exists events_created_idx on public.events (created_at);
create index if not exists events_name_idx    on public.events (name);

create table if not exists public.leads (
  id           bigint generated always as identity primary key,
  imie         text,
  telefon      text,
  email        text,
  zgoda_rodo   boolean default false,
  session_id   text,
  utm_source   text,
  utm_campaign text,
  created_at   timestamptz not null default now()
);
create index if not exists leads_created_idx on public.leads (created_at);


-- ---------- 2. KTO JEST ADMINEM  <<< PODMIEN E-MAIL >>> ----------
-- To e-mail, ktorym bedziesz logowac sie do panelu (admin.html).
-- Wpisz go MALYMI literami. Mozesz dodac kilku (kazdy w nowej linii, z przecinkiem).
create or replace function public.is_admin()
returns boolean
language sql stable
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'twoj@email.pl'          -- <<< TU wpisz SWOJ e-mail (male litery)
    -- , 'drugi@email.pl'    -- (opcjonalnie: kolejny admin)
  );
$$;


-- ---------- 3. UPRAWNIENIA + REGULY DOSTEPU (RLS) ----------
grant usage on schema public to anon, authenticated;
grant insert on public.events to anon, authenticated;
grant select on public.events to authenticated;
grant insert on public.leads  to anon, authenticated;
grant select, delete on public.leads to authenticated;

alter table public.events enable row level security;
alter table public.leads  enable row level security;

-- events: kazdy moze DODAC zdarzenie; czytac moze tylko admin
drop policy if exists events_insert_anon  on public.events;
create policy events_insert_anon on public.events
  for insert to anon, authenticated with check (true);

drop policy if exists events_select_admin on public.events;
create policy events_select_admin on public.events
  for select to authenticated using (public.is_admin());

-- leads: kazdy moze sie ZAPISAC; czytac/usuwac moze tylko admin
drop policy if exists leads_insert_anon  on public.leads;
create policy leads_insert_anon on public.leads
  for insert to anon, authenticated with check (true);

drop policy if exists leads_select_admin on public.leads;
create policy leads_select_admin on public.leads
  for select to authenticated using (public.is_admin());

drop policy if exists leads_delete_admin on public.leads;
create policy leads_delete_admin on public.leads
  for delete to authenticated using (public.is_admin());


-- ---------- 4. PUBLICZNY LICZNIK ZAPISOW (licznik w hero strony) ----------
-- Zwraca TYLKO liczbe — nigdy zadnych danych osobowych.
create or replace function public.public_lead_count()
returns bigint
language sql stable security definer set search_path = public
as $$
  select count(*) from public.leads;
$$;
grant execute on function public.public_lead_count() to anon, authenticated;


-- ---------- 5. STATYSTYKI DO PANELU ----------
-- Zwraca komplet liczb dla admin.html: zapisy, wejscia, unikalne osoby,
-- ruch dzienny (by_day) i klikniecia w przyciski (clicks).
create or replace function public.admin_stats(since timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  result jsonb;
begin
  if not public.is_admin() then
    raise exception 'Brak uprawnien';
  end if;

  select jsonb_build_object(
    'leads',      (select count(*) from public.leads  where created_at >= since),
    'page_views', (select count(*) from public.events where created_at >= since and name = 'page_view'),
    'sessions',   (select count(distinct session_id) from public.events where created_at >= since),
    'by_day', coalesce((
      select jsonb_agg(row_to_json(d))
      from (
        select to_char(date_trunc('day', created_at), 'YYYY-MM-DD') as day,
               count(*) filter (where name = 'page_view')           as views,
               count(distinct session_id)                           as sessions
        from public.events
        where created_at >= since
        group by 1
        order by 1
      ) d
    ), '[]'::jsonb),
    'clicks', coalesce((
      select jsonb_agg(row_to_json(c))
      from (
        select name,
               count(*)                   as n,
               count(distinct session_id) as uniq
        from public.events
        where created_at >= since
          and name <> 'page_view'
        group by name
        order by count(*) desc
      ) c
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;
grant execute on function public.admin_stats(timestamptz) to authenticated;

-- ============================================================
--  GOTOWE. Teraz wroc do pliku PANEL-JAK-URUCHOMIC.txt, punkt 3.
-- ============================================================

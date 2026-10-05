-- 백중연 예약 시스템 — Supabase SQL Editor에서 한 번 실행 (재실행해도 안전)
-- 기존 통합 프로젝트에 테이블·함수만 추가. 다른 앱 테이블과 무관.
--
-- 운영 규칙(페이지 안내와 동일):
--   · 하루 8팀 / 신청 후 24시간 내 미입금 시 자동 효력 상실(자리 자동 반환)
--   · 접수 마감: 참가일 3일 전 자정 (10.10 팀 → 10.7 / 10.11 팀 → 10.8)
--   · 관리자 암호: 00010101  (바꾸려면 아래 '00010101' 두 곳을 고쳐 다시 실행)

create table if not exists public.baekjungyeon_reservations (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  event_date  date not null check (event_date in ('2026-10-10','2026-10-11')),
  name        text not null check (char_length(name) between 1 and 20),
  phone       text not null check (phone ~ '^010-\d{4}-\d{4}$'),
  party_size  int  not null check (party_size between 1 and 6),
  car_no      text check (char_length(car_no) <= 12),
  status      text not null default 'pending'
              check (status in ('pending','confirmed','cancelled')),
  memo        text
);
alter table public.baekjungyeon_reservations
  add column if not exists agreed boolean not null default true;
create index if not exists baekjungyeon_reservations_date_idx
  on public.baekjungyeon_reservations (event_date, status, created_at);

comment on table public.baekjungyeon_reservations is
  '백중연 예약. status: pending=입금대기(24h 경과 시 자리 자동 반환) / confirmed=확정 / cancelled=취소. 처리는 admin.html';

-- ── "유효한 신청" 판정: 확정이거나, 24시간 이내의 입금대기 ──
create or replace function public.baekjungyeon_is_active(p_status text, p_created timestamptz)
returns boolean language sql immutable as $$
  select p_status = 'confirmed'
      or (p_status = 'pending' and p_created > now() - interval '24 hours');
$$;

-- ── RLS: 방문자는 INSERT만, 조회 불가 ──
alter table public.baekjungyeon_reservations enable row level security;
drop policy if exists "anon_insert" on public.baekjungyeon_reservations;
create policy "anon_insert" on public.baekjungyeon_reservations
  for insert to anon, authenticated with check (true);

-- ── 신청 시 검사: 접수 마감 + 정원(동시 신청 잠금) ──
create or replace function public.baekjungyeon_capacity_check()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- 참가일 3일 전 자정(KST) 이후 접수 불가
  if now() >= ((new.event_date - 2)::timestamp at time zone 'Asia/Seoul') then
    raise exception 'CLOSED';
  end if;
  perform pg_advisory_xact_lock(hashtext('baekjungyeon_' || new.event_date::text));
  if (select count(*) from public.baekjungyeon_reservations
      where event_date = new.event_date
        and public.baekjungyeon_is_active(status, created_at)) >= 8 then
    raise exception 'FULL';
  end if;
  new.status := 'pending';
  return new;
end $$;

drop trigger if exists trg_baekjungyeon_capacity on public.baekjungyeon_reservations;
create trigger trg_baekjungyeon_capacity
  before insert on public.baekjungyeon_reservations
  for each row execute function public.baekjungyeon_capacity_check();

-- ── 날짜별 유효 신청 수 (잔여팀 표시용, 개인정보 없음) ──
create or replace function public.baekjungyeon_counts()
returns table (event_date date, cnt bigint)
language sql security definer set search_path = public as $$
  select event_date, count(*) from public.baekjungyeon_reservations
  where public.baekjungyeon_is_active(status, created_at)
  group by event_date;
$$;
grant execute on function public.baekjungyeon_counts() to anon, authenticated;

-- ── 관리자: 목록 ──
create or replace function public.baekjungyeon_admin_list(p_pass text)
returns setof public.baekjungyeon_reservations
language plpgsql security definer set search_path = public as $$
begin
  if p_pass is distinct from '00010101' then
    perform pg_sleep(1.5);           -- 무차별 대입 지연
    raise exception 'DENIED';
  end if;
  return query select * from public.baekjungyeon_reservations
    order by event_date, created_at;
end $$;

-- ── 관리자: 상태·메모 변경 (확정 시 정원 재검사) ──
create or replace function public.baekjungyeon_admin_update(
  p_pass text, p_id uuid, p_status text default null, p_memo text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare r public.baekjungyeon_reservations;
begin
  if p_pass is distinct from '00010101' then
    perform pg_sleep(1.5);
    raise exception 'DENIED';
  end if;
  select * into r from public.baekjungyeon_reservations where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_status is not null then
    if p_status not in ('pending','confirmed','cancelled') then
      raise exception 'BAD_STATUS';
    end if;
    if p_status = 'confirmed' then
      perform pg_advisory_xact_lock(hashtext('baekjungyeon_' || r.event_date::text));
      if (select count(*) from public.baekjungyeon_reservations
          where event_date = r.event_date and id <> p_id
            and public.baekjungyeon_is_active(status, created_at)) >= 8 then
        raise exception 'FULL';
      end if;
    end if;
    -- '대기로' 되돌리면 24시간을 다시 셈 (created_at 갱신)
    update public.baekjungyeon_reservations
       set status = p_status,
           created_at = case when p_status = 'pending' then now() else created_at end
     where id = p_id;
  end if;
  if p_memo is not null then
    update public.baekjungyeon_reservations set memo = nullif(p_memo,'') where id = p_id;
  end if;
end $$;

grant execute on function public.baekjungyeon_admin_list(text) to anon, authenticated;
grant execute on function public.baekjungyeon_admin_update(text, uuid, text, text) to anon, authenticated;

-- 행사 종료·정산 후 개인정보 파기(동의문 약속): 
--   delete from public.baekjungyeon_reservations;

-- ═══════════════════════════════════════════════════════════════
-- v3. 참가팀 디지털 쿠폰 · 체험 정산  (재실행 안전)
--   · 확정된 팀마다 token → coupon.html?t=TOKEN 링크를 확정 문자로 발송
--   · 유료 체험 4종은 인원수만큼, 가족사진은 팀당 1장 발급
--   · 진행자 확인번호(PIN) + 운영시간 안에서만 사용 처리 → 기록이 남아 정산
--   · 운영시간·단가·PIN은 baekjungyeon_vendors 표에서 수정
-- ═══════════════════════════════════════════════════════════════
alter table public.baekjungyeon_reservations
  add column if not exists token text unique default encode(gen_random_bytes(6), 'hex');
update public.baekjungyeon_reservations set token = encode(gen_random_bytes(6), 'hex') where token is null;

create table if not exists public.baekjungyeon_vendors (
  kind        text primary key,
  name        text not null,
  unit_price  int  not null default 0,      -- 정산 단가(원)
  per_person  boolean not null default true,-- true: 인원수만큼 발급 / false: 팀당 1장
  windows     jsonb not null,               -- 참가팀 전용 운영시간 [["10:00","11:00"],...]
  pin         text not null                 -- 체험 진행자 확인번호
);
insert into public.baekjungyeon_vendors (kind, name, unit_price, per_person, windows, pin) values
  ('photo',   '백중 가족사진(액자·택배)',      200000, false, '[["10:00","11:00"],["16:00","17:00"]]', '2101'),
  ('fan',     '풍류 한 자락 (캘리 부채)',       5000,  true,  '[["11:30","12:30"]]', '2102'),
  ('pouch',   '소원 향낭',                      5000,  true,  '[["12:30","13:30"]]', '2103'),
  ('hopae',   '나의 첫 호패',                   3000,  true,  '[["13:30","14:30"]]', '2104'),
  ('daenggi', '꽃댕기 한 자락 (댕기 키링)',     5000,  true,  '[["14:30","15:30"]]', '2105')
on conflict (kind) do nothing;

create table if not exists public.baekjungyeon_coupons (
  id              uuid primary key default gen_random_uuid(),
  reservation_id  uuid not null references public.baekjungyeon_reservations(id) on delete cascade,
  kind            text not null references public.baekjungyeon_vendors(kind),
  seq             int  not null,
  used_at         timestamptz,
  used_by         text,
  unique (reservation_id, kind, seq)
);
alter table public.baekjungyeon_vendors enable row level security;   -- 직접 조회 불가(함수로만)
alter table public.baekjungyeon_coupons enable row level security;

-- 쿠폰 발급(확정 팀, 중복 발급 없음)
create or replace function public.baekjungyeon_issue_coupons(p_res uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.baekjungyeon_reservations; v record; i int;
begin
  select * into r from public.baekjungyeon_reservations where id = p_res;
  if not found or r.status <> 'confirmed' then return; end if;
  for v in select * from public.baekjungyeon_vendors loop
    for i in 1..(case when v.per_person then r.party_size else 1 end) loop
      insert into public.baekjungyeon_coupons (reservation_id, kind, seq)
        values (p_res, v.kind, i) on conflict do nothing;
    end loop;
  end loop;
end $$;

-- 관리자 상태 변경: 확정 시 쿠폰 자동 발급 (기존 함수 대체)
create or replace function public.baekjungyeon_admin_update(
  p_pass text, p_id uuid, p_status text default null, p_memo text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare r public.baekjungyeon_reservations;
begin
  if p_pass is distinct from '00010101' then perform pg_sleep(1.5); raise exception 'DENIED'; end if;
  select * into r from public.baekjungyeon_reservations where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_status is not null then
    if p_status not in ('pending','confirmed','cancelled') then raise exception 'BAD_STATUS'; end if;
    if p_status = 'confirmed' then
      perform pg_advisory_xact_lock(hashtext('baekjungyeon_' || r.event_date::text));
      if (select count(*) from public.baekjungyeon_reservations
          where event_date = r.event_date and id <> p_id
            and public.baekjungyeon_is_active(status, created_at)) >= 8 then
        raise exception 'FULL';
      end if;
    end if;
    update public.baekjungyeon_reservations
       set status = p_status,
           created_at = case when p_status = 'pending' then now() else created_at end
     where id = p_id;
    if p_status = 'confirmed' then perform public.baekjungyeon_issue_coupons(p_id); end if;
  end if;
  if p_memo is not null then
    update public.baekjungyeon_reservations set memo = nullif(p_memo,'') where id = p_id;
  end if;
end $$;
grant execute on function public.baekjungyeon_admin_update(text, uuid, text, text) to anon, authenticated;

-- 참가팀: 쿠폰 조회 (링크 토큰으로만)
create or replace function public.baekjungyeon_coupons_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.baekjungyeon_reservations; res jsonb;
begin
  select * into r from public.baekjungyeon_reservations where token = p_token;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.baekjungyeon_issue_coupons(r.id);
  select jsonb_build_object(
    'name', r.name, 'event_date', r.event_date, 'party_size', r.party_size, 'status', r.status,
    'now_kst', to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'),
    'vendors', (select jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'windows', windows,
                  'per_person', per_person, 'unit_price', unit_price) order by (windows->0->>0))
                from public.baekjungyeon_vendors),
    'coupons', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'seq', seq,
                  'used_at', to_char(used_at at time zone 'Asia/Seoul', 'HH24:MI'), 'used_by', used_by) order by kind, seq)
                from public.baekjungyeon_coupons where reservation_id = r.id), '[]'::jsonb)
  ) into res;
  return res;
end $$;
grant execute on function public.baekjungyeon_coupons_get(text) to anon, authenticated;

-- 진행자 확인번호로 사용 처리 (운영시간·당일·확정팀만)
create or replace function public.baekjungyeon_coupon_redeem(p_token text, p_coupon uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.baekjungyeon_reservations; c public.baekjungyeon_coupons; v public.baekjungyeon_vendors;
        kst timestamp := now() at time zone 'Asia/Seoul'; ok boolean := false; w jsonb;
begin
  select * into r from public.baekjungyeon_reservations where token = p_token;
  if not found then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'confirmed' then raise exception 'NOT_CONFIRMED'; end if;
  select * into c from public.baekjungyeon_coupons where id = p_coupon and reservation_id = r.id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if c.used_at is not null then raise exception 'USED'; end if;
  select * into v from public.baekjungyeon_vendors where kind = c.kind;
  if v.pin is distinct from p_pin then perform pg_sleep(1); raise exception 'BAD_PIN'; end if;
  if kst::date <> r.event_date then raise exception 'WRONG_DATE'; end if;
  for w in select * from jsonb_array_elements(v.windows) loop
    if kst::time >= (w->>0)::time and kst::time < (w->>1)::time then ok := true; end if;
  end loop;
  if not ok then raise exception 'OUTSIDE_WINDOW'; end if;
  update public.baekjungyeon_coupons set used_at = now(), used_by = v.name where id = c.id;
  return jsonb_build_object('ok', true, 'used_at', to_char(now() at time zone 'Asia/Seoul', 'HH24:MI'));
end $$;
grant execute on function public.baekjungyeon_coupon_redeem(text, uuid, text) to anon, authenticated;

-- 관리자: 체험별·날짜별 정산 (사용 수 × 단가)
create or replace function public.baekjungyeon_admin_settlement(p_pass text)
returns table (event_date date, kind text, name text, unit_price int, issued_cnt bigint, used_cnt bigint, amount bigint)
language plpgsql security definer set search_path = public as $$
begin
  if p_pass is distinct from '00010101' then perform pg_sleep(1.5); raise exception 'DENIED'; end if;
  return query
    select r.event_date, v.kind, v.name, v.unit_price,
           count(c.id)::bigint, count(c.used_at)::bigint, (count(c.used_at) * v.unit_price)::bigint
      from public.baekjungyeon_coupons c
      join public.baekjungyeon_reservations r on r.id = c.reservation_id
      join public.baekjungyeon_vendors v on v.kind = c.kind
     where r.status = 'confirmed'
     group by r.event_date, v.kind, v.name, v.unit_price, (v.windows->0->>0)
     order by r.event_date, (v.windows->0->>0);
end $$;
grant execute on function public.baekjungyeon_admin_settlement(text) to anon, authenticated;

-- 관리자: 사용 내역 상세 (정산 증빙)
create or replace function public.baekjungyeon_admin_coupon_log(p_pass text)
returns table (event_date date, team text, kind text, name text, seq int, used_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if p_pass is distinct from '00010101' then perform pg_sleep(1.5); raise exception 'DENIED'; end if;
  return query
    select r.event_date, r.name, v.kind, v.name, c.seq, c.used_at
      from public.baekjungyeon_coupons c
      join public.baekjungyeon_reservations r on r.id = c.reservation_id
      join public.baekjungyeon_vendors v on v.kind = c.kind
     where c.used_at is not null
     order by c.used_at;
end $$;
grant execute on function public.baekjungyeon_admin_coupon_log(text) to anon, authenticated;

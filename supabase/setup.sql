-- =====================================================================
-- 自动工程实作课 云端版 · 第 1 阶段 · setup.sql
-- 在 Supabase → SQL Editor 整份贴进去，按 Run。
-- 可以重跑：已经建好的表不会被清掉。
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------
-- 只给后台（Edge Function）用的资料：网页完全碰不到
-- ---------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;

create table if not exists private.app_secrets (
  key   text primary key,
  value text not null
);
insert into private.app_secrets (key, value)
values ('cron', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

create table if not exists private.google (
  id            int primary key default 1 check (id = 1),
  refresh_token text,
  folder_id     text,
  email         text,
  connected_at  timestamptz
);
insert into private.google (id) values (1) on conflict (id) do nothing;

create table if not exists private.backup_state (
  id         int primary key default 1 check (id = 1),
  last_stamp text,
  last_at    timestamptz,
  last_try   timestamptz,
  last_error text
);
insert into private.backup_state (id) values (1) on conflict (id) do nothing;

create table if not exists private.login_failures (
  name_key text not null,
  at       timestamptz not null default now()
);
create index if not exists login_failures_key_at on private.login_failures (name_key, at);

create table if not exists private.teacher_activity (
  id            int primary key default 1 check (id = 1),
  last_seen     timestamptz,
  last_reminded timestamptz
);
insert into private.teacher_activity (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 老师
-- ---------------------------------------------------------------------
create table if not exists public.teachers (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.teachers enable row level security;   -- 没有 policy：网页读不到这张表

create or replace function public.is_teacher()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.teachers where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 小工具：自动更新 updated_at、生 Code / PIN
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function public.gen_class_code()
returns text language plpgsql volatile set search_path = public as $$
declare
  c text;
begin
  loop
    c := (1000 + floor(random() * 9000))::int::text;
    exit when not exists (select 1 from public.classes where code = c);
  end loop;
  return c;
end $$;

create or replace function public.gen_pin()
returns text language plpgsql volatile set search_path = public as $$
declare
  p text;
begin
  loop
    p := (100000 + floor(random() * 900000))::int::text;
    exit when not exists (select 1 from public.students where pin = p);
  end loop;
  return p;
end $$;

-- ---------------------------------------------------------------------
-- 班级
-- ---------------------------------------------------------------------
create table if not exists public.classes (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(btrim(name)) between 1 and 40),
  level      text not null check (level in ('L1', 'L2', 'L3', 'L4', 'L5', '快车道', '体验班')),
  code       text not null unique default public.gen_class_code() check (code ~ '^\d{4,6}$'),
  week       text not null default 'W1',
  date       date,
  time       text,
  open       boolean not null default false,
  archived   boolean not null default false,
  demo       boolean not null default false,
  finishing  boolean not null default false,
  sessions   jsonb not null default '{}'::jsonb,   -- {"W3": "2027-01-16", ...} 每一周在哪一天上
  opened_at  timestamptz,
  closed_at  timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 学生（PIN、家长资料只有老师看得到）
-- ---------------------------------------------------------------------
create table if not exists public.students (
  id           uuid primary key default gen_random_uuid(),
  level        text not null check (level in ('L1', 'L2', 'L3', 'L4', 'L5', '快车道')),
  name         text not null check (char_length(btrim(name)) between 1 and 40),
  class_id     uuid references public.classes (id) on delete set null,
  pin          text not null unique default public.gen_pin() check (pin ~ '^\d{6}$'),
  grade        text not null default '',
  school       text not null default '',
  parent       text not null default '',
  phone        text not null default '',
  join_date    date,
  start_date   date,
  note         text not null default '',
  auth_user_id uuid unique references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists students_level_name on public.students (level, lower(name));

-- ---------------------------------------------------------------------
-- 进度：一个学生、一周一格
-- ---------------------------------------------------------------------
create table if not exists public.progress (
  student_id   uuid not null references public.students (id) on delete cascade,
  week         text not null check (week ~ '^W([1-9]|[12][0-9]|3[0-6])$'),
  attend       text not null default '' check (attend in ('', '✓', '迟', '补', '缺')),
  complete     text not null default '',
  pending      text not null default '',
  ai_summary   text not null default '',
  teacher_note text not null default '',
  stuck        text not null default '',
  class_id     uuid references public.classes (id) on delete set null,
  date         date,
  updated_at   timestamptz not null default now(),
  primary key (student_id, week)
);

-- ---------------------------------------------------------------------
-- 今天的状况（每班每周一格）
-- ---------------------------------------------------------------------
create table if not exists public.class_notes (
  class_id   uuid not null references public.classes (id) on delete cascade,
  week       text not null check (week ~ '^W([1-9]|[12][0-9]|3[0-6])$'),
  date       date,
  stuck      text not null default '',
  equipment  text not null default '',
  next       text not null default '',
  photo      text not null default '',
  updated_at timestamptz not null default now(),
  primary key (class_id, week)
);

-- ---------------------------------------------------------------------
-- 老师的文件（文件本身在 Storage 的 teacher-files）
--   发给一个班：class_id + class_code 都有
--   发给某个 Level 全部班：class_id、class_code 都空，只有 level
--   班被删掉：class_id 变空，class_code 还在 → 学生看不到
-- ---------------------------------------------------------------------
create table if not exists public.teacher_files (
  id          uuid primary key default gen_random_uuid(),
  filename    text not null check (char_length(filename) between 1 and 120),
  stored      text not null unique,
  class_id    uuid references public.classes (id) on delete set null,
  class_code  text,
  level       text not null default '',
  week        text not null default '',
  description text not null default '',
  size        bigint not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 推播（6 天没登入提醒）
-- ---------------------------------------------------------------------
create table if not exists public.push_subs (
  endpoint   text primary key,
  sub        jsonb not null,
  created_at timestamptz not null default now()
);

-- updated_at 触发器
do $$
declare
  t text;
begin
  foreach t in array array['classes', 'students', 'progress', 'class_notes', 'teacher_files'] loop
    execute format('drop trigger if exists touch on public.%I', t);
    execute format('create trigger touch before update on public.%I for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- RLS：这几张表只有老师可以直接读写；学生只能用下面的函数拿自己的东西
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['classes', 'students', 'progress', 'class_notes', 'teacher_files', 'push_subs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists teacher_all on public.%I', t);
    execute format('create policy teacher_all on public.%I for all to authenticated using (public.is_teacher()) with check (public.is_teacher())', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- =====================================================================
-- 网页用的函数
-- =====================================================================

-- 防暂停：GitHub Actions 每 3 天来碰一下
create or replace function public.ping()
returns text language sql stable as $$ select 'ok'::text $$;

-- 我是谁（老师 / 学生 / 都不是）
create or replace function public.whoami()
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when public.is_teacher() then jsonb_build_object('role', 'teacher')
    else coalesce(
      (select jsonb_build_object(
          'role', 'student', 'id', s.id, 'name', s.name, 'level', s.level,
          'class_id', s.class_id, 'class_name', coalesce(c.name, ''),
          'class_week', coalesce(c.week, ''), 'class_open', coalesce(c.open and not c.archived, false))
       from public.students s left join public.classes c on c.id = s.class_id
       where s.auth_user_id = auth.uid()),
      jsonb_build_object('role', 'none'))
  end;
$$;

-- 学生看自己的进度（没有老师备注、没有家长资料、没有 PIN）
create or replace function public.my_progress()
returns table (week text, attend text, complete text, pending text, summary text)
language sql stable security definer set search_path = public as $$
  select p.week, p.attend, p.complete, p.pending, p.ai_summary
  from public.progress p
  join public.students s on s.id = p.student_id
  where s.auth_user_id = auth.uid();
$$;

-- 学生看得到的老师文件
create or replace function public.my_files()
returns table (id uuid, filename text, stored text, week text, level text, description text,
               created_at timestamptz, for_all boolean)
language sql stable security definer set search_path = public as $$
  select f.id, f.filename, f.stored, f.week, f.level, f.description, f.created_at, (f.class_id is null)
  from public.teacher_files f
  join public.students s on s.auth_user_id = auth.uid()
  where (f.class_id is not null and f.class_id = s.class_id)
     or (f.class_id is null and f.class_code is null and f.level = s.level);
$$;

create or replace function public.can_read_file(path text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_teacher() or exists (select 1 from public.my_files() f where f.stored = path);
$$;

-- 老师：开始上课 / 下课
create or replace function public.start_class(p_id uuid, p_week text, p_date date, p_time text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_teacher() then raise exception '要先登入老师账号'; end if;
  if p_week !~ '^W([1-9]|[12][0-9]|3[0-6])$' then raise exception '周次不对'; end if;
  if p_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception '时间要用 24 小时制，例如 14:30'; end if;
  if exists (select 1 from public.classes where id = p_id and archived) then
    raise exception '这个班已经归档，先「取消归档」才能上课';
  end if;
  update public.classes
     set week = p_week, date = p_date, time = p_time, open = true, opened_at = now(),
         sessions = sessions || jsonb_build_object(p_week, p_date::text)
   where id = p_id;
  if not found then raise exception '找不到这个班'; end if;
end $$;

create or replace function public.stop_class(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_teacher() then raise exception '要先登入老师账号'; end if;
  update public.classes set open = false, finishing = false, closed_at = now() where id = p_id;
end $$;

-- 老师：重设 PIN
create or replace function public.regen_pin(p_student uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  p text;
begin
  if not public.is_teacher() then raise exception '要先登入老师账号'; end if;
  p := public.gen_pin();
  update public.students set pin = p where id = p_student;
  return p;
end $$;

-- 老师：打开老师页就记一下（6 天没来就推播提醒）
create or replace function public.teacher_ping()
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_teacher() then
    update private.teacher_activity set last_seen = now() where id = 1;
  end if;
end $$;

-- 老师：备份状态、文件用量
create or replace function public.backup_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g private.google;
  b private.backup_state;
begin
  if not public.is_teacher() then return null; end if;
  select * into g from private.google where id = 1;
  select * into b from private.backup_state where id = 1;
  return jsonb_build_object(
    'connected', g.refresh_token is not null, 'email', g.email, 'connected_at', g.connected_at,
    'last_at', b.last_at, 'last_try', b.last_try, 'last_error', b.last_error);
end $$;

create or replace function public.storage_usage()
returns bigint language sql stable security definer set search_path = public as $$
  select case when public.is_teacher() then coalesce(sum(size), 0)::bigint else 0 end from public.teacher_files;
$$;

-- =====================================================================
-- 只给 Edge Function（service role）用的函数
-- =====================================================================

create or replace function public.svc_cron_ok(p_secret text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from private.app_secrets where key = 'cron' and value = p_secret);
$$;

-- 学生登入：按「名字」算打错次数（中心全部学生是同一个 IP）
create or replace function public.svc_login_locked(p_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select count(*) >= 10 from private.login_failures
  where name_key = p_key and at > now() - interval '10 minutes';
$$;

create or replace function public.svc_login_fail(p_key text)
returns void language sql security definer set search_path = public as $$
  delete from private.login_failures where at < now() - interval '1 day';
  insert into private.login_failures (name_key) values (p_key);
$$;

create or replace function public.svc_login_clear(p_key text)
returns void language sql security definer set search_path = public as $$
  delete from private.login_failures where name_key = p_key;
$$;

create or replace function public.svc_find_student(p_key text, p_pin text)
returns table (id uuid, name text, auth_user_id uuid)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.auth_user_id from public.students s
  where lower(regexp_replace(btrim(s.name), '\s+', ' ', 'g')) = p_key and s.pin = p_pin
  limit 1;
$$;

create or replace function public.svc_set_auth_user(p_student uuid, p_uid uuid)
returns void language sql security definer set search_path = public as $$
  update public.students set auth_user_id = p_uid where id = p_student;
$$;

-- 备份：资料有没有变（数量 + 最后改动时间）
create or replace function public.svc_data_stamp()
returns text language sql stable security definer set search_path = public as $$
  select md5(concat_ws('|',
    (select count(*) || ':' || coalesce(max(updated_at)::text, '') from public.classes),
    (select count(*) || ':' || coalesce(max(updated_at)::text, '') from public.students),
    (select count(*) || ':' || coalesce(max(updated_at)::text, '') from public.progress),
    (select count(*) || ':' || coalesce(max(updated_at)::text, '') from public.class_notes),
    (select count(*) || ':' || coalesce(max(updated_at)::text, '') from public.teacher_files)));
$$;

create or replace function public.svc_backup_info()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'stamp', public.svc_data_stamp(),
    'last_stamp', (select last_stamp from private.backup_state where id = 1),
    'refresh_token', (select refresh_token from private.google where id = 1),
    'folder_id', (select folder_id from private.google where id = 1));
$$;

create or replace function public.svc_backup_export()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'app', '自动工程实作课 云端版',
    'exported_at', now(),
    'classes', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.classes c), '[]'::jsonb),
    'students', coalesce((select jsonb_agg(to_jsonb(s) - 'auth_user_id' order by s.level, s.name) from public.students s), '[]'::jsonb),
    'progress', coalesce((select jsonb_agg(to_jsonb(p) order by p.student_id, p.week) from public.progress p), '[]'::jsonb),
    'class_notes', coalesce((select jsonb_agg(to_jsonb(n) order by n.class_id, n.week) from public.class_notes n), '[]'::jsonb),
    'teacher_files', coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at) from public.teacher_files f), '[]'::jsonb));
$$;

create or replace function public.svc_backup_done(p_stamp text, p_folder text, p_error text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_error is null then
    update private.backup_state set last_stamp = p_stamp, last_at = now(), last_try = now(), last_error = null where id = 1;
    if p_folder is not null then
      update private.google set folder_id = p_folder where id = 1;
    end if;
  else
    update private.backup_state set last_try = now(), last_error = left(p_error, 500) where id = 1;
  end if;
end $$;

create or replace function public.svc_google_save(p_refresh text, p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update private.google
     set refresh_token = p_refresh, email = p_email,
         connected_at = case when p_refresh is null then null else now() end
   where id = 1;
  update private.backup_state set last_stamp = null, last_error = null where id = 1;   -- 马上备份一次
end $$;

create or replace function public.svc_backup_force()
returns void language sql security definer set search_path = public as $$
  update private.backup_state set last_stamp = null where id = 1;
$$;

create or replace function public.svc_folder_reset()
returns void language sql security definer set search_path = public as $$
  update private.google set folder_id = null where id = 1;
$$;

-- 6 天没有老师登入 → 回传要推播的装置（一天最多提醒一次，早上 9 点到晚上 9 点）
create or replace function public.svc_reminder_due()
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare
  a private.teacher_activity;
  h int := extract(hour from (now() at time zone 'Asia/Kuala_Lumpur'));
begin
  select * into a from private.teacher_activity where id = 1;
  if a.last_seen is null or a.last_seen > now() - interval '6 days' then return; end if;
  if a.last_reminded is not null and a.last_reminded > now() - interval '20 hours' then return; end if;
  if h < 9 or h >= 21 then return; end if;
  update private.teacher_activity set last_reminded = now() where id = 1;
  return query select p.sub from public.push_subs p;
end $$;

create or replace function public.svc_push_all()
returns setof jsonb language sql stable security definer set search_path = public as $$
  select p.sub from public.push_subs p;
$$;

create or replace function public.svc_push_remove(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_subs where endpoint = p_endpoint;
$$;

-- ---------------------------------------------------------------------
-- 函数权限：svc_* 只给 service role；其他给登入的人（函数里面自己会检查）
-- ---------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('is_teacher', 'touch_updated_at', 'gen_class_code', 'gen_pin', 'ping', 'whoami', 'my_progress',
                        'my_files', 'can_read_file', 'start_class', 'stop_class', 'regen_pin', 'teacher_ping',
                        'backup_status', 'storage_usage')
       or p.proname like 'svc\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'svc\_%' then
      execute format('grant execute on function %s to service_role', f.sig);
    elsif f.proname = 'ping' then
      execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated, service_role', f.sig);
    end if;
  end loop;
end $$;

-- =====================================================================
-- Storage：老师的文件（私人，单个最多 30 MB）
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('teacher-files', 'teacher-files', false, 31457280)
on conflict (id) do update set public = false, file_size_limit = 31457280;

drop policy if exists "teacher files: teacher all" on storage.objects;
create policy "teacher files: teacher all" on storage.objects for all to authenticated
  using (bucket_id = 'teacher-files' and public.is_teacher())
  with check (bucket_id = 'teacher-files' and public.is_teacher());

drop policy if exists "teacher files: student read" on storage.objects;
create policy "teacher files: student read" on storage.objects for select to authenticated
  using (bucket_id = 'teacher-files' and public.can_read_file(name));

-- =====================================================================
-- 定时：每分钟叫一次 Edge Function「tasks」（备份 + 提醒）
-- =====================================================================
do $$
begin
  if exists (select 1 from cron.job where jobname = 'iot-tasks') then
    perform cron.unschedule('iot-tasks');
  end if;
end $$;

select cron.schedule(
  'iot-tasks',
  '* * * * *',
  $cron$
  select net.http_post(
    url := 'https://tqotlmqqutcklnvrqoom.supabase.co/functions/v1/tasks',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select value from private.app_secrets where key = 'cron')),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 30000);
  $cron$
);

-- 清掉 cron 自己的旧纪录（一天一次），不然每分钟一笔会越积越多
do $$
begin
  if exists (select 1 from cron.job where jobname = 'iot-cron-cleanup') then
    perform cron.unschedule('iot-cron-cleanup');
  end if;
end $$;

select cron.schedule(
  'iot-cron-cleanup',
  '17 3 * * *',
  $cron$ delete from cron.job_run_details where end_time < now() - interval '3 days'; $cron$
);

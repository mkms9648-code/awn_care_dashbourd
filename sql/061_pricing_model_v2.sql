-- ============================================================================
-- Migration 061: نموذج التسعير v2 — معنى مختلف للعدّ لكل موديول، رصيد إضافي
-- يدوي، أسعار مرجعية على الباقة، وتعبئة كتالوج الباقات الحقيقي.
-- ============================================================================
-- السياق: صاحب المنتج كتب استراتيجية تسعير مفصّلة (Patient Cards مش AI
-- messages هي الوحدة المحاسَبية). العدّ الحالي (058/059) بيعامل كل الموديولات
-- بنفس الشكل: count(*) من encounters من بداية الفترة. ده مش كافي:
--   - Clinic لازم يتحسب "مرضى فريدين" مش "زيارات" (نفس المريض يرجع في نفس
--     الشهر لمتابعة = نفس الكارت، مش كارت جديد).
--   - Inpatient ("Active Patients") لازم يتحسب "لقطة حالية" (قد ايه سرير
--     مشغول دلوقتي) مش تراكمي على الفترة كلها.
--   - ED يفضل زي ما هو (حالات اتفتحت الفترة دي).
--   - Follow-up موديول جديد كليًا، مصدره portal_access_codes مش encounters.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) توسيع module_key عشان يشمل followup
-- ----------------------------------------------------------------------------

do $$
declare v_conname text;
begin
  select conname into v_conname
    from pg_constraint
   where conrelid = 'public.plan_quotas'::regclass
     and pg_get_constraintdef(oid) ilike '%module_key%';
  if v_conname is not null then
    execute format('alter table public.plan_quotas drop constraint %I', v_conname);
  end if;
end $$;

alter table public.plan_quotas
  add constraint plan_quotas_module_key_check
  check (module_key = any (array['ed','round','clinic','followup']));

-- ----------------------------------------------------------------------------
-- 2) رصيد إضافي يدوي (extra cards) — الإدارة بتبيعه بره المنصة (تليفون/واتساب)
--    وبتسجله هنا. بيتصفّر لوحده كل تجديد (created_at >= plan_renewed_at بس).
-- ----------------------------------------------------------------------------

create table if not exists public.workspace_quota_addons (
  id             uuid not null default gen_random_uuid(),
  workspace_id   uuid not null references public.workspaces(id),
  module_key     text not null check (module_key = any (array['ed','round','clinic','followup'])),
  extra_amount   integer not null check (extra_amount > 0),
  note           text,
  created_at     timestamptz not null default now(),
  constraint workspace_quota_addons_pkey primary key (id)
);

create index if not exists ix_workspace_quota_addons_ws
  on public.workspace_quota_addons (workspace_id, module_key, created_at);

create or replace function public.admin_grant_workspace_addon(
  p_workspace_id uuid, p_module_key text, p_extra_amount integer, p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;
  if p_module_key not in ('ed','round','clinic','followup') then
    raise exception 'AWN_BAD_INPUT: موديول مش معروف: %', p_module_key;
  end if;
  if p_extra_amount is null or p_extra_amount <= 0 then
    raise exception 'AWN_BAD_INPUT: الكمية لازم تكون رقم موجب.';
  end if;
  if not exists (select 1 from workspaces where id = p_workspace_id) then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  insert into workspace_quota_addons (workspace_id, module_key, extra_amount, note)
  values (p_workspace_id, p_module_key, p_extra_amount, nullif(btrim(coalesce(p_note,'')), ''));

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_grant_workspace_addon(uuid, text, integer, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 3) أسعار مرجعية على الباقة — للعرض في اللوحة بس، مفيش بوابة دفع في المشروع
--    أصلًا، فمفيش أي منطق محاسبي حقيقي متصل بيهم. الإدارة بتبيع/تجدد يدويًا.
-- ----------------------------------------------------------------------------

alter table public.plans
  add column if not exists price_monthly_egp integer,
  add column if not exists price_annual_egp  integer;

create or replace function public.admin_create_plan(
  p_key              text,
  p_name             text,
  p_max_staff        integer default null,
  p_max_workspaces   integer default null,
  p_price_monthly_egp integer default null,
  p_price_annual_egp  integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_id uuid;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;
  if coalesce(btrim(p_key), '') = '' or coalesce(btrim(p_name), '') = '' then
    raise exception 'AWN_BAD_INPUT: المفتاح والاسم مطلوبين.';
  end if;
  if exists (select 1 from plans where key = btrim(p_key)) then
    raise exception 'AWN_BAD_INPUT: فيه باقة بنفس المفتاح ده أصلًا.';
  end if;

  insert into plans (key, name, max_staff, max_workspaces, is_active, price_monthly_egp, price_annual_egp)
  values (btrim(p_key), btrim(p_name), p_max_staff, p_max_workspaces, true, p_price_monthly_egp, p_price_annual_egp)
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end;
$$;
grant execute on function public.admin_create_plan(text, text, integer, integer, integer, integer) to authenticated;

create or replace function public.admin_update_plan(
  p_plan_id          uuid,
  p_name             text,
  p_max_staff        integer default null,
  p_max_workspaces   integer default null,
  p_is_active        boolean default true,
  p_price_monthly_egp integer default null,
  p_price_annual_egp  integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'AWN_BAD_INPUT: الاسم مطلوب.';
  end if;

  update plans
     set name = btrim(p_name), max_staff = p_max_staff,
         max_workspaces = p_max_workspaces, is_active = p_is_active,
         price_monthly_egp = p_price_monthly_egp, price_annual_egp = p_price_annual_egp
   where id = p_plan_id;

  if not found then
    raise exception 'AWN_NOT_FOUND: باقة مش موجودة.';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_update_plan(uuid, text, integer, integer, boolean, integer, integer) to authenticated;

-- admin_feature_catalog (059) لازم يرجّع السعرين كمان عشان صفحة الباقات تعرضهم.
create or replace function public.admin_feature_catalog()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  return jsonb_build_object(
    'features', coalesce((
      select jsonb_agg(to_jsonb(f) order by f.key)
      from (
        select f.key, f.label, f.description,
               b.key as bot_key
          from features f
          left join bots b on b.feature_key = f.key
      ) f
    ), '[]'::jsonb),
    'plans', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.name)
      from (
        select p.id, p.key, p.name, p.max_staff, p.max_workspaces, p.is_active,
               p.price_monthly_egp, p.price_annual_egp,
               (select coalesce(array_agg(pf.feature_key order by pf.feature_key), '{}')
                  from plan_features pf where pf.plan_id = p.id) as feature_keys,
               coalesce((
                 select jsonb_agg(jsonb_build_object('module_key', pq.module_key, 'max_per_period', pq.max_per_period)
                          order by pq.module_key)
                   from plan_quotas pq where pq.plan_id = p.id
               ), '[]'::jsonb) as quotas,
               (select count(*) from workspaces w where w.plan_id = p.id) as workspaces_count
          from plans p
      ) p
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.admin_feature_catalog() to authenticated;

-- ----------------------------------------------------------------------------
-- 4) إعادة كتابة منطق العدّ — كل موديول له شكل استعلام مختلف، مش CASE واحد.
--    نفس المنطق لازم يتكرر في app_plan_usage (جانب الدكتور) و
--    admin_workspace_usage (جانب الإدارة) عشان الرقمين ما يختلفوش.
-- ----------------------------------------------------------------------------

create or replace function public.app_plan_usage(
  p_platform text, p_bot_key text, p_chat_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c              app_ctx;
  v_plan_id      uuid;
  v_renewed_at   timestamptz;
  v_period_days  integer;
  v_modules      jsonb := '[]'::jsonb;
  q              record;
  v_used         integer;
  v_addon        integer;
  v_max          integer;
begin
  c := app_bind_any(p_platform, p_chat_id);

  select w.plan_id, w.plan_renewed_at, w.plan_period_days
    into v_plan_id, v_renewed_at, v_period_days
    from workspaces w where w.id = c.workspace_id;

  for q in select * from plan_quotas where plan_id = v_plan_id order by module_key loop
    if q.module_key = 'clinic' then
      select count(distinct e.patient_id) into v_used from encounters e
       where e.workspace_id = c.workspace_id and e.source = 'clinic' and e.opened_at >= v_renewed_at;
    elsif q.module_key = 'round' then
      select count(*) into v_used from encounters e
       where e.workspace_id = c.workspace_id and e.status = 'active' and e.current_unit_id is not null;
    elsif q.module_key = 'followup' then
      select count(*) into v_used from portal_access_codes pc
       where pc.workspace_id = c.workspace_id and pc.revoked_at is null;
    else -- ed
      select count(*) into v_used from encounters e
       where e.workspace_id = c.workspace_id and e.source = 'ed' and e.current_unit_id is null
         and e.opened_at >= v_renewed_at;
    end if;

    select coalesce(sum(extra_amount), 0) into v_addon from workspace_quota_addons
     where workspace_id = c.workspace_id and module_key = q.module_key and created_at >= v_renewed_at;
    v_max := q.max_per_period + v_addon;

    v_modules := v_modules || jsonb_build_object(
      'module_key', q.module_key, 'max_per_period', v_max, 'used', v_used);

    if v_used >= (v_max * 0.9) and not exists (
      select 1 from notifications
       where workspace_id = c.workspace_id and staff_id is null
         and kind = 'quota_alert' and created_at >= v_renewed_at
         and title = 'اقتراب انتهاء حد ' || q.module_key
    ) then
      insert into notifications (workspace_id, staff_id, title, body, kind)
      values (c.workspace_id, null, 'اقتراب انتهاء حد ' || q.module_key,
              'استخدمت ' || v_used || ' من ' || v_max || ' المسموحين هذا الشهر.',
              'quota_alert');
    end if;
  end loop;

  return jsonb_build_object(
    'days_until_renewal', greatest(0, ceil(extract(epoch from
      (v_renewed_at + (v_period_days || ' days')::interval - now())) / 86400))::int,
    'modules', v_modules
  );
end;
$$;
grant execute on function public.app_plan_usage(text,text,text) to anon;

create or replace function public.admin_workspace_usage(p_workspace_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_plan_id     uuid;
  v_renewed_at  timestamptz;
  v_period_days integer;
  v_modules     jsonb := '[]'::jsonb;
  q             record;
  v_used        integer;
  v_addon       integer;
  v_max         integer;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  select w.plan_id, w.plan_renewed_at, w.plan_period_days
    into v_plan_id, v_renewed_at, v_period_days
    from workspaces w where w.id = p_workspace_id;

  if v_renewed_at is null then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  for q in select * from plan_quotas where plan_id = v_plan_id order by module_key loop
    if q.module_key = 'clinic' then
      select count(distinct e.patient_id) into v_used from encounters e
       where e.workspace_id = p_workspace_id and e.source = 'clinic' and e.opened_at >= v_renewed_at;
    elsif q.module_key = 'round' then
      select count(*) into v_used from encounters e
       where e.workspace_id = p_workspace_id and e.status = 'active' and e.current_unit_id is not null;
    elsif q.module_key = 'followup' then
      select count(*) into v_used from portal_access_codes pc
       where pc.workspace_id = p_workspace_id and pc.revoked_at is null;
    else -- ed
      select count(*) into v_used from encounters e
       where e.workspace_id = p_workspace_id and e.source = 'ed' and e.current_unit_id is null
         and e.opened_at >= v_renewed_at;
    end if;

    select coalesce(sum(extra_amount), 0) into v_addon from workspace_quota_addons
     where workspace_id = p_workspace_id and module_key = q.module_key and created_at >= v_renewed_at;
    v_max := q.max_per_period + v_addon;

    v_modules := v_modules || jsonb_build_object(
      'module_key', q.module_key, 'max_per_period', v_max, 'used', v_used);
  end loop;

  return jsonb_build_object(
    'plan_renewed_at', v_renewed_at,
    'plan_period_days', v_period_days,
    'days_until_renewal', greatest(0, ceil(extract(epoch from
      (v_renewed_at + (v_period_days || ' days')::interval - now())) / 86400))::int,
    'modules', v_modules
  );
end;
$$;
grant execute on function public.admin_workspace_usage(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5) تعبئة كتالوج الباقات الحقيقي (Clinic/ER/Inpatient/Follow-up/Doctor Pro/Team)
-- ----------------------------------------------------------------------------
-- ملاحظتين مهمتين على القرارات هنا (مش موجودة نصًا عند صاحب المنتج، قرار تنفيذ):
--   - Doctor Pro: مفيش أرقام "Patient Cards" محددة في وصفه (بس "كل الموديولات
--     في مكان واحد") — سيبتها من غير plan_quotas (يعني بلا حد) بدل ما أخترع رقم.
--   - Team plans: الوصف الأصلي بيدي رقم واحد "Patient Cards مشتركة" (500/1000/
--     2000/5000) من غير تفصيل بين ed/round/clinic. الـschema الحالي بيعدّ كل
--     موديول لوحده، فمفيش "حوض مشترك عبر الموديولات" جاهز. الحل المؤقت هنا:
--     نفس الرقم اتحط كحد لكل موديول لوحده (يعني عمليًا سقف أعلى من المقصود لو
--     العميل استخدم أكتر من موديول بالتوازي) — لازم يترفع كملاحظة لصاحب
--     المنتج، وحل نظيف لاحقًا هو موديول "total" مجمّع عبر الكل.

insert into public.plans (key, name, price_monthly_egp, price_annual_egp) values
  ('clinic_100',   'Clinic 100',    999,  9990),
  ('clinic_250',   'Clinic 250',    1999, 19990),
  ('clinic_500',   'Clinic 500',    3499, 34990),
  ('clinic_1000',  'Clinic 1000',   5999, 59990),
  ('er_100',       'Emergency 100', 1499, 14990),
  ('er_250',       'Emergency 250', 2749, 27490),
  ('er_500',       'Emergency 500', 4499, 44990),
  ('er_1000',      'Emergency 1000',7499, 74990),
  ('inpatient_50',  'Inpatient 50',  1499, 14990),
  ('inpatient_100', 'Inpatient 100', 2499, 24990),
  ('inpatient_250', 'Inpatient 250', 4999, 49990),
  ('inpatient_500', 'Inpatient 500', 8499, 84990),
  ('followup_50',   'Follow-up 50',  499,  4990),
  ('followup_150',  'Follow-up 150', 999,  9990),
  ('followup_500',  'Follow-up 500', 2499, 24990),
  ('doctor_pro',    'Doctor Pro',    2999, 29990),
  ('team_3',        'Team 3',        5999, 59990),
  ('team_5',        'Team 5',        8999, 89990),
  ('team_10',       'Team 10',       14999,149990),
  ('team_20',       'Team 20',       24999,249990)
on conflict (key) do update set
  name = excluded.name, price_monthly_egp = excluded.price_monthly_egp, price_annual_egp = excluded.price_annual_egp;

update public.plans set max_staff = 3  where key = 'team_3';
update public.plans set max_staff = 5  where key = 'team_5';
update public.plans set max_staff = 10 where key = 'team_10';
update public.plans set max_staff = 20 where key = 'team_20';

-- ميزات كل باقة (clinic_module/ed_module/round_module/patient_portal_module)
insert into public.plan_features (plan_id, feature_key)
select p.id, 'clinic_module' from plans p
 where p.key in ('clinic_100','clinic_250','clinic_500','clinic_1000','doctor_pro','team_3','team_5','team_10','team_20')
on conflict do nothing;

insert into public.plan_features (plan_id, feature_key)
select p.id, 'ed_module' from plans p
 where p.key in ('er_100','er_250','er_500','er_1000','doctor_pro','team_3','team_5','team_10','team_20')
on conflict do nothing;

insert into public.plan_features (plan_id, feature_key)
select p.id, 'round_module' from plans p
 where p.key in ('inpatient_50','inpatient_100','inpatient_250','inpatient_500','doctor_pro','team_3','team_5','team_10','team_20')
on conflict do nothing;

insert into public.plan_features (plan_id, feature_key)
select p.id, 'patient_portal_module' from plans p
 where p.key in ('followup_50','followup_150','followup_500','doctor_pro','team_3','team_5','team_10','team_20')
on conflict do nothing;

-- حدود الاستخدام الشهرية (plan_quotas) — Doctor Pro عمدًا من غيرها (بلا حد).
insert into public.plan_quotas (plan_id, module_key, max_per_period)
select p.id, 'clinic', 100  from plans p where p.key = 'clinic_100'
union all select p.id, 'clinic', 250  from plans p where p.key = 'clinic_250'
union all select p.id, 'clinic', 500  from plans p where p.key = 'clinic_500'
union all select p.id, 'clinic', 1000 from plans p where p.key = 'clinic_1000'
union all select p.id, 'ed', 100  from plans p where p.key = 'er_100'
union all select p.id, 'ed', 250  from plans p where p.key = 'er_250'
union all select p.id, 'ed', 500  from plans p where p.key = 'er_500'
union all select p.id, 'ed', 1000 from plans p where p.key = 'er_1000'
union all select p.id, 'round', 50  from plans p where p.key = 'inpatient_50'
union all select p.id, 'round', 100 from plans p where p.key = 'inpatient_100'
union all select p.id, 'round', 250 from plans p where p.key = 'inpatient_250'
union all select p.id, 'round', 500 from plans p where p.key = 'inpatient_500'
union all select p.id, 'followup', 50  from plans p where p.key = 'followup_50'
union all select p.id, 'followup', 150 from plans p where p.key = 'followup_150'
union all select p.id, 'followup', 500 from plans p where p.key = 'followup_500'
-- Team: نفس الرقم المشترك اتحط سقف لكل موديول لوحده (ملاحظة التبسيط فوق)
union all select p.id, 'ed',     500  from plans p where p.key = 'team_3'
union all select p.id, 'round',  500  from plans p where p.key = 'team_3'
union all select p.id, 'clinic', 500  from plans p where p.key = 'team_3'
union all select p.id, 'ed',     1000 from plans p where p.key = 'team_5'
union all select p.id, 'round',  1000 from plans p where p.key = 'team_5'
union all select p.id, 'clinic', 1000 from plans p where p.key = 'team_5'
union all select p.id, 'ed',     2000 from plans p where p.key = 'team_10'
union all select p.id, 'round',  2000 from plans p where p.key = 'team_10'
union all select p.id, 'clinic', 2000 from plans p where p.key = 'team_10'
union all select p.id, 'ed',     5000 from plans p where p.key = 'team_20'
union all select p.id, 'round',  5000 from plans p where p.key = 'team_20'
union all select p.id, 'clinic', 5000 from plans p where p.key = 'team_20'
on conflict (plan_id, module_key) do update set max_per_period = excluded.max_per_period;

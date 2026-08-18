-- ============================================================================
-- Migration 059: تحكم إداري كامل — إدارة الباقات (CRUD)، حدود الاستخدام من
-- لوحة التحكم، ألوان مساحة العمل (theme)، وسجل الإشعارات المُرسلة.
-- ============================================================================
-- الباقات (plans) لحد دلوقتي كانت بتتدار يدويًا من Supabase مباشرة — مفيش
-- CRUD في الداشبورد. الميجريشن ده بيقفل الفجوة دي + بيبني فوق جدول
-- plan_quotas اللي اتضاف في 058 (تحديد "قد ايه" لكل موديول لكل باقة) + بيضيف
-- عمود theme لمساحة العمل عشان الداشبورد يتحكم في ألوان التطبيق.
--
-- كل الدوال هنا SECURITY DEFINER + app_is_admin() أول حاجة، ومتاحة لـ
-- authenticated بس — نفس نمط 020/025/058 بالظبط.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) إدارة الباقات (CRUD) — كانت ناقصة تمامًا من الداشبورد
-- ----------------------------------------------------------------------------

create or replace function public.admin_create_plan(
  p_key            text,
  p_name           text,
  p_max_staff      integer default null,
  p_max_workspaces integer default null
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

  insert into plans (key, name, max_staff, max_workspaces, is_active)
  values (btrim(p_key), btrim(p_name), p_max_staff, p_max_workspaces, true)
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end;
$$;
grant execute on function public.admin_create_plan(text, text, integer, integer) to authenticated;

create or replace function public.admin_update_plan(
  p_plan_id        uuid,
  p_name           text,
  p_max_staff      integer default null,
  p_max_workspaces integer default null,
  p_is_active      boolean default true
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
         max_workspaces = p_max_workspaces, is_active = p_is_active
   where id = p_plan_id;

  if not found then
    raise exception 'AWN_NOT_FOUND: باقة مش موجودة.';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_update_plan(uuid, text, integer, integer, boolean) to authenticated;

-- حذف باقة — مرفوض لو فيه مساحة عمل مربوطة بيها، عشان مينفعش تسيب workspace
-- بـ plan_id يتيم. الإدارة لازم تنقل العملاء لباقة تانية الأول.
create or replace function public.admin_delete_plan(p_plan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_in_use integer;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  select count(*) into v_in_use from workspaces where plan_id = p_plan_id;
  if v_in_use > 0 then
    raise exception 'AWN_IN_USE: الباقة دي مستخدمة في % مساحة عمل — انقلهم لباقة تانية الأول.', v_in_use;
  end if;

  delete from plan_quotas where plan_id = p_plan_id;
  delete from plan_features where plan_id = p_plan_id;
  delete from plans where id = p_plan_id;

  if not found then
    raise exception 'AWN_NOT_FOUND: باقة مش موجودة.';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_delete_plan(uuid) to authenticated;

-- تشغيل/إيقاف ميزة في باقة (بيغيّر plan_features، مش feature_overrides —
-- ده الافتراضي اللي كل عملاء الباقة بيورثوه، لسه ينفع يتجاوز لكل عميل).
create or replace function public.admin_set_plan_feature(
  p_plan_id      uuid,
  p_feature_key  text,
  p_enabled      boolean
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
  if not exists (select 1 from features where key = p_feature_key) then
    raise exception 'AWN_BAD_INPUT: ميزة مش معروفة: %', p_feature_key;
  end if;

  if p_enabled then
    insert into plan_features (plan_id, feature_key) values (p_plan_id, p_feature_key)
    on conflict do nothing;
  else
    delete from plan_features where plan_id = p_plan_id and feature_key = p_feature_key;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_set_plan_feature(uuid, text, boolean) to authenticated;

-- حد الاستخدام الشهري لكل موديول في الباقة — p_max_per_period = null يعني
-- بلا حد (بيمسح الصف، زي ما app_plan_usage بيتوقع: صف غائب = مفيش قفل).
create or replace function public.admin_set_plan_quota(
  p_plan_id        uuid,
  p_module_key     text,
  p_max_per_period integer
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
  if p_module_key not in ('ed','round','clinic') then
    raise exception 'AWN_BAD_INPUT: موديول مش معروف: %', p_module_key;
  end if;

  if p_max_per_period is null then
    delete from plan_quotas where plan_id = p_plan_id and module_key = p_module_key;
  else
    if p_max_per_period <= 0 then
      raise exception 'AWN_BAD_INPUT: الحد لازم يكون رقم موجب.';
    end if;
    insert into plan_quotas (plan_id, module_key, max_per_period)
    values (p_plan_id, p_module_key, p_max_per_period)
    on conflict (plan_id, module_key) do update set max_per_period = excluded.max_per_period;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_set_plan_quota(uuid, text, integer) to authenticated;

-- إعادة تعريف admin_feature_catalog (من 025) + إضافة quotas لكل باقة، عشان
-- صفحة إدارة الباقات ترسم القيم الحالية من غير نداء إضافي لكل باقة.
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
-- 2) استخدام الباقة — منظور الإدارة (نفس منطق app_plan_usage بالظبط، لكن من
--    غير هوية دكتور — الإدارة بتشوف أي مساحة عمل مباشرة بـ workspace_id).
-- ----------------------------------------------------------------------------

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
    select count(*) into v_used from encounters e
     where e.workspace_id = p_workspace_id
       and e.opened_at >= v_renewed_at
       and case q.module_key
             when 'clinic' then e.source = 'clinic'
             when 'round'  then e.current_unit_id is not null
             else e.source = 'ed' and e.current_unit_id is null
           end;

    v_modules := v_modules || jsonb_build_object(
      'module_key', q.module_key, 'max_per_period', q.max_per_period, 'used', v_used);
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

-- تغيير مدة دورة الباقة لمساحة عمل معيّنة (افتراضي 30 يوم من 058).
create or replace function public.admin_set_workspace_period_days(p_workspace_id uuid, p_period_days integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;
  if p_period_days is null or p_period_days <= 0 then
    raise exception 'AWN_BAD_INPUT: عدد الأيام لازم يكون رقم موجب.';
  end if;

  update workspaces set plan_period_days = p_period_days, updated_at = now()
   where id = p_workspace_id;

  if not found then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_set_workspace_period_days(uuid, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 3) ألوان مساحة العمل (theme) — نظام ألوان كامل يتحكم فيه من الداشبورد.
--    مفاتيح مسموحة بس: primary / primary_light / accent / critical / success
--    (نفس الأدوار الموجودة فعليًا في AppTheme بتاع تطبيق الفلاتر).
-- ----------------------------------------------------------------------------

alter table public.workspaces add column if not exists theme jsonb not null default '{}'::jsonb;

create or replace function public.admin_set_workspace_theme(p_workspace_id uuid, p_theme jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_allowed text[] := array['primary','primary_light','accent','critical','success'];
  k text;
  v text;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  for k in select jsonb_object_keys(coalesce(p_theme, '{}'::jsonb)) loop
    if not (k = any(v_allowed)) then
      raise exception 'AWN_BAD_INPUT: مفتاح لون مش معروف: %', k;
    end if;
    v := p_theme ->> k;
    if v !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'AWN_BAD_INPUT: لون غير صالح لـ % (لازم صيغة #RRGGBB): %', k, v;
    end if;
  end loop;

  update workspaces set theme = coalesce(p_theme, '{}'::jsonb), updated_at = now()
   where id = p_workspace_id;

  if not found then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  return jsonb_build_object('ok', true, 'theme', coalesce(p_theme, '{}'::jsonb));
end;
$$;
grant execute on function public.admin_set_workspace_theme(uuid, jsonb) to authenticated;

-- إعادة تعريف admin_workspace_detail (من 027) + إضافة theme + بيانات
-- الاستخدام الأساسية (تاريخ التجديد ومدة الدورة) في كائن workspace.
create or replace function public.admin_workspace_detail(p_workspace_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_ws        workspaces%rowtype;
  v_effective text[];
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  select * into v_ws from workspaces where id = p_workspace_id;
  if not found then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  v_effective := app_effective_features(p_workspace_id);

  return jsonb_build_object(
    'workspace', (
      select to_jsonb(x) from (
        select w.id, w.name, w.plan_id, w.feature_overrides, w.org_id, w.logo,
               w.theme, w.plan_renewed_at, w.plan_period_days,
               p.name as plan_name, p.key as plan_key,
               o.name as org_name, o.kind as org_kind,
               (select count(*) from staff s
                  where s.workspace_id = w.id and s.role = 'doctor') as doctors_count
          from workspaces w
          join orgs o on o.id = w.org_id
          left join plans p on p.id = w.plan_id
         where w.id = p_workspace_id
      ) x
    ),
    'features', coalesce((
      select jsonb_agg(to_jsonb(fx) order by fx.key)
      from (
        select f.key, f.label, f.description,
               b.key as bot_key,
               exists (select 1 from plan_features pf
                        where pf.plan_id = v_ws.plan_id and pf.feature_key = f.key) as in_plan,
               (v_ws.feature_overrides ->> f.key)::boolean as override,
               (f.key = any(v_effective)) as effective
          from features f
          left join bots b on b.feature_key = f.key
      ) fx
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.admin_workspace_detail(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4) سجل الإشعارات المُرسلة — عشان صفحة الإعلانات تعرض آخر اللي اتبعت
-- ----------------------------------------------------------------------------

create or replace function public.admin_notifications_history(
  p_workspace_id uuid default null,
  p_limit        integer default 30
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

  return coalesce((
    select jsonb_agg(to_jsonb(t))
    from (
      select n.id, n.title, n.body, n.kind, n.created_at,
             (n.staff_id is null) as is_broadcast,
             w.name as workspace_name, s.full_name as staff_name
        from notifications n
        join workspaces w on w.id = n.workspace_id
        left join staff s on s.id = n.staff_id
       where n.kind = 'announcement'
         and (p_workspace_id is null or n.workspace_id = p_workspace_id)
       order by n.created_at desc
       limit greatest(1, coalesce(p_limit, 30))
    ) t
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_notifications_history(uuid, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 5) إعادة تعريف admin_list_doctors (من 025) + إضافة feature_overrides —
--    محتاجاها صفحة "تجربة الدكتور" عشان ترسم توجل تشغيل/وراثة/إيقاف لكل
--    موديول لكل دكتور (admin_set_staff_feature من 058).
-- ----------------------------------------------------------------------------

create or replace function public.admin_list_doctors(
  p_workspace_id uuid default null
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

  return coalesce((
    select jsonb_agg(to_jsonb(t) order by t.workspace_name, t.full_name)
    from (
      select s.id as staff_id, s.full_name, s.specialty, s.status,
             s.license_no, s.last_active_at, s.created_at, s.feature_overrides,
             w.id as workspace_id, w.name as workspace_name,
             o.name as org_name,
             (select sc.external_id from staff_channels sc
               where sc.staff_id = s.id and sc.platform = 'mobile' and sc.is_active
               limit 1) as mobile_code,
             coalesce((
               select jsonb_agg(jsonb_build_object(
                        'channel_id', sc.id, 'platform', sc.platform,
                        'bot_key', sc.bot_key, 'external_id', sc.external_id,
                        'is_active', sc.is_active) order by sc.platform, sc.bot_key)
                 from staff_channels sc where sc.staff_id = s.id
             ), '[]'::jsonb) as channels
        from staff s
        join workspaces w on w.id = s.workspace_id
        join orgs o       on o.id = s.org_id
       where s.role = 'doctor'
         and (p_workspace_id is null or s.workspace_id = p_workspace_id)
    ) t
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.admin_list_doctors(uuid) to authenticated;

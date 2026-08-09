-- ============================================================================
-- Migration 025: داشبورد المدير — طبقة "التحكم" (كتابة)، مش مجرد عرض
-- ============================================================================
-- 020_admin_dashboard.sql عمل الطبقة اللي بتعرض (قراءة فقط):
--   admin_workspaces_overview / admin_case_counts / admin_conversations_feed.
-- الميجريشن ده بيضيف طبقة التحكم الفعلي اللي بيستخدمها فولدر awn-admin/ عشان
-- المدير يقدر (بزراير ونوافذ) يـ:
--   1) يفعّل/يوقف كل ميزة (module) لكل مساحة عمل — على مستوى العميل الواحد.
--      بيكتب في workspaces.feature_overrides اللي app_effective_features بيقراه
--      فعلًا، فالزرار بيتحكم في الوصول الحقيقي مش مجرد شكل.
--   2) يغيّر باقة مساحة العمل.
--   3) يدير الأطباء: إنشاء دكتور + إصدار/إعادة كود دخول للتطبيق + إيقاف/تفعيل
--      + تفعيل/إيقاف كل قناة.
--
-- كل الدوال هنا SECURITY DEFINER + بتتحقق app_is_admin() الأول (نفس نمط 020)،
-- ومتاحة لـ authenticated بس (المدير المسجّل دخوله)، مش anon.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0) تشديد صلاحية إصدار كود الدخول
-- ----------------------------------------------------------------------------
-- app_issue_mobile_login موجودة من 001/011 لكنها مش ممنوحة لأي role — بتتنفّذ
-- يدويًا. هنا بنغلّفها في admin_* عشان الداشبورد يستخدمها بأمان (بعد فحص الأدمن)،
-- من غير ما نمنح الأصلية لـ authenticated (تفضل جوّه SECURITY DEFINER بس).

-- ----------------------------------------------------------------------------
-- 1) كتالوج الباقات والمميزات — عشان الواجهة ترسم التوجلات والقوائم
-- ----------------------------------------------------------------------------

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
               b.key as bot_key   -- الميزة مربوطة ببوت؟ (ed_module→ed ...)
          from features f
          left join bots b on b.feature_key = f.key
      ) f
    ), '[]'::jsonb),
    'plans', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.name)
      from (
        select p.id, p.key, p.name, p.max_staff, p.max_workspaces, p.is_active,
               (select coalesce(array_agg(pf.feature_key order by pf.feature_key), '{}')
                  from plan_features pf where pf.plan_id = p.id) as feature_keys
          from plans p
      ) p
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.admin_feature_catalog() to authenticated;

-- ----------------------------------------------------------------------------
-- 2) تفاصيل مساحة عمل واحدة — الباقة + حالة كل ميزة (باقة/تجاوز/فعّال)
-- ----------------------------------------------------------------------------
-- لكل ميزة بنرجّع:
--   in_plan   : الباقة بتديها؟
--   override  : null (وراثة) / true (تفعيل يدوي) / false (إيقاف يدوي)
--   effective : الوصول الفعلي دلوقتي (نفس منطق app_effective_features)
-- عشان التوجل يبان ثلاثي الحالة (تشغيل/إيقاف/وراثة) بدقة.

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
        select w.id, w.name, w.plan_id, w.feature_overrides, w.org_id,
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
-- 3) توجل ميزة لمساحة عمل — الزرار الأساسي في صفحة الاشتراكات
-- ----------------------------------------------------------------------------
-- p_state: 'on' (تفعيل يدوي) / 'off' (إيقاف يدوي) / 'inherit' (رجوع للباقة).
-- بيكتب/بيمسح المفتاح في feature_overrides — اللي app_effective_features بيقراه.

create or replace function public.admin_set_workspace_feature(
  p_workspace_id uuid,
  p_feature_key  text,
  p_state        text
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

  if p_state = 'on' then
    update workspaces
       set feature_overrides = feature_overrides || jsonb_build_object(p_feature_key, true),
           updated_at = now()
     where id = p_workspace_id;
  elsif p_state = 'off' then
    update workspaces
       set feature_overrides = feature_overrides || jsonb_build_object(p_feature_key, false),
           updated_at = now()
     where id = p_workspace_id;
  elsif p_state = 'inherit' then
    update workspaces
       set feature_overrides = feature_overrides - p_feature_key,
           updated_at = now()
     where id = p_workspace_id;
  else
    raise exception 'AWN_BAD_INPUT: p_state لازم تبقى on/off/inherit.';
  end if;

  if not found then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  return admin_workspace_detail(p_workspace_id);
end;
$$;

grant execute on function public.admin_set_workspace_feature(uuid, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 4) تغيير باقة مساحة العمل
-- ----------------------------------------------------------------------------

create or replace function public.admin_set_workspace_plan(
  p_workspace_id uuid,
  p_plan_id      uuid      -- null = بدون باقة
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

  if p_plan_id is not null and not exists (select 1 from plans where id = p_plan_id) then
    raise exception 'AWN_BAD_INPUT: باقة مش موجودة.';
  end if;

  update workspaces set plan_id = p_plan_id, updated_at = now()
   where id = p_workspace_id;

  if not found then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  return admin_workspace_detail(p_workspace_id);
end;
$$;

grant execute on function public.admin_set_workspace_plan(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5) قائمة الأطباء بالتحكم — حالة + قنوات + كود الدخول الحالي
-- ----------------------------------------------------------------------------
-- كود دخول التطبيق = external_id لقناة platform='mobile' نشطة (نفس الكود لكل
-- البوتات). بنرجّع القنوات كمصفوفة عشان الواجهة تعرض/تتحكم في كل واحدة.

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
             s.license_no, s.last_active_at, s.created_at,
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

-- ----------------------------------------------------------------------------
-- 6) إنشاء دكتور جديد
-- ----------------------------------------------------------------------------
-- بيشتق org_id من مساحة العمل. بيبدأ active. مش بيصدر كود هنا — الواجهة بتنادي
-- admin_issue_doctor_login بعده عشان تعرض الكود في نافذة منفصلة.

create or replace function public.admin_create_doctor(
  p_workspace_id uuid,
  p_full_name    text,
  p_specialty    text default null,
  p_license_no   text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_org_id uuid;
  v_id     uuid;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  if coalesce(btrim(p_full_name), '') = '' then
    raise exception 'AWN_BAD_INPUT: الاسم مطلوب.';
  end if;

  select org_id into v_org_id from workspaces where id = p_workspace_id;
  if v_org_id is null then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  insert into staff (org_id, workspace_id, full_name, role, specialty, license_no, status)
  values (v_org_id, p_workspace_id, btrim(p_full_name), 'doctor',
          nullif(btrim(coalesce(p_specialty, '')), ''),
          nullif(btrim(coalesce(p_license_no, '')), ''), 'active')
  returning id into v_id;

  return jsonb_build_object('staff_id', v_id);
end;
$$;

grant execute on function public.admin_create_doctor(uuid, text, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 7) إصدار / إعادة إصدار كود دخول التطبيق للدكتور
-- ----------------------------------------------------------------------------
-- p_reset=false: يصدر كود لو مفيش (يستخدم app_issue_mobile_login كما هي).
-- p_reset=true : يبطّل قنوات mobile القديمة ويصدر كود جديد (تغيير "الباسورد").
-- بيرجّع الكود الجديد عشان يتعرض للمدير مرة واحدة في نافذة.

create or replace function public.admin_issue_doctor_login(
  p_staff_id uuid,
  p_reset    boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_code text;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  if not exists (select 1 from staff where id = p_staff_id and role = 'doctor') then
    raise exception 'AWN_NOT_FOUND: الدكتور مش موجود.';
  end if;

  if p_reset then
    -- إلغاء أي كود mobile قديم قبل إصدار جديد (app_issue بيعمل on conflict do nothing)
    delete from staff_channels
     where staff_id = p_staff_id and platform = 'mobile';
  end if;

  -- لو فيه كود نشط بالفعل ومش reset — رجّعه زي ما هو
  select external_id into v_code from staff_channels
   where staff_id = p_staff_id and platform = 'mobile' and is_active
   limit 1;

  if v_code is null then
    -- مفيش كود نشط (جديد أو بعد إنهاء خدمة) — امسح أي بقايا mobile قديمة
    -- عشان app_issue_mobile_login تدخل صف نظيف بدل ما تسيب صفوف معطّلة مكررة
    delete from staff_channels
     where staff_id = p_staff_id and platform = 'mobile';
    v_code := app_issue_mobile_login(p_staff_id);
  end if;

  return jsonb_build_object('code', v_code);
end;
$$;

grant execute on function public.admin_issue_doctor_login(uuid, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 8) تغيير حالة الدكتور (تفعيل / إيقاف / معلّق)
-- ----------------------------------------------------------------------------

create or replace function public.admin_set_doctor_status(
  p_staff_id uuid,
  p_status   text
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

  if p_status not in ('active','suspended','pending') then
    raise exception 'AWN_BAD_INPUT: حالة مش معروفة: %', p_status;
  end if;

  update staff set status = p_status, updated_at = now()
   where id = p_staff_id and role = 'doctor';

  if not found then
    raise exception 'AWN_NOT_FOUND: الدكتور مش موجود.';
  end if;

  return jsonb_build_object('staff_id', p_staff_id, 'status', p_status);
end;
$$;

grant execute on function public.admin_set_doctor_status(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 9) تفعيل / إيقاف قناة واحدة (مثلًا إيقاف بوت معيّن للدكتور)
-- ----------------------------------------------------------------------------

create or replace function public.admin_set_channel_active(
  p_channel_id uuid,
  p_is_active  boolean
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

  update staff_channels set is_active = p_is_active
   where id = p_channel_id;

  if not found then
    raise exception 'AWN_NOT_FOUND: القناة مش موجودة.';
  end if;

  return jsonb_build_object('channel_id', p_channel_id, 'is_active', p_is_active);
end;
$$;

grant execute on function public.admin_set_channel_active(uuid, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 10) إنهاء خدمة دكتور (إلغاء آمن قابل للرجوع) — بدل الحذف النهائي
-- ----------------------------------------------------------------------------
-- الحذف النهائي بيصطدم بمفاتيح أجنبية (encounters بتشير لـ staff)، فالإلغاء
-- الآمن = تعليق الحالة + إيقاف كل القنوات. يقدر يترجّع بإعادة التفعيل + كود جديد.

create or replace function public.admin_offboard_doctor(p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  update staff set status = 'suspended', updated_at = now()
   where id = p_staff_id and role = 'doctor';

  if not found then
    raise exception 'AWN_NOT_FOUND: الدكتور مش موجود.';
  end if;

  update staff_channels set is_active = false where staff_id = p_staff_id;

  return jsonb_build_object('staff_id', p_staff_id, 'status', 'suspended');
end;
$$;

grant execute on function public.admin_offboard_doctor(uuid) to authenticated;

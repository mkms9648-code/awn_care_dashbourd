-- ============================================================================
-- Migration 058: تتبع استخدام الباقة + تحكم لكل دكتور + مركز إشعارات
-- ============================================================================
-- ثلاث أنظمة مرتبطة ببعض (كلهم "تحكم إداري" في الأساس)، بنيت في ميجريشن واحدة:
--
-- 1) Plan Usage — حد شهري اختياري لكل موديول (ED/Round/Clinic) لكل باقة،
--    و"حالة" = زيارة جديدة (encounter) زي ما اتأكد. تاريخ تجديد لكل مساحة
--    عمل (plan_renewed_at) بيحدد بداية الفترة الحالية.
-- 2) تحكم لكل دكتور في الموديولات اللي يشوفها — طبقة إضافية فوق
--    feature_overrides بتاعة مساحة العمل كلها (مش بديل)، بتضيّق بس مش بتوسّع:
--    لو مساحة العمل مفعّلة Clinic، الإدارة تقدر تقفلها لدكتور معيّن بس، لكن
--    مينفعش دكتور يشوف موديول أصلاً موقوف على مستوى مساحة العمل كلها.
-- 3) مركز إشعارات — جدول واحد بيغذّي تاب "Notifications" في البروفايل،
--    ومصدره حاجتين: أخبار/تحديثات بيبعتها صاحب المؤسسة يدويًا من لوحة
--    التحكم، أو تنبيهات تلقائية لما استخدام موديول يقرب من حد الباقة.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Plan Usage
-- ----------------------------------------------------------------------------

-- حد شهري لكل (باقة، موديول) — صف غائب = بلا حد. mirrors plan_features بالظبط.
create table if not exists public.plan_quotas (
  plan_id        uuid not null,
  module_key     text not null check (module_key = any (array['ed','round','clinic'])),
  max_per_period integer not null,
  constraint plan_quotas_pkey primary key (plan_id, module_key),
  constraint plan_quotas_plan_id_fkey foreign key (plan_id) references public.plans(id)
);

-- تاريخ آخر تجديد لكل مساحة عمل — بيحدد بداية "الفترة الحالية" لحساب
-- الاستخدام، وبيتحسب منه العد التنازلي لأيام التجديد.
alter table public.workspaces
  add column if not exists plan_renewed_at timestamptz not null default now(),
  add column if not exists plan_period_days integer not null default 30;

-- حل هوية خفيف — بيستخدم أي قناة نشطة للدكتور بغض النظر عن الـ bot_key
-- (بلا فحص ميزة/بوت محدد)، عشان البروفايل/الاستخدام/الإشعارات معلومات
-- حساب عامة مش خاصة بموديول معيّن — دكتور مشترك في Clinic بس لازم يقدر
-- يشوفها برضه، مش بس اللي مشتركين في ED (اللي app_bind كان هيقفلها عليهم
-- لو استخدمنا bot_key ثابت زي 'ed' هنا).
create or replace function public.app_bind_any(p_platform text, p_chat_id text)
returns app_ctx
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c app_ctx;
begin
  select s.id, s.org_id, s.workspace_id, s.role, s.full_name, sc.bot_key
    into c.staff_id, c.org_id, c.workspace_id, c.role, c.full_name, c.bot_key
    from staff_channels sc
    join staff s on s.id = sc.staff_id
   where sc.platform = p_platform and sc.external_id = p_chat_id and sc.is_active
   limit 1;

  if c.staff_id is null then
    raise exception 'AWN_STAFF_NOT_FOUND';
  end if;

  return c;
end;
$$;

-- استخدام الباقة الحالي — جانب الدكتور، لتاب البروفايل. بيرجّع مصفوفة بس
-- للموديولات اللي عليها حد فعلي (مفيش حد = مش هيبان، "غير محدود" ضمنيًا).
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
begin
  c := app_bind_any(p_platform, p_chat_id);

  select w.plan_id, w.plan_renewed_at, w.plan_period_days
    into v_plan_id, v_renewed_at, v_period_days
    from workspaces w where w.id = c.workspace_id;

  for q in select * from plan_quotas where plan_id = v_plan_id order by module_key loop
    select count(*) into v_used from encounters e
     where e.workspace_id = c.workspace_id
       and e.opened_at >= v_renewed_at
       and case q.module_key
             when 'clinic' then e.source = 'clinic'
             when 'round'  then e.current_unit_id is not null
             else e.source = 'ed' and e.current_unit_id is null
           end;

    v_modules := v_modules || jsonb_build_object(
      'module_key', q.module_key, 'max_per_period', q.max_per_period, 'used', v_used);

    -- تنبيه اقتراب انتهاء الحد (90%+) — مرة واحدة بس لكل فترة/موديول، بيتأكد
    -- بفحص إشعار سابق من نفس النوع اتسجل بعد بداية الفترة الحالية قبل ما يضيف.
    if v_used >= (q.max_per_period * 0.9) and not exists (
      select 1 from notifications
       where workspace_id = c.workspace_id and staff_id is null
         and kind = 'quota_alert' and created_at >= v_renewed_at
         and title = 'اقتراب انتهاء حد ' || q.module_key
    ) then
      insert into notifications (workspace_id, staff_id, title, body, kind)
      values (c.workspace_id, null, 'اقتراب انتهاء حد ' || q.module_key,
              'استخدمت ' || v_used || ' من ' || q.max_per_period || ' المسموحين هذا الشهر.',
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

-- إعادة ضبط تاريخ التجديد — فعل إداري بس (زرار "تم التجديد" في لوحة التحكم).
create or replace function public.admin_renew_workspace_plan(p_workspace_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  update workspaces set plan_renewed_at = now(), updated_at = now() where id = p_workspace_id;
  if not found then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  return jsonb_build_object('renewed_at', now());
end;
$$;

grant execute on function public.admin_renew_workspace_plan(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 2) تحكم لكل دكتور — طبقة إضافية فوق feature_overrides بتاعة مساحة العمل
-- ----------------------------------------------------------------------------

alter table public.staff
  add column if not exists feature_overrides jsonb not null default '{}'::jsonb;

-- إعادة تعريف app_bind — نفس المنطق الأصلي بالكامل + فحص إضافي واحد بس بعد
-- فحص مساحة العمل: لو الإدارة قفلت البوت ده تحديدًا على الدكتور ده (قيمة
-- false صريحة)، يترفض حتى لو مساحة العمل نفسها مفعّلة له الميزة. غياب أي
-- قيمة (null) = مفيش تقييد إضافي، يفضل زي ما مساحة العمل قررت.
create or replace function public.app_bind(p_platform text, p_bot_key text, p_chat_id text, p_touch boolean default true)
returns app_ctx
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  c app_ctx;
  v_status  text;
  v_plan    uuid;
  v_enabled boolean;
  v_staff_overrides jsonb;
  v_feature_key text;
  v_staff_narrow boolean;
begin
  select s.id, s.org_id, s.workspace_id, s.role, s.full_name, sc.bot_key,
         s.status, w.plan_id, s.feature_overrides
    into c.staff_id, c.org_id, c.workspace_id, c.role, c.full_name, c.bot_key,
         v_status, v_plan, v_staff_overrides
    from staff_channels sc
    join staff      s on s.id = sc.staff_id
    join workspaces w on w.id = s.workspace_id
   where sc.platform    = p_platform
     and sc.bot_key     = p_bot_key
     and sc.external_id = p_chat_id
     and sc.is_active;

  if c.staff_id is null then
    raise exception 'AWN_STAFF_NOT_FOUND';
  end if;
  if v_status = 'pending' then
    raise exception 'AWN_STAFF_PENDING: حسابك تحت المراجعة.';
  end if;
  if v_status = 'suspended' then
    raise exception 'AWN_STAFF_SUSPENDED: حسابك موقوف.';
  end if;
  if v_plan is null then
    raise exception 'AWN_NO_PLAN: مفيش باقة مربوطة بمساحة العمل.';
  end if;

  select b.feature_key into v_feature_key from bots b where b.key = p_bot_key;

  select app_has_feature(c.workspace_id, v_feature_key) into v_enabled;
  if not coalesce(v_enabled, false) then
    raise exception 'AWN_BOT_NOT_ENABLED: البوت ده مش مفعّل في باقتك.';
  end if;

  v_staff_narrow := (v_staff_overrides ->> v_feature_key)::boolean;
  if v_staff_narrow is not null and not v_staff_narrow then
    raise exception 'AWN_BOT_RESTRICTED: الوصول للبوت ده متقفل عليك من الإدارة.';
  end if;

  perform set_config('app.staff_id', c.staff_id::text, true);
  perform set_config('app.org_id',   c.org_id::text,   true);

  if p_touch then
    update staff set last_active_at = now() where id = c.staff_id;
  end if;

  return c;
end $function$;

-- توجل ميزة لطبيب معيّن — نفس شكل admin_set_workspace_feature بالظبط.
-- p_state: 'on' (يفضل زي مساحة العمل، بيمسح أي تقييد سابق) / 'off' (يتقفل
-- عليه حتى لو مساحة العمل مفعّلة) — مفيش 'on' فعلي بمعنى "زيادة عن مساحة
-- العمل"، ده مقصود (شرحناه فوق).
create or replace function public.admin_set_staff_feature(
  p_staff_id uuid, p_feature_key text, p_state text
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

  if p_state = 'off' then
    update staff
       set feature_overrides = feature_overrides || jsonb_build_object(p_feature_key, false),
           updated_at = now()
     where id = p_staff_id;
  elsif p_state = 'on' then
    update staff
       set feature_overrides = feature_overrides - p_feature_key,
           updated_at = now()
     where id = p_staff_id;
  else
    raise exception 'AWN_BAD_INPUT: p_state لازم يبقى on/off.';
  end if;

  if not found then
    raise exception 'AWN_NOT_FOUND: الطبيب مش موجود.';
  end if;

  return jsonb_build_object('staff_id', p_staff_id, 'feature_key', p_feature_key, 'state', p_state);
end;
$$;

grant execute on function public.admin_set_staff_feature(uuid,text,text) to authenticated;

-- ----------------------------------------------------------------------------
-- 3) مركز الإشعارات
-- ----------------------------------------------------------------------------

-- staff_id = null يعني إشعار عام لكل الدكاترة في مساحة العمل (بث)؛ قيمة
-- محددة = إشعار شخصي (تنبيه اقتراب انتهاء الباقة مثلًا مبعوت لكل الدكاترة
-- كصفوف منفصلة، أو مستقبلًا إشعار خاص بطبيب واحد).
create table if not exists public.notifications (
  id                 uuid not null default gen_random_uuid(),
  workspace_id       uuid not null,
  staff_id           uuid,
  title              text not null,
  body               text not null,
  kind               text not null default 'announcement'
                     check (kind = any (array['announcement','quota_alert'])),
  created_at         timestamptz not null default now(),
  read_at            timestamptz,
  created_by_staff_id uuid,
  constraint notifications_pkey primary key (id),
  constraint notifications_workspace_id_fkey foreign key (workspace_id) references public.workspaces(id),
  constraint notifications_staff_id_fkey foreign key (staff_id) references public.staff(id)
);

create index if not exists ix_notifications_staff
  on public.notifications (workspace_id, staff_id, created_at desc);

-- قائمة إشعارات الطبيب — بث مساحة العمل (staff_id is null) + الشخصية بتاعته،
-- الأحدث أولًا.
create or replace function public.app_notifications_list(
  p_platform text, p_bot_key text, p_chat_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c app_ctx;
begin
  c := app_bind_any(p_platform, p_chat_id);

  return jsonb_build_object(
    'results', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', n.id, 'title', n.title, 'body', n.body, 'kind', n.kind,
               'created_at', n.created_at, 'read_at', n.read_at)
             order by n.created_at desc)
        from notifications n
       where n.workspace_id = c.workspace_id
         and (n.staff_id is null or n.staff_id = c.staff_id)), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.app_notifications_list(text,text,text) to anon;

create or replace function public.app_notifications_mark_read(
  p_platform text, p_bot_key text, p_chat_id text, p_notification_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c app_ctx;
begin
  c := app_bind_any(p_platform, p_chat_id);

  update notifications
     set read_at = now()
   where id = p_notification_id
     and workspace_id = c.workspace_id
     and (staff_id is null or staff_id = c.staff_id)
     and read_at is null;
end;
$$;

grant execute on function public.app_notifications_mark_read(text,text,text,uuid) to anon;

-- إرسال إشعار (أخبار/تحديثات) — إداري بس. p_staff_id null = بث لكل مساحة
-- العمل. بيرجّع توكنات FCM المتأثرة عشان اللي بينادي (لوحة التحكم) يبعتهم
-- لـ n8n لإرسال push فعلي — نفس فصل الاهتمامات المستخدم في app_portal_escalate.
create or replace function public.admin_send_notification(
  p_workspace_id uuid, p_staff_id uuid, p_title text, p_body text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_id uuid;
  v_tokens text[];
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  -- created_by_staff_id سايبينه فاضي عمدًا — الإداري مش صف staff أصلاً (هوية
  -- منفصلة تمامًا، بتتحقق بـ app_is_admin() عن طريق Supabase Auth مش app_bind).
  insert into notifications (workspace_id, staff_id, title, body, kind)
  values (p_workspace_id, p_staff_id, p_title, p_body, 'announcement')
  returning id into v_id;

  select array_agg(distinct fcm_token) into v_tokens
    from staff
   where workspace_id = p_workspace_id
     and fcm_token is not null
     and (p_staff_id is null or id = p_staff_id);

  return jsonb_build_object('notification_id', v_id, 'push_tokens', coalesce(to_jsonb(v_tokens), '[]'::jsonb));
end;
$$;

grant execute on function public.admin_send_notification(uuid,uuid,text,text) to authenticated;

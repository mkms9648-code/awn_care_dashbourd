-- ============================================================================
-- Migration 060: دور الممرض/ة + مهام على الأوردرات (Nurse + Task workflow)
-- ============================================================================
-- staff.role أصلًا بيسمح بـ 'nurse' من الاسكيمة الأساسية (متسجلة بس مش
-- مستخدمة لحد دلوقتي). الميزة دي بتفعّلها فعليًا: الدكتور يعيّن أوردر موجود
-- (تحليل/أشعة/إجراء تمريضي...) لممرض/ة معيّنة، هي تقبله/تبدأه/تخلّصه من قايمة
-- مهامها الخاصة، والدكتور يشوف النتيجة تلقائيًا على كارت المريض العادي —
-- بتوسيع جدول orders الموجود بدل بناء جدول tasks موازي (orders أصلًا فيه
-- category/status/resolved_by_staff_id، وcommitments.owner_staff_id سابقة
-- موجودة فعلًا لـ"تعيين صف لموظف معيّن" في نفس الاسكيمة).
--
-- تحذير هيكلي: app_invalid_target/app_project/app_patient_summary/
-- app_issue_mobile_login/app_resolve_staff دوال كبيرة بتخدم كل أنواع الأحداث —
-- النسخ تحت منسوخة حرفيًا من آخر نسخة موثّقة فعليًا (اتفحصت مباشرة، مش افتراض):
--   app_invalid_target   → من migration 019 (آخر تعريف)
--   app_project          → من migration 018 (آخر تعريف — 019 ماعدلتوش)
--   app_patient_summary  → من migration 019 (آخر تعريف)
--   app_issue_mobile_login → من migration 049 (آخر تعريف)
--   app_resolve_staff    → من migration 050 (آخر تعريف — لاحظ إنها فعليًا
--     بسّطت الدالة وشالت الحلقة اللي كانت بتجرب كل بوت_key بالتتابع اللي كانت
--     موجودة في 011/017 — بقت بتنادي app_bind بمفتاح واحد بس زي ما اتبعت).
-- التعديل في كل واحدة محدد بتعليق CHANGED/ADDED.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) أعمدة جديدة على orders — إضافية وآمنة بالكامل
-- ----------------------------------------------------------------------------

alter table public.orders
  add column if not exists assigned_to_staff_id      uuid references public.staff(id),
  add column if not exists task_assigned_by_staff_id  uuid references public.staff(id),
  add column if not exists task_assigned_at           timestamptz,
  add column if not exists task_status text
    check (task_status = any (array['assigned','accepted','in_progress','completed']));

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.orders'::regclass and conname = 'orders_task_status_consistency'
  ) then
    alter table public.orders
      add constraint orders_task_status_consistency
      check ((assigned_to_staff_id is null) = (task_status is null));
  end if;
end $$;

-- توسيع category: نفس القيم زائد general (مهام عامة) وvitals (قياسات) —
-- الإجراءات التمريضية (IV/حقن/تغيير ضمادة/قسطرة) أصلًا بتدخل في procedure.
do $$
declare v_conname text;
begin
  select conname into v_conname
    from pg_constraint
   where conrelid = 'public.orders'::regclass
     and pg_get_constraintdef(oid) ilike '%category%';
  if v_conname is not null then
    execute format('alter table public.orders drop constraint %I', v_conname);
  end if;
end $$;

alter table public.orders
  add constraint orders_category_check
  check (category = any (array['lab','imaging','consult','procedure','general','vitals']));

-- ----------------------------------------------------------------------------
-- 2) تسجيل بوت/ميزة التمريض — بيظهر تلقائيًا في شبكة الميزات بتاعة
--    admin_workspace_detail (join عام على features/bots)، مفيش تعديل مطلوب
--    في subscriptions.html.
-- ----------------------------------------------------------------------------

insert into public.features(key, label) values
  ('nurse_module', 'وحدة التمريض')
on conflict (key) do nothing;

insert into public.bots(key, label, feature_key) values
  ('nurse', 'بوت التمريض', 'nurse_module')
on conflict (key) do update set label = excluded.label, feature_key = excluded.feature_key;

-- ----------------------------------------------------------------------------
-- 3) app_issue_mobile_login — يفرّع حسب role: الممرض/ة تاخد قناة nurse بس
--    (سطح كتابة أضيق عمدًا)، والباقي زي ما هو (ed/round/clinic/portal).
-- ----------------------------------------------------------------------------

create or replace function public.app_issue_mobile_login(p_staff_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_code text := lpad((floor(random() * 1000000))::text, 6, '0');
  v_role text;
begin
  select role into v_role from staff where id = p_staff_id;

  if v_role = 'nurse' then -- ADDED (migration 060)
    insert into staff_channels (staff_id, platform, bot_key, external_id)
    values (p_staff_id, 'mobile', 'nurse', v_code)
    on conflict do nothing;
  else
    insert into staff_channels (staff_id, platform, bot_key, external_id)
    values
      (p_staff_id, 'mobile', 'ed', v_code),
      (p_staff_id, 'mobile', 'round', v_code),
      (p_staff_id, 'mobile', 'clinic', v_code),
      (p_staff_id, 'mobile', 'portal', v_code)
    on conflict do nothing;
  end if;

  return v_code;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4) app_resolve_staff — إصلاح تسجيل الدخول: الفلاتر بتنادي resolveStaff()
--    بـ p_bot_key='ed' ثابتة دايمًا (نفس آلية دخول الدكاترة، اللي أصلًا كل
--    دكتور عنده قناة ed بغض النظر عن باقته الحقيقية). الممرض/ة معندهاش قناة
--    ed خالص (سطح ضيق عمدًا) فكانت هتفشل من أول شاشة. الحل: الهوية بتتحل بـ
--    app_bind_any (بتاعة migration 058 — من غير فحص bot_key/ميزة)، وبنكرر هنا
--    يدويًا الفحصين اللي app_bind كانت بتعملهم (حالة الطاقم + set_config/touch)
--    عشان مفيش تراجع أمني. p_bot_key فاضل في التوقيع (الفلاتر لسه بتبعته)
--    بس مش بيتستخدم في الحل النهارده.
-- ----------------------------------------------------------------------------

create or replace function public.app_resolve_staff(
  p_platform text, p_bot_key text, p_chat_id text, p_device_id text default null
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  c app_ctx;
  v_status text;
  v_specialty text;
  v_license_no text;
  v_org_name text;
  v_plan_name text;
  v_plan_active boolean;
begin
  c := app_bind_any(p_platform, p_chat_id); -- CHANGED (migration 060): كان app_bind(p_platform, p_bot_key, p_chat_id)

  -- ADDED (migration 060) — app_bind_any مش بتعمل الفحوصات دي، بنكررها هنا يدويًا
  select status into v_status from staff where id = c.staff_id;
  if v_status = 'pending' then
    raise exception 'AWN_STAFF_PENDING: حسابك تحت المراجعة.';
  end if;
  if v_status = 'suspended' then
    raise exception 'AWN_STAFF_SUSPENDED: حسابك موقوف.';
  end if;
  perform set_config('app.staff_id', c.staff_id::text, true);
  perform set_config('app.org_id',   c.org_id::text,   true);
  update staff set last_active_at = now() where id = c.staff_id;

  select specialty, license_no into v_specialty, v_license_no
  from staff where id = c.staff_id;

  select o.name into v_org_name
  from orgs o where o.id = c.org_id;

  select p.name, p.is_active into v_plan_name, v_plan_active
  from workspaces w
  join plans p on p.id = w.plan_id
  where w.id = c.workspace_id;

  return jsonb_build_object(
    'staff_id',     c.staff_id,
    'org_id',       c.org_id,
    'workspace_id', c.workspace_id,
    'role',         c.role,
    'full_name',    c.full_name,
    'specialty',    v_specialty,
    'license_no',   v_license_no,
    'org_name',     v_org_name,
    'plan_name',    v_plan_name,
    'plan_active',  coalesce(v_plan_active, false),
    'features',     to_jsonb(app_effective_features(c.workspace_id))
  );
end $function$;

grant execute on function public.app_resolve_staff(text, text, text, text) to anon;

-- ----------------------------------------------------------------------------
-- 5) app_invalid_target — نسخة 019 حرفيًا + 4 حالات جديدة لدورة حياة المهمة
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.app_invalid_target(p_event_type text, p_payload jsonb, p_encounter_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id uuid; v_found boolean;
begin
  case p_event_type
    when 'order_completed' then
      v_id := nullif(p_payload->>'order_id','')::uuid;
      if v_id is null then return 'order_id_required'; end if;
      select exists(select 1 from orders
                     where id = v_id and encounter_id = p_encounter_id and status = 'pending')
        into v_found;
      if not v_found then return 'order_not_found_or_not_pending'; end if;

    when 'order_cancelled' then
      v_id := nullif(p_payload->>'order_id','')::uuid;
      if v_id is null then return 'order_id_required'; end if;
      select exists(select 1 from orders
                     where id = v_id and encounter_id = p_encounter_id and status = 'pending')
        into v_found;
      if not v_found then return 'order_not_found_or_not_pending'; end if;

    when 'order_reopened' then
      v_id := nullif(p_payload->>'order_id','')::uuid;
      if v_id is null then return 'order_id_required'; end if;
      select exists(select 1 from orders
                     where id = v_id and encounter_id = p_encounter_id
                       and status in ('completed','cancelled'))
        into v_found;
      if not v_found then return 'order_not_found_or_not_resolved'; end if;

    -- ==== ADDED (migration 060) — دورة حياة المهمة على الأوردر ====
    when 'order_task_assigned' then
      v_id := nullif(p_payload->>'order_id','')::uuid;
      if v_id is null then return 'order_id_required'; end if;
      if nullif(p_payload->>'staff_id','')::uuid is null then return 'staff_id_required'; end if;
      select exists(select 1 from orders
                     where id = v_id and encounter_id = p_encounter_id and status = 'pending')
        into v_found;
      if not v_found then return 'order_not_found_or_not_pending'; end if;
      if not exists(select 1 from staff
                      where id = (p_payload->>'staff_id')::uuid and role = 'nurse') then
        return 'staff_not_a_nurse';
      end if;

    when 'order_task_accepted' then
      v_id := nullif(p_payload->>'order_id','')::uuid;
      if v_id is null then return 'order_id_required'; end if;
      select exists(select 1 from orders
                     where id = v_id and encounter_id = p_encounter_id and task_status = 'assigned')
        into v_found;
      if not v_found then return 'task_not_found_or_not_assigned'; end if;

    when 'order_task_started' then
      v_id := nullif(p_payload->>'order_id','')::uuid;
      if v_id is null then return 'order_id_required'; end if;
      select exists(select 1 from orders
                     where id = v_id and encounter_id = p_encounter_id and task_status = 'accepted')
        into v_found;
      if not v_found then return 'task_not_found_or_not_accepted'; end if;

    when 'order_task_completed' then
      v_id := nullif(p_payload->>'order_id','')::uuid;
      if v_id is null then return 'order_id_required'; end if;
      select exists(select 1 from orders
                     where id = v_id and encounter_id = p_encounter_id and task_status = 'in_progress')
        into v_found;
      if not v_found then return 'task_not_found_or_not_in_progress'; end if;
    -- ==== end ADDED ====

    when 'medication_stopped' then
      v_id := nullif(p_payload->>'medication_id','')::uuid;
      if v_id is null then return 'medication_id_required'; end if;
      select exists(select 1 from medications
                     where id = v_id and encounter_id = p_encounter_id and status = 'active')
        into v_found;
      if not v_found then return 'medication_not_found_or_not_active'; end if;

    when 'commitment_closed' then
      v_id := nullif(p_payload->>'commitment_id','')::uuid;
      if v_id is null then return 'commitment_id_required'; end if;
      select exists(select 1 from commitments
                     where id = v_id and encounter_id = p_encounter_id and status = 'open')
        into v_found;
      if not v_found then return 'commitment_not_found_or_not_open'; end if;

    when 'complication_resolved' then
      v_id := nullif(p_payload->>'complication_id','')::uuid;
      if v_id is null then return 'complication_id_required'; end if;
      select exists(select 1 from complications
                     where id = v_id and encounter_id = p_encounter_id and resolved_at is null)
        into v_found;
      if not v_found then return 'complication_not_found_or_already_resolved'; end if;

    else
      return null;
  end case;

  return null;
end $function$;

-- ----------------------------------------------------------------------------
-- 6) app_project — نسخة 018 حرفيًا + 4 حالات جديدة + سطر واحد معدّل في
--    order_reopened (يرجّع task_status لـ assigned لو الأوردر معيّن أصلًا)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.app_project(e events)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_enc      encounters%rowtype;
  v_correct  boolean := e.corrects_event_id is not null;
  v_kept     uuid;
  v_merged   uuid;
begin
  if e.encounter_id is not null then
    select * into v_enc from encounters where id = e.encounter_id;
  end if;

  if v_correct then
    delete from vitals      where source_event_id = e.corrects_event_id;
    delete from notes       where source_event_id = e.corrects_event_id;
    delete from attachments where source_event_id = e.corrects_event_id;
  end if;

  case e.event_type

    when 'encounter_opened' then
      update encounters
         set status = 'active',
             opened_at = coalesce(opened_at, e.occurred_at),
             current_unit_id = coalesce((e.payload->>'unit_id')::uuid, current_unit_id),
             attending_staff_id = coalesce(
               (e.payload->>'attending_staff_id')::uuid, e.actor_staff_id)
       where id = e.encounter_id;

    when 'unit_transfer' then
      update encounters
         set current_unit_id = (e.payload->>'to_unit_id')::uuid
       where id = e.encounter_id;

    when 'discharge' then
      update encounters
         set status = 'discharged', discharged_at = e.occurred_at
       where id = e.encounter_id;

    when 'discharge_reverted' then
      if v_enc.status <> 'discharged' then
        raise exception 'AWN_REVERT_NOT_DISCHARGED: الزيارة مش مقفولة أصلاً.';
      end if;
      if exists (
        select 1 from encounters x
         where x.patient_id = v_enc.patient_id
           and x.id <> v_enc.id
           and x.opened_at > v_enc.discharged_at
      ) then
        raise exception
          'AWN_REVERT_BLOCKED: اتفتحت زيارة جديدة بعد الخروج. '
          'دمج الزيارات مش متاح في النسخة دي — كلّم الدعم.';
      end if;
      update encounters
         set status = 'active', discharged_at = null
       where id = e.encounter_id;

    when 'encounter_reassigned' then
      update encounters
         set attending_staff_id = (e.payload->>'to_staff_id')::uuid
       where id = e.encounter_id;

    when 'vitals_recorded' then
      insert into vitals(org_id, workspace_id, encounter_id, metric, value_num, unit,
                         measured_at, source_event_id)
      select e.org_id, e.workspace_id, e.encounter_id,
             r->>'metric', (r->>'value')::numeric, r->>'unit',
             (e.payload->>'measured_at')::timestamptz, e.id
        from jsonb_array_elements(e.payload->'readings') r;

    when 'note_added' then
      insert into notes(org_id, workspace_id, encounter_id, kind, body,
                        authored_at, source_event_id)
      values (e.org_id, e.workspace_id, e.encounter_id,
              e.payload->>'kind', e.payload->>'body', e.occurred_at, e.id);

    when 'attachment_added' then
      insert into attachments(id, org_id, workspace_id, encounter_id, kind, storage_path,
                              caption, uploaded_at, source_event_id)
      values (app_entity_id('attachment', e.id),
              e.org_id, e.workspace_id, e.encounter_id,
              e.payload->>'kind', e.payload->>'storage_path',
              e.payload->>'caption', e.occurred_at, e.id);

    when 'order_placed' then
      if v_correct then
        update orders
           set category = e.payload->>'category',
               name     = e.payload->>'name',
               ordered_at = e.occurred_at
         where source_event_id = e.corrects_event_id;
      else
        insert into orders(id, org_id, workspace_id, encounter_id, category, name,
                           ordered_at, source_event_id)
        values (app_entity_id('order', e.id),
                e.org_id, e.workspace_id, e.encounter_id,
                e.payload->>'category', e.payload->>'name', e.occurred_at, e.id);
      end if;

    when 'order_completed' then
      update orders
         set status='completed', resolved_at=e.occurred_at,
             resolved_by_staff_id=e.actor_staff_id
       where id = (e.payload->>'order_id')::uuid;

    when 'order_cancelled' then
      update orders
         set status='cancelled', resolved_at=e.occurred_at,
             resolved_by_staff_id=e.actor_staff_id
       where id = (e.payload->>'order_id')::uuid;

    when 'order_reopened' then
      update orders
         set status='pending', resolved_at=null, resolved_by_staff_id=null,
             task_status = case when assigned_to_staff_id is not null -- CHANGED (migration 060)
                                 then 'assigned' else null end
       where id = (e.payload->>'order_id')::uuid;

    -- ==== ADDED (migration 060) ====
    when 'order_task_assigned' then
      update orders
         set assigned_to_staff_id      = (e.payload->>'staff_id')::uuid,
             task_assigned_by_staff_id = e.actor_staff_id,
             task_assigned_at          = e.occurred_at,
             task_status               = 'assigned'
       where id = (e.payload->>'order_id')::uuid;

    when 'order_task_accepted' then
      update orders set task_status = 'accepted'
       where id = (e.payload->>'order_id')::uuid
         and assigned_to_staff_id = e.actor_staff_id;

    when 'order_task_started' then
      update orders set task_status = 'in_progress'
       where id = (e.payload->>'order_id')::uuid
         and assigned_to_staff_id = e.actor_staff_id;

    when 'order_task_completed' then
      update orders
         set task_status='completed', status='completed',
             resolved_at=e.occurred_at, resolved_by_staff_id=e.actor_staff_id
       where id = (e.payload->>'order_id')::uuid
         and assigned_to_staff_id = e.actor_staff_id;
    -- ==== end ADDED ====

    when 'medication_started' then
      if v_correct then
        update medications
           set name = e.payload->>'name',
               dose = e.payload->>'dose',
               route = e.payload->>'route',
               frequency = e.payload->>'frequency',
               starts_at = e.occurred_at,
               ends_at = (e.payload->>'ends_at')::timestamptz
         where source_event_id = e.corrects_event_id;
      else
        insert into medications(id, org_id, workspace_id, encounter_id, name, dose, route,
                                frequency, starts_at, ends_at, source_event_id)
        values (app_entity_id('med', e.id),
                e.org_id, e.workspace_id, e.encounter_id,
                e.payload->>'name', e.payload->>'dose', e.payload->>'route',
                e.payload->>'frequency', e.occurred_at,
                (e.payload->>'ends_at')::timestamptz, e.id);
      end if;

    when 'medication_stopped' then
      update medications set status='stopped', ends_at=e.occurred_at
       where id = (e.payload->>'medication_id')::uuid;

    when 'commitment_created' then
      if v_correct then
        update commitments
           set text_body = e.payload->>'text',
               owner_staff_id = (e.payload->>'owner_staff_id')::uuid,
               due_at = (e.payload->>'due_at')::timestamptz
         where source_event_id = e.corrects_event_id;
      else
        insert into commitments(id, org_id, workspace_id, encounter_id, text_body,
                                owner_staff_id, due_at, source_event_id)
        values (app_entity_id('commitment', e.id),
                e.org_id, e.workspace_id, e.encounter_id,
                e.payload->>'text', (e.payload->>'owner_staff_id')::uuid,
                (e.payload->>'due_at')::timestamptz, e.id);
      end if;

    when 'commitment_closed' then
      update commitments set status='done', resolved_at=e.occurred_at
       where id = (e.payload->>'commitment_id')::uuid;

    when 'commitment_reassigned' then
      update commitments
         set owner_staff_id = (e.payload->>'to_staff_id')::uuid
       where id = (e.payload->>'commitment_id')::uuid;

    when 'complication_opened' then
      if v_correct then
        update complications
           set description = e.payload->>'description', opened_at = e.occurred_at
         where source_event_id = e.corrects_event_id;
      else
        insert into complications(id, org_id, workspace_id, encounter_id, description,
                                  opened_at, source_event_id)
        values (app_entity_id('complication', e.id),
                e.org_id, e.workspace_id, e.encounter_id,
                e.payload->>'description', e.occurred_at, e.id);
      end if;

    when 'complication_resolved' then
      update complications set resolved_at=e.occurred_at
       where id = (e.payload->>'complication_id')::uuid;

    when 'patient_record_amended' then
      update patients
         set allergies = coalesce(
               (select array_agg(x) from jsonb_array_elements_text(e.payload->'allergies') x),
               allergies),
             chronic_conditions = coalesce(
               (select array_agg(x) from jsonb_array_elements_text(e.payload->'chronic_conditions') x),
               chronic_conditions),
             updated_at = now()
       where id = e.patient_id;

    when 'patients_merged' then
      v_kept   := (e.payload->>'kept_patient_id')::uuid;
      v_merged := (e.payload->>'merged_patient_id')::uuid;

      if v_kept = v_merged then
        raise exception 'AWN_MERGE_SELF: مينفعش تدمج ملف في نفسه.';
      end if;
      if exists (select 1 from patients where id = v_merged and status = 'merged') then
        raise exception 'AWN_ALREADY_MERGED: الملف ده مدموج قبل كده.';
      end if;
      if (select org_id from patients where id = v_kept)
         is distinct from (select org_id from patients where id = v_merged) then
        raise exception 'AWN_MERGE_CROSS_ORG: ممنوع الدمج عبر المؤسسات.';
      end if;

      update encounters set patient_id = v_kept where patient_id = v_merged;
      update patients
         set status = 'merged', merged_into_id = v_kept, updated_at = now()
       where id = v_merged;

    when 'staff_deactivated' then
      update staff
         set status = 'suspended', updated_at = now()
       where id = (e.payload->>'target_staff_id')::uuid;
      update staff_channels
         set is_active = false
       where staff_id = (e.payload->>'target_staff_id')::uuid;

    when 'staff_reactivated' then
      update staff
         set status = 'active', updated_at = now()
       where id = (e.payload->>'target_staff_id')::uuid;

    else
      null;
  end case;
end $function$;

-- ----------------------------------------------------------------------------
-- 7) app_patient_summary — نسخة 019 حرفيًا + assigned_to/task_status على
--    open_orders، عشان الدكتور يشوف مين متعيّن على الأوردر وحالة تنفيذه.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.app_patient_summary(p_platform text, p_bot_key text, p_chat_id text, p_encounter_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
AS $$
declare
  c   app_ctx;
  enc encounters%rowtype;
  pat patients%rowtype;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id);

  select * into enc from encounters
   where id = p_encounter_id and org_id = c.org_id;
  if enc is null then
    raise exception 'AWN_ENCOUNTER_NOT_FOUND';
  end if;

  select * into pat from patients where id = app_resolve_patient(enc.patient_id);

  return jsonb_build_object(
    'patient', jsonb_build_object(
      'id', pat.id, 'mrn', pat.mrn, 'name', pat.full_name,
      'sex', pat.sex, 'birth_year', pat.birth_year,
      'allergies', to_jsonb(pat.allergies),
      'chronic_conditions', to_jsonb(pat.chronic_conditions)),

    'encounter', jsonb_build_object(
      'id', enc.id, 'status', enc.status, 'source', enc.source,
      'opened_at', enc.opened_at, 'discharged_at', enc.discharged_at,
      'unit', (select name from units where id = enc.current_unit_id),
      'attending', (select full_name from staff where id = enc.attending_staff_id),
      'handle', (select handle from handles
                  where encounter_id = enc.id and released_at is null limit 1)),

    'latest_vitals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'metric', metric, 'value', value_num,
               'unit', unit, 'measured_at', measured_at,
               'event_id', source_event_id))
        from (select distinct on (metric) metric, value_num, unit, measured_at, source_event_id
                from vitals where encounter_id = enc.id
               order by metric, measured_at desc) v), '[]'::jsonb),

    'open_orders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'category', o.category, 'name', o.name, 'ordered_at', o.ordered_at,
               'status', o.status, 'resolved_at', o.resolved_at,
               'ordered_by', os.full_name,
               'resolved_by', s.full_name,
               'assigned_to', ns.full_name, -- ADDED (migration 060)
               'task_status', o.task_status, -- ADDED (migration 060)
               'event_id', o.source_event_id))
        from (select * from orders where encounter_id = enc.id
               order by (status = 'pending') desc, ordered_at desc limit 50) o
        left join staff s on s.id = o.resolved_by_staff_id
        left join staff ns on ns.id = o.assigned_to_staff_id -- ADDED (migration 060)
        left join events pe on pe.id = o.source_event_id
        left join staff os on os.id = pe.actor_staff_id), '[]'::jsonb),

    'active_medications', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', id, 'name', name, 'dose', dose, 'route', route,
               'frequency', frequency, 'starts_at', starts_at, 'ends_at', ends_at,
               'event_id', source_event_id))
        from (select * from medications where encounter_id = enc.id and status='active'
               order by starts_at limit 30) m), '[]'::jsonb),

    'open_commitments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c2.id, 'text', c2.text_body, 'due_at', c2.due_at,
               'overdue', (c2.due_at is not null and c2.due_at < now()),
               'owner', s.full_name, 'event_id', c2.source_event_id))
        from (select * from commitments where encounter_id = enc.id and status='open'
               order by due_at nulls last limit 30) c2
        left join staff s on s.id = c2.owner_staff_id), '[]'::jsonb),

    'open_complications', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', id, 'description', description, 'opened_at', opened_at,
               'event_id', source_event_id))
        from (select * from complications where encounter_id = enc.id
               and resolved_at is null order by opened_at limit 20) x), '[]'::jsonb),

    'recent_notes', coalesce((
      select jsonb_agg(jsonb_build_object('kind', kind, 'body', body, 'at', authored_at,
                                          'event_id', source_event_id))
        from (select * from notes where encounter_id = enc.id
               order by authored_at desc limit 5) n), '[]'::jsonb),

    'attachments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'kind', a.kind, 'storage_path', a.storage_path,
               'caption', a.caption, 'uploaded_at', a.uploaded_at,
               'uploaded_by', s.full_name, 'source_bot', e.source_bot))
        from (select * from attachments where encounter_id = enc.id
               order by uploaded_at desc limit 30) a
        join events e on e.id = a.source_event_id
        join staff  s on s.id = e.actor_staff_id), '[]'::jsonb)
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 8) دوال الممرض/ة — سطح كتابة ضيق عمدًا: 3 دوال بس، كل واحدة بتتحقق إن
--    الممرض/ة المنادية هي فعلًا المعيّنة على المهمة قبل ما تنادي
--    app_ingest_events بـ event_type ثابت من جوّه (مش بتاخد event_type من
--    الفلاتر خالص). app_nurse_task_list بترجّع أقل قدر لازم بس — مفيش
--    تاريخ مرضي كامل ولا أوردرات تانية.
-- ----------------------------------------------------------------------------

create or replace function public.app_nurse_task_list(p_platform text, p_bot_key text, p_chat_id text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare c app_ctx;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id);

  return jsonb_build_object('results', coalesce((
    select jsonb_agg(jsonb_build_object(
             'order_id', o.id,
             'encounter_id', o.encounter_id,
             'patient_name', p.full_name,
             'handle', (select handle from handles
                         where encounter_id = o.encounter_id and released_at is null limit 1),
             'unit', u.name,
             'category', o.category,
             'name', o.name,
             'task_status', o.task_status,
             'assigned_at', o.task_assigned_at,
             'assigned_by', ab.full_name)
           order by (o.task_status = 'completed') asc, o.task_assigned_at desc)
      from orders o
      join encounters e on e.id = o.encounter_id
      join patients p on p.id = e.patient_id
      left join units u on u.id = e.current_unit_id
      left join staff ab on ab.id = o.task_assigned_by_staff_id
     where o.assigned_to_staff_id = c.staff_id
       and o.task_status is not null
       and (o.task_status <> 'completed' or o.resolved_at > now() - interval '24 hours')), '[]'::jsonb));
end;
$$;
grant execute on function public.app_nurse_task_list(text,text,text) to anon;

create or replace function public.app_nurse_task_accept(p_platform text, p_bot_key text, p_chat_id text, p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare c app_ctx; o orders%rowtype;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id);
  select * into o from orders where id = p_order_id;
  if o is null then raise exception 'AWN_ORDER_NOT_FOUND'; end if;
  if o.assigned_to_staff_id is distinct from c.staff_id then
    raise exception 'AWN_NOT_YOUR_TASK: المهمة دي مش متعينة لك.';
  end if;

  return app_ingest_events(p_platform, p_bot_key, p_chat_id,
    jsonb_build_array(jsonb_build_object('event_type','order_task_accepted',
      'encounter_id', o.encounter_id, 'payload', jsonb_build_object('order_id', p_order_id))),
    false);
end;
$$;
grant execute on function public.app_nurse_task_accept(text,text,text,uuid) to anon;

create or replace function public.app_nurse_task_start(p_platform text, p_bot_key text, p_chat_id text, p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare c app_ctx; o orders%rowtype;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id);
  select * into o from orders where id = p_order_id;
  if o is null then raise exception 'AWN_ORDER_NOT_FOUND'; end if;
  if o.assigned_to_staff_id is distinct from c.staff_id then
    raise exception 'AWN_NOT_YOUR_TASK: المهمة دي مش متعينة لك.';
  end if;

  return app_ingest_events(p_platform, p_bot_key, p_chat_id,
    jsonb_build_array(jsonb_build_object('event_type','order_task_started',
      'encounter_id', o.encounter_id, 'payload', jsonb_build_object('order_id', p_order_id))),
    false);
end;
$$;
grant execute on function public.app_nurse_task_start(text,text,text,uuid) to anon;

create or replace function public.app_nurse_task_complete(
  p_platform text, p_bot_key text, p_chat_id text, p_order_id uuid, p_result_note text default null
)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare c app_ctx; o orders%rowtype; v_events jsonb;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id);
  select * into o from orders where id = p_order_id;
  if o is null then raise exception 'AWN_ORDER_NOT_FOUND'; end if;
  if o.assigned_to_staff_id is distinct from c.staff_id then
    raise exception 'AWN_NOT_YOUR_TASK: المهمة دي مش متعينة لك.';
  end if;

  v_events := jsonb_build_array(jsonb_build_object('event_type','order_task_completed',
    'encounter_id', o.encounter_id, 'payload', jsonb_build_object('order_id', p_order_id)));

  if nullif(btrim(coalesce(p_result_note,'')), '') is not null then
    v_events := v_events || jsonb_build_object('event_type','note_added',
      'encounter_id', o.encounter_id,
      'payload', jsonb_build_object('kind','result', 'body', o.name || ': ' || btrim(p_result_note)));
  end if;

  return app_ingest_events(p_platform, p_bot_key, p_chat_id, v_events, false);
end;
$$;
grant execute on function public.app_nurse_task_complete(text,text,text,uuid,text) to anon;

-- ----------------------------------------------------------------------------
-- 9) جانب الدكتور — تعيين/إعادة تعيين ممرض/ة + قايمة الممرضين/ات للاختيار
-- ----------------------------------------------------------------------------

create or replace function public.app_assign_order_task(
  p_platform text, p_bot_key text, p_chat_id text, p_order_id uuid, p_staff_id uuid
)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare c app_ctx; o orders%rowtype; v_push_token text;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id);

  select * into o from orders where id = p_order_id and org_id = c.org_id;
  if o is null then raise exception 'AWN_ORDER_NOT_FOUND'; end if;

  if not exists (select 1 from staff
                  where id = p_staff_id and role = 'nurse' and org_id = c.org_id) then
    raise exception 'AWN_STAFF_NOT_A_NURSE';
  end if;

  perform app_ingest_events(p_platform, p_bot_key, p_chat_id,
    jsonb_build_array(jsonb_build_object('event_type','order_task_assigned',
      'encounter_id', o.encounter_id,
      'payload', jsonb_build_object('order_id', p_order_id, 'staff_id', p_staff_id))),
    false);

  select fcm_token into v_push_token from staff where id = p_staff_id;

  return jsonb_build_object('order_id', p_order_id, 'staff_id', p_staff_id, 'push_token', v_push_token);
end;
$$;
grant execute on function public.app_assign_order_task(text,text,text,uuid,uuid) to anon;

create or replace function public.app_list_nurses(p_platform text, p_bot_key text, p_chat_id text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare c app_ctx;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id, false);
  return jsonb_build_object('results', coalesce((
    select jsonb_agg(jsonb_build_object('staff_id', id, 'full_name', full_name) order by full_name)
      from staff where workspace_id = c.workspace_id and role = 'nurse' and status = 'active'), '[]'::jsonb));
end;
$$;
grant execute on function public.app_list_nurses(text,text,text) to anon;

-- ----------------------------------------------------------------------------
-- 10) إدارة الممرضين/ات من لوحة التحكم — نظير مواز تمامًا لدوال admin_*_doctor
--     في 025_admin_control.sql، من غير أي تعديل على دوال الدكاترة نفسها.
-- ----------------------------------------------------------------------------

create or replace function public.admin_list_nurses(p_workspace_id uuid default null)
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
      select s.id as staff_id, s.full_name, s.status, s.last_active_at, s.created_at,
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
       where s.role = 'nurse'
         and (p_workspace_id is null or s.workspace_id = p_workspace_id)
    ) t
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_list_nurses(uuid) to authenticated;

create or replace function public.admin_create_nurse(p_workspace_id uuid, p_full_name text)
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

  insert into staff (org_id, workspace_id, full_name, role, status)
  values (v_org_id, p_workspace_id, btrim(p_full_name), 'nurse', 'active')
  returning id into v_id;

  return jsonb_build_object('staff_id', v_id);
end;
$$;
grant execute on function public.admin_create_nurse(uuid, text) to authenticated;

create or replace function public.admin_issue_nurse_login(p_staff_id uuid, p_reset boolean default false)
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
  if not exists (select 1 from staff where id = p_staff_id and role = 'nurse') then
    raise exception 'AWN_NOT_FOUND: الممرض/ة مش موجود/ة.';
  end if;

  if p_reset then
    delete from staff_channels where staff_id = p_staff_id and platform = 'mobile';
  end if;

  select external_id into v_code from staff_channels
   where staff_id = p_staff_id and platform = 'mobile' and is_active
   limit 1;

  if v_code is null then
    delete from staff_channels where staff_id = p_staff_id and platform = 'mobile';
    v_code := app_issue_mobile_login(p_staff_id);
  end if;

  return jsonb_build_object('code', v_code);
end;
$$;
grant execute on function public.admin_issue_nurse_login(uuid, boolean) to authenticated;

create or replace function public.admin_set_nurse_status(p_staff_id uuid, p_status text)
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
   where id = p_staff_id and role = 'nurse';
  if not found then
    raise exception 'AWN_NOT_FOUND: الممرض/ة مش موجود/ة.';
  end if;

  return jsonb_build_object('staff_id', p_staff_id, 'status', p_status);
end;
$$;
grant execute on function public.admin_set_nurse_status(uuid, text) to authenticated;

create or replace function public.admin_offboard_nurse(p_staff_id uuid)
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
   where id = p_staff_id and role = 'nurse';
  if not found then
    raise exception 'AWN_NOT_FOUND: الممرض/ة مش موجود/ة.';
  end if;

  update staff_channels set is_active = false where staff_id = p_staff_id;
  return jsonb_build_object('staff_id', p_staff_id, 'status', 'suspended');
end;
$$;
grant execute on function public.admin_offboard_nurse(uuid) to authenticated;

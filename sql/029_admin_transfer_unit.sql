-- ============================================================================
-- Migration 029: نقل حالة لقسم آخر من لوحة التحكم — كأكشن متدقّق (audited)
-- ============================================================================
-- بيسجّل حدث unit_transfer في جدول events (append-only) — فبيتطبّق تلقائيًا
-- (trigger events_apply بيغيّر current_unit_id) وبيتدقّق مين وامتى:
--   actor_staff_id = الطبيب المعالج (أو أول عضو نشط)، occurred_at = دلوقتي،
--   payload.by_admin = إيميل المدير اللي عمل النقلة، payload.via='admin_dashboard'.
-- ============================================================================

create or replace function public.admin_transfer_unit(p_encounter_id uuid, p_to_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  enc     encounters%rowtype;
  v_unit  units%rowtype;
  v_actor uuid;
  v_email text := coalesce(auth.jwt() ->> 'email', '');
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  select * into enc from encounters where id = p_encounter_id;
  if not found then raise exception 'AWN_NOT_FOUND: الحالة مش موجودة.'; end if;

  select * into v_unit from units where id = p_to_unit_id;
  if v_unit is null then raise exception 'AWN_NOT_FOUND: القسم مش موجود.'; end if;
  if v_unit.org_id <> enc.org_id then
    raise exception 'AWN_BAD_INPUT: القسم مش تابع لنفس المؤسسة.';
  end if;

  -- الفاعل لازم يكون staff (القيد NOT NULL): الطبيب المعالج، وإلا أول عضو نشط
  v_actor := enc.attending_staff_id;
  if v_actor is null then
    select id into v_actor from staff
     where workspace_id = enc.workspace_id
     order by (status = 'active') desc, created_at
     limit 1;
  end if;
  if v_actor is null then
    raise exception 'AWN_BAD_INPUT: مفيش طاقم في مساحة العمل لتسجيل النقلة.';
  end if;

  insert into events (org_id, workspace_id, encounter_id, patient_id, event_type,
                      payload, actor_staff_id, source_bot, occurred_at)
  values (enc.org_id, enc.workspace_id, enc.id, enc.patient_id, 'unit_transfer',
          jsonb_build_object('to_unit_id', p_to_unit_id, 'by_admin', v_email, 'via', 'admin_dashboard'),
          v_actor, 'round', now());

  return jsonb_build_object('ok', true, 'unit', v_unit.name);
end;
$$;

grant execute on function public.admin_transfer_unit(uuid, uuid) to authenticated;

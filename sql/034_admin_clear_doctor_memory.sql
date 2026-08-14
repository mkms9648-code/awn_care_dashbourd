-- ============================================================================
-- Migration 034: زرار أدمن — تصفير ذاكرة محادثة الدكتور (n8n_chat_histories)
-- ============================================================================
-- المطلوب: زرار في لوحة تحكم الأطباء يمسح "ذاكرة" الأجنت بتاعة دكتور معيّن —
-- كل البوتات اللي بيستخدمها (طوارئ/راوند/عيادة)، من غير ما يلمس أي بيانات
-- إكلينيكية (patients/encounters/orders...) — دي جداول منفصلة تمامًا.
--
-- التصميم: نفس نمط باقي admin_* (SECURITY DEFINER + app_is_admin() + منوحة
-- لـ authenticated بس). بيقرا كل صفوف staff_channels بتاعة الدكتور (بكل
-- الـ bot_key/platform اللي عنده)، ويبني session_id لكل واحد بنفس صيغة n8n
-- (external_id || '-' || bot_key — راجع migration 004)، ويمسحهم كلهم دفعة
-- واحدة بـ DELETE...USING (مفيش loop).
-- ============================================================================

create or replace function public.admin_clear_doctor_memory(p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_full_name text;
  v_deleted   bigint;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  select full_name into v_full_name from staff where id = p_staff_id;
  if v_full_name is null then
    raise exception 'AWN_NOT_FOUND: الدكتور مش موجود.';
  end if;

  with sessions as (
    select distinct sc.external_id || '-' || sc.bot_key as session_id
      from staff_channels sc
     where sc.staff_id = p_staff_id
  ),
  deleted as (
    delete from n8n_chat_histories h
     using sessions s
     where h.session_id = s.session_id
    returning h.id
  )
  select count(*) into v_deleted from deleted;

  return jsonb_build_object(
    'status', 'ok',
    'staff_id', p_staff_id,
    'full_name', v_full_name,
    'deleted_messages', v_deleted
  );
end;
$$;

grant execute on function public.admin_clear_doctor_memory(uuid) to authenticated;

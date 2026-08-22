-- ============================================================================
-- Migration 062: كاليندر متابعات — دالة واحدة بس، الباقي كله موجود
-- ============================================================================
-- استخراج مواعيد المتابعة ("تعالى بعد أسبوع") من كلام الدكتور شغال بالفعل —
-- أداة add_commitment وبرومبت العيادة (024_bot_prompts_ed_clinic.sql، قسم
-- "Follow-up") بيحسبوا due_at ويسجلوا commitment_created زي ما هو من زمان.
-- الناقص الوحيد هو دالة تجمع الالتزامات المفتوحة عبر كل مرضى الدكتور
-- (مش زيارة واحدة بس زي app_patient_summary) لفترة تاريخ معيّنة، عشان
-- شاشة الكاليندر الجديدة تعرضها. مفيش تعديل على البرومبت ولا على أي حاجة
-- تانية — كل حاجة تانية شغالة زي ما هي.
-- ============================================================================

create or replace function public.app_calendar_followups(
  p_platform text, p_bot_key text, p_chat_id text,
  p_from timestamptz, p_to timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare c app_ctx;
begin
  c := app_bind(p_platform, p_bot_key, p_chat_id);

  return jsonb_build_object('results', coalesce((
    select jsonb_agg(jsonb_build_object(
             'commitment_id', k.id,
             'encounter_id', k.encounter_id,
             'patient_name', p.full_name,
             'handle', (select handle from handles
                         where encounter_id = k.encounter_id and released_at is null limit 1),
             'text', k.text_body,
             'due_at', k.due_at,
             'is_overdue', k.due_at < now())
           order by k.due_at)
      from commitments k
      join encounters e on e.id = k.encounter_id
      join patients p on p.id = e.patient_id
     where e.workspace_id = c.workspace_id
       and k.status = 'open'
       and k.due_at is not null
       and k.due_at between p_from and p_to
       and coalesce(k.owner_staff_id, e.attending_staff_id) = c.staff_id
  ), '[]'::jsonb));
end;
$$;
grant execute on function public.app_calendar_followups(text,text,text,timestamptz,timestamptz) to anon;

-- ============================================================================
-- Migration 064: تصحيح — admin_set_plan_quota كانت لسه رافضة موديول followup
-- ============================================================================
-- 061 وسّع قيد plan_quotas.module_key ليشمل 'followup' وقرأ منه في
-- app_plan_usage/admin_workspace_usage، لكن admin_set_plan_quota (059) فضلت
-- برضه بترفض أي حاجة غير ed/round/clinic — يعني مفيش طريقة تحطّ حد استخدام
-- لموديول المتابعة من غير INSERT يدوي مباشر في الجدول. تصحيح بسيط: نفس قايمة
-- الموديولات المسموحة في قيد الجدول.
-- ============================================================================

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
  if p_module_key not in ('ed','round','clinic','followup') then
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

-- ============================================================================
-- Migration 021: قايمة "شاتس" لداشبورد المراجعة — كل (دكتور × بوت) ليه فعليًا
--                محادثة، مرتبة بالأحدث الأول (زي أي تطبيق شات).
-- ============================================================================

create or replace function public.admin_doctor_channels()
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
    select jsonb_agg(to_jsonb(t) order by t.last_msg_id desc nulls last)
    from (
      select s.id as staff_id, s.full_name, w.name as workspace_name, sc.bot_key,
             (
               select max(h.id) from n8n_chat_histories h
                where h.session_id = sc.external_id || '-' || sc.bot_key
             ) as last_msg_id
        from staff_channels sc
        join staff s      on s.id = sc.staff_id
        join workspaces w on w.id = s.workspace_id
       where sc.is_active and s.role = 'doctor'
    ) t
   where t.last_msg_id is not null
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.admin_doctor_channels() to authenticated;

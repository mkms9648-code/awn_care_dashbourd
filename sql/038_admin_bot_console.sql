-- ============================================================================
-- Migration 038: "البرومبتات والأدوات" في اللوحة — بدل الدخول لـ Supabase
-- ============================================================================
-- الجزء 1: إدارة برومبتات البوتات (bot_prompts) — عرض + تعديل + إضافة بوت جديد.
--   نفس نمط sales_kb بالظبط (migration 026): admin_get_*/admin_set_* محميين
--   بـ app_is_admin()، ومنوحين لـ authenticated بس.
--
-- الجزء 2: عرض دوال app_* (اللي البوتات بتستخدمها كأدوات) — للقراءة بس، من
--   catalog بوستجريس نفسه (pg_proc/pg_get_functiondef) — مفيش أي تنفيذ أو
--   تعديل SQL من اللوحة، القرار كان نخليها عرض بس دلوقتي.
-- ============================================================================

-- ---- 1) عمودين تتبّع للتعديل (idempotent) ----
alter table public.bot_prompts add column if not exists updated_at timestamptz not null default now();
alter table public.bot_prompts add column if not exists updated_by text;

-- ---- 2) قائمة خفيفة (بدون النص الكامل) لعرض البطاقات في اللوحة ----
create or replace function public.admin_list_bot_prompts()
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
    select jsonb_agg(jsonb_build_object(
             'bot_key', bot_key,
             'length', length(prompt_text),
             'updated_at', updated_at,
             'updated_by', updated_by
           ) order by bot_key)
    from bot_prompts
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_list_bot_prompts() to authenticated;

-- ---- 3) جلب برومبت بوت واحد كامل (للفتح في المحرّر) ----
create or replace function public.admin_get_bot_prompt(p_bot_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;
  return coalesce(
    (select to_jsonb(t) from bot_prompts t where t.bot_key = p_bot_key),
    jsonb_build_object('bot_key', p_bot_key, 'prompt_text', '', 'updated_at', null, 'updated_by', null)
  );
end;
$$;
grant execute on function public.admin_get_bot_prompt(text) to authenticated;

-- ---- 4) حفظ/تحديث (أو إنشاء بوت جديد) ----
create or replace function public.admin_set_bot_prompt(p_bot_key text, p_prompt_text text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_email text := coalesce((auth.jwt() ->> 'email'), '');
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;
  if coalesce(btrim(p_bot_key), '') = '' then
    raise exception 'AWN_BAD_INPUT: مفتاح البوت مطلوب.';
  end if;
  if coalesce(btrim(p_prompt_text), '') = '' then
    raise exception 'AWN_BAD_INPUT: البرومبت مينفعش يبقى فاضي.';
  end if;

  insert into bot_prompts (bot_key, prompt_text, updated_at, updated_by)
  values (btrim(p_bot_key), p_prompt_text, now(), v_email)
  on conflict (bot_key) do update
    set prompt_text = excluded.prompt_text,
        updated_at  = now(),
        updated_by  = v_email;

  return (select to_jsonb(t) from bot_prompts t where t.bot_key = btrim(p_bot_key));
end;
$$;
grant execute on function public.admin_set_bot_prompt(text, text) to authenticated;

-- ---- 5) عرض دوال app_* (قراءة فقط — من catalog بوستجريس، مفيش تنفيذ) ----
create or replace function public.admin_list_app_functions()
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
    select jsonb_agg(jsonb_build_object(
             'name', p.proname,
             'args', pg_get_function_arguments(p.oid),
             'result', pg_get_function_result(p.oid),
             'definition', pg_get_functiondef(p.oid)
           ) order by p.proname, pg_get_function_arguments(p.oid))
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname like 'app\_%'
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_list_app_functions() to authenticated;

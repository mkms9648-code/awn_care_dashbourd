-- ============================================================================
--  فتحي ميزانية — طبقة أدمن للوحة تحكم عون إيجنت الموحّدة
-- ============================================================================
--  شغّل الملف ده في Supabase بتاع فتحي (jiniprotcrmsverqetmw) → SQL Editor،
--  بعد الملفات الأساسية (smart_accountant_supabase.sql + dashboard_auth.sql +
--  feature_operations_hub.sql اللي فيه chat_enabled).
--
--  فلسفة الأمان هنا مطابقة لباقي فتحي: الداشبورد بيتكلم مع دوال SECURITY DEFINER
--  بمفتاح anon، والتحقق جوّه الدالة عن طريق "سر أدمن" (زي كود دخول العميل بالظبط،
--  بس ده للمدير). مفيش قراءة مباشرة لأي جدول.
--
--  خطوة لمرة واحدة بعد التشغيل — عيّن سر الأدمن (من SQL Editor، service_role):
--     select set_admin_secret('اكتب_سر_قوي_هنا');
--  وبعدين استخدم نفس السر ده لما الداشبورد يطلبه أول مرة.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
--  0) أعمدة تحكم على مستوى الشركة
-- ---------------------------------------------------------------------------
alter table companies add column if not exists is_active     boolean not null default true;
-- خريطة تشغيل/إيقاف الوحدات لكل شركة: { "inventory": false, ... }
-- المفتاح الغائب = مفعّل افتراضيًا. القيمة false = موقوف. (chat ليه عموده الخاص)
alter table companies add column if not exists feature_flags jsonb  not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
--  1) سر الأدمن — صف واحد، مخزّن bcrypt (زي company_access)
-- ---------------------------------------------------------------------------
create table if not exists app_admin_secret (
  id          smallint primary key default 1,
  secret_hash text not null,
  updated_at  timestamptz not null default now(),
  constraint app_admin_secret_singleton check (id = 1)
);
alter table app_admin_secret enable row level security;   -- مفيش policies = anon مايقراش

-- تعيين/تغيير سر الأدمن (service_role بس)
create or replace function set_admin_secret(p_secret text)
returns void
language sql security definer set search_path = public, extensions
as $$
  insert into app_admin_secret(id, secret_hash)
  values (1, crypt(p_secret, gen_salt('bf')))
  on conflict (id) do update set secret_hash = crypt(p_secret, gen_salt('bf')), updated_at = now();
$$;
grant execute on function set_admin_secret(text) to service_role;

-- تحقق داخلي (مش ممنوح لـ anon — بيتنادى جوّه الدوال المحمية بس)
create or replace function _admin_ok(p_secret text)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select exists (
    select 1 from app_admin_secret
     where id = 1 and secret_hash = crypt(coalesce(p_secret, ''), secret_hash)
  );
$$;

-- ---------------------------------------------------------------------------
--  2) قائمة الشركات (العملاء) + حالة كل واحدة
-- ---------------------------------------------------------------------------
create or replace function admin_list_companies(p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then
    raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.';
  end if;

  return coalesce((
    select json_agg(t order by t.name)
    from (
      select c.id, c.name, c.currency, c.industry,
             c.chat_enabled, c.is_active, c.feature_flags,
             c.telegram_chat_id, c.created_at,
             exists(select 1 from company_access ca where ca.company_id = c.id) as has_code
        from companies c
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function admin_list_companies(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  3) إنشاء شركة جديدة (+ كود دخول اختياري)
-- ---------------------------------------------------------------------------
create or replace function admin_create_company(
  p_secret   text,
  p_name     text,
  p_currency text default 'EGP',
  p_code     text default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  if not _admin_ok(p_secret) then
    raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'AWN_BAD_INPUT: اسم الشركة مطلوب.';
  end if;

  insert into companies(name, currency)
  values (btrim(p_name), coalesce(nullif(btrim(p_currency), ''), 'EGP'))
  returning id into v_id;

  if p_code is not null and btrim(p_code) <> '' then
    insert into company_access(company_id, code_hash)
    values (v_id, crypt(btrim(p_code), gen_salt('bf')));
  end if;

  return json_build_object('ok', true, 'company_id', v_id);
end;
$$;
grant execute on function admin_create_company(text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  4) تعيين/تغيير كود دخول شركة ("الباسورد")
-- ---------------------------------------------------------------------------
create or replace function admin_set_company_code(
  p_secret     text,
  p_company_id uuid,
  p_code       text
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then
    raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.';
  end if;
  if coalesce(btrim(p_code), '') = '' then
    raise exception 'AWN_BAD_INPUT: الكود مطلوب.';
  end if;
  if not exists(select 1 from companies where id = p_company_id) then
    raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.';
  end if;

  insert into company_access(company_id, code_hash)
  values (p_company_id, crypt(btrim(p_code), gen_salt('bf')))
  on conflict (company_id) do update
    set code_hash = crypt(btrim(p_code), gen_salt('bf')), updated_at = now();

  return json_build_object('ok', true);
end;
$$;
grant execute on function admin_set_company_code(text, uuid, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  5) إلغاء كود دخول شركة (تعطيل الدخول تمامًا)
-- ---------------------------------------------------------------------------
create or replace function admin_clear_company_code(p_secret text, p_company_id uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then
    raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.';
  end if;
  delete from company_access where company_id = p_company_id;
  return json_build_object('ok', true);
end;
$$;
grant execute on function admin_clear_company_code(text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  6) تفعيل/إيقاف الشركة، والشات، والوحدات
-- ---------------------------------------------------------------------------
create or replace function admin_set_company_active(p_secret text, p_company_id uuid, p_active boolean)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  update companies set is_active = p_active where id = p_company_id;
  if not found then raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.'; end if;
  return json_build_object('ok', true, 'is_active', p_active);
end;
$$;
grant execute on function admin_set_company_active(text, uuid, boolean) to anon, authenticated;

create or replace function admin_set_chat_enabled(p_secret text, p_company_id uuid, p_enabled boolean)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  update companies set chat_enabled = p_enabled where id = p_company_id;
  if not found then raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.'; end if;
  return json_build_object('ok', true, 'chat_enabled', p_enabled);
end;
$$;
grant execute on function admin_set_chat_enabled(text, uuid, boolean) to anon, authenticated;

-- توجل وحدة (تاب) لشركة: p_state = 'on' / 'off' / 'inherit'
create or replace function admin_set_company_feature(
  p_secret text, p_company_id uuid, p_key text, p_state text
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;

  if p_state = 'on' then
    update companies set feature_flags = feature_flags || jsonb_build_object(p_key, true)  where id = p_company_id;
  elsif p_state = 'off' then
    update companies set feature_flags = feature_flags || jsonb_build_object(p_key, false) where id = p_company_id;
  elsif p_state = 'inherit' then
    update companies set feature_flags = feature_flags - p_key where id = p_company_id;
  else
    raise exception 'AWN_BAD_INPUT: p_state لازم تبقى on/off/inherit.';
  end if;

  if not found then raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.'; end if;
  return (select json_build_object('ok', true, 'feature_flags', feature_flags) from companies where id = p_company_id);
end;
$$;
grant execute on function admin_set_company_feature(text, uuid, text, text) to anon, authenticated;

-- الوحدات (التابات) اللي يتحكم فيها الأدمن — للعرض في الواجهة
create or replace function admin_feature_catalog(p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  return json_build_array(
    json_build_object('key','chat',       'label','الشات'),
    json_build_object('key','pnl',        'label','قائمة الدخل'),
    json_build_object('key','bs',         'label','الميزانية'),
    json_build_object('key','customers',  'label','العملاء'),
    json_build_object('key','suppliers',  'label','الموردين'),
    json_build_object('key','journal',    'label','اليومية'),
    json_build_object('key','tb',         'label','ميزان المراجعة'),
    json_build_object('key','documents',  'label','المستندات'),
    json_build_object('key','inventory',  'label','المخزون'),
    json_build_object('key','reps',       'label','المناديب'),
    json_build_object('key','operations', 'label','العمليات'),
    json_build_object('key','ledger',     'label','دفتر الأستاذ')
  );
end;
$$;
grant execute on function admin_feature_catalog(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  7) الوحدات المفعّلة لشركة (للعميل) — الداشبورد بيقراها عشان يخفي التابات
-- ---------------------------------------------------------------------------
create or replace function dashboard_flags(p_code text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_company companies%rowtype;
begin
  select c.* into v_company
  from company_access ca join companies c on c.id = ca.company_id
  where ca.code_hash = crypt(p_code, ca.code_hash);
  if not found then
    return json_build_object('ok', false);
  end if;
  return json_build_object('ok', true,
    'chat_enabled', v_company.chat_enabled,
    'is_active', v_company.is_active,
    'feature_flags', v_company.feature_flags);
end;
$$;
grant execute on function dashboard_flags(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  8) متابعة شات شركة — مقاوم لاختلاف سكيمة messages بين نسختين في التاريخ:
--     (أ) نسخة feature_message_link  : messages(company_id, content, ...)
--     (ب) نسخة n8n framework         : messages(conversation_id, sender_type,
--         message_content, execution_url, sent_at) + conversations(user_id)
--     بنكتشف الأعمدة الموجودة فعلًا ونقرأ منها.
-- ---------------------------------------------------------------------------
create or replace function admin_company_chat(p_secret text, p_company_id uuid, p_limit int default 300)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_chat text; v_out json;
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;

  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='messages' and column_name='company_id') then
    -- سكيمة (أ): مرتبطة بالشركة مباشرة
    execute $q$
      select coalesce(json_agg(x order by x.at), '[]'::json) from (
        select coalesce(m.content, '')                                   as content,
               'user'::text                                             as role,
               coalesce(m.message_type, 'text')                          as message_type,
               null::text                                                as exec_url,
               m.created_at                                              as at
          from messages m
         where m.company_id = $1
         order by m.created_at desc
         limit $2
      ) x
    $q$ into v_out using p_company_id, p_limit;
    return v_out;
  else
    -- سكيمة (ب): عبر conversations.user_id = telegram_chat_id بتاع الشركة
    select telegram_chat_id into v_chat from companies where id = p_company_id;
    if v_chat is null then return '[]'::json; end if;
    execute $q$
      select coalesce(json_agg(x order by x.at), '[]'::json) from (
        select coalesce(m.message_content, '')                           as content,
               coalesce(m.sender_type, 'user')                           as role,
               coalesce(m.message_type, 'text')                          as message_type,
               m.execution_url                                           as exec_url,
               coalesce(m.sent_at, m.created_at)                         as at
          from messages m
          join conversations c on c.conversation_id = m.conversation_id
         where c.user_id = $1
         order by coalesce(m.sent_at, m.created_at) desc
         limit $2
      ) x
    $q$ into v_out using v_chat, p_limit;
    return v_out;
  end if;
end;
$$;
grant execute on function admin_company_chat(text, uuid, int) to anon, authenticated;

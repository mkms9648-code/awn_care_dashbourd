-- ============================================================================
-- Migration 026: مساعد المبيعات/الدعم (AI) — قاعدة المعرفة القابلة للتحديث
-- ============================================================================
-- الفكرة: أي حد بيدير المشروع (كول سنتر/سيلز) يفتح "مساعد المبيعات" في اللوحة
-- ويسأله بالعربي، والمساعد (AI في n8n) يرد باحتراف ونبرة تسويقية بناءً على:
--   • persona   : الاتفاق على أسلوب/نبرة الرد (كيف يرد، مؤدب، تسويقي، يحل مشاكل).
--   • knowledge : بيانات المشروع (أسعار/باقات/طرق دفع/لينكات/تقني) — تتحدّث من اللوحة.
--
-- بنخزّن معرفة المنتجين (awncare / fathi) هنا في مشروع عون كير (نفس مكان app_admins)
-- عشان محرّر واحد محمي بـ app_is_admin(). n8n بيقرا المعرفة عن طريق sales_kb_get.
-- ============================================================================

create table if not exists public.sales_kb (
  product    text primary key,
  persona    text not null default '',
  knowledge  text not null default '',
  updated_at timestamptz not null default now(),
  updated_by text
);

alter table public.sales_kb enable row level security;   -- مفيش policies = وصول عبر الدوال بس

insert into public.sales_kb (product) values ('awncare'), ('fathi')
on conflict (product) do nothing;

-- قراءة المعرفة للمحرّر (إداري فقط)
create or replace function public.admin_get_sales_kb(p_product text)
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
    (select to_jsonb(k) from sales_kb k where k.product = p_product),
    jsonb_build_object('product', p_product, 'persona', '', 'knowledge', '')
  );
end;
$$;
grant execute on function public.admin_get_sales_kb(text) to authenticated;

-- حفظ/تحديث المعرفة (إداري فقط)
create or replace function public.admin_set_sales_kb(
  p_product text, p_persona text, p_knowledge text
)
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
  if p_product not in ('awncare', 'fathi') then
    raise exception 'AWN_BAD_INPUT: منتج مش معروف: %', p_product;
  end if;

  insert into sales_kb (product, persona, knowledge, updated_at, updated_by)
  values (p_product, coalesce(p_persona, ''), coalesce(p_knowledge, ''), now(), v_email)
  on conflict (product) do update
    set persona = excluded.persona,
        knowledge = excluded.knowledge,
        updated_at = now(),
        updated_by = v_email;

  return (select to_jsonb(k) from sales_kb k where k.product = p_product);
end;
$$;
grant execute on function public.admin_set_sales_kb(text, text, text) to authenticated;

-- قراءة المعرفة لـ n8n (مش سرية — دي نفس المعلومات اللي المساعد هيقولها للناس).
-- بترجّع persona + knowledge عشان n8n يبني منهم رسالة النظام.
create or replace function public.sales_kb_get(p_product text)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
           'persona',   coalesce((select persona   from sales_kb where product = p_product), ''),
           'knowledge', coalesce((select knowledge from sales_kb where product = p_product), '')
         );
$$;
grant execute on function public.sales_kb_get(text) to anon, authenticated;

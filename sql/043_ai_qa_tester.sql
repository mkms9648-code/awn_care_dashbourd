-- ============================================================================
-- Migration 043: اختبار الذكاء الاصطناعي (AI QA Tester) — شخصيات اختبار البوتات
-- ============================================================================
-- الفكرة: المطوّر (مش دكتور) عايز يتأكد إن بوتات الطوارئ/الراوند/العيادة لسه
-- بترد صح من غير ما يضطر هو نفسه يلعب دور الدكتور ويحكم على ردود طبية.
-- الحل: صفحة "اختبار الذكاء الاصطناعي" في اللوحة بتشغّل AI (Gemini في n8n)
-- بيلعب دور "الدكتور المختبِر" — بياخد شخصية/برومبت من هنا، ويكلم البوت الحقيقي
-- عن طريق نفس الـ webhook اللي التطبيق الحقيقي بيستخدمه، والمطوّر يتفرج بس.
--
-- عشان الحالات الوهمية دي متتلخبطش مع بيانات حقيقية، الاختبار بيتم من خلال
-- "دكتور تجريبي" حقيقي (staff row) جوّه مساحة عمل حقيقية موجودة — مفيش مساحة
-- عمل معزولة جديدة لأن جدولي workspaces/orgs مش متعرّفين في الـ migrations دي
-- (schema أساسي بره الريبو ده). الهوية دي بتتعمل وتترباط من نفس صفحة الاختبار
-- عن طريق admin_create_doctor/admin_issue_doctor_login الموجودين بالفعل.
--
-- برومبت الشخصية بيتبعت مباشرة مع كل نداء لـ n8n (مش بيتقرا من هنا) — عشان كده
-- الجدول ده إداري بس (مفيش grant لـ anon زي sales_kb_get، لأن مفيش داعي).
-- ============================================================================

create table if not exists public.bot_test_personas (
  bot_key         text primary key,
  persona_prompt  text not null default '',
  max_turns       integer not null default 150,
  test_staff_id   uuid references public.staff(id),
  test_chat_id    text,
  updated_at      timestamptz not null default now(),
  updated_by      text
);

alter table public.bot_test_personas enable row level security;  -- مفيش policies = وصول عبر الدوال بس

insert into public.bot_test_personas (bot_key, persona_prompt) values
('ed',
'إنت دكتور طوارئ حقيقي واقف في الاستقبال (الكشف الأولي) في مستشفى مصري مزدحم، بتستخدم تطبيق عون كير على الموبايل لتوثيق الحالات من أول ما تدخل لحد القرار النهائي. التطبيق فعليًا بيقدر يسجّل: بيانات المريض، فحص وتاريخ مرضي وتشخيص، طلبات تحاليل/أشعة وقفلها لما النتيجة ترجع، ملاحظات وإرشادات صحية، تنويم في قسم/سرير أو خروج، وتصحيح أي معلومة اتسجلت غلط — استخدم الإمكانيات دي فعليًا، متكتفيش بالتسجيل بس.

مهمتك إنك تحاكي 20 حالة طوارئ متنوعة وواقعية (نوبة قلبية، حادث سيارة، نزيف، تسمم، حروق، تشنج أطفال، ضيق نفس حاد، جلطة مشتبه بها، حساسية شديدة، ألم بطن حاد، حمى عند طفل...) واحدة ورا التانية، وكل حالة تعدّي بالخطوات دي (اكتبها كسرد طبيعي زي دكتور بيحكي على عجل، من غير ترقيم أو عناوين):

1. الفتح: رقم التذكرة (لو حسّيت إنه اتاخد لحالة قبل كده، اكتب رقم عشوائي تاني — فيه حالات حقيقية مسجلة من قبل بأرقام تذاكر موجودة بالفعل) + سن/جنس المريض + الشكوى الرئيسية باختصار زي ما سمعتها بسرعة، مثلاً "تذكرة 4521 — راجل 45 سنة، ألم صدر حاد من نص ساعة".
2. الفحص والتاريخ: لما البوت يسأل، أو حتى من غير ما يسأل، ادّي علامات حيوية واقعية (ضغط/نبض/حرارة/تنفس/أكسجين)، تاريخ مرضي مختصر، ونتيجة فحصك الإكلينيكي — اختلق تفاصيل واقعية ومتسقة مع الحالة.
3. انطباعك المبدئي: قول تشخيصك الأولي بوضوح (مش لازم نهائي، انطباع كفاية).
4. الطلبات: اطلب فعليًا التحاليل والأشعة المناسبة للحالة بالاسم (زي ECG, Troponin, CBC, D-dimer, X-ray, CT Brain...)، والدواء الضروري لو الحالة محتاجة تدخل فوري. في حوالي نص الحالات، بعد شوية قول إن نتيجة رجعت واختلق قيمة واقعية وعلّق عليها قبل ما تكمّل.
5. القرار النهائي: اقفل كل حالة بقرار واضح — تنويم (سمّي القسم: عناية مركزة/باطنة/جراحة/أطفال...) أو خروج (مع روشتة وإرشادات صحية مختصرة) أو تحويل لمستشفى تاني. نوّع بين القرارات، مش كل الحالات تتنوّم.
6. من وقت للتاني (مش كل حالة، مرة كل 5-6 حالات تقريبًا) اسأل عن حالة سجلتها قبل كده في نفس الجلسة عشان تتابعها أو تتأكد من بياناتها، وأحيانًا (مرة أو اتنين بس في كل الاختبار) صحّح معلومة قلتها غلط في حالة سابقة بوضوح إنك بتصحح.

بعد ما تقفل حالة بقرار، ابدأ التالية فورًا من غير أي مقدمة، وابدأ الرسالة بـ "[حالة رقم N]".

لما تخلّص كل الحالات المطلوبة، اكتب END_TEST وحده من غير أي كلام قبله أو بعده.'),
('round',
'إنت دكتور بتعمل الراوند على الأقسام الداخلية في مستشفى مصري، وبتستخدم بوت "الراوند" في عون كير. المرضى اللي بتشوفهم نوعين:
(أ) مريض جاي من الطوارئ ومعاه رقم تذكرة جاهز من هناك — لو لقيت قائمة مرضى حقيقيين متاحة في التعليمات، استخدم منها ومتخترعش حد تاني.
(ب) مريض اتحوّل لقسمك من قسم داخلي تاني بسبب مضاعفات (مثال: حالة مسالك بولية حصلها مضاعفة واتحولت لجراحة عامة) — ده مريض جديد بيدخل قسمك مباشرة من غير ما يعدي بالطوارئ، فسجّله كمريض جديد.

حاكي حوالي 8 مرضى متنوعين (اخلط بين النوعين أ و ب)، وتابع كل مريض 3 أيام متتالية زي راوند حقيقي فعلاً — يوم 1 التقييم الأولي والأوامر، يوم 2 متابعة النتايج وتعديل العلاج لو محتاج، يوم 3 استكمال المتابعة وقرار نهائي (يخرج / يفضل متابع / يتحول لقسم تاني). في كل يوم اذكر: الأدوية ومواعيدها، ومتابعة العلامة الحيوية الأهم للحالة (زي الضغط أو الأكسجين أو السكر حسب المرض).

ابدأ كل مريض جديد بـ "[مريض رقم N]"، وكل يوم جديد لنفس المريض بـ "— يوم Y —". لما تخلّص كل المرضى (بالـ 3 أيام بتوعهم)، اكتب END_TEST بس من غير أي كلام تاني.'),
('clinic',
'إنت دكتور عيادة خارجية بيستخدم بوت "العيادة" في عون كير. بيدخلك مريض واحد كل مرة بيشتكي من حاجة، وإنت بتتعامل معاه ككشف عيادة عادي: تسمعله شكواه وتاريخه المرضي، تطلب تحاليل أو أشعة لو محتاج، وتدّيله روشتة بالعلاج.

مهمتك تحاكي 20 كشف متنوع (كشف أول، متابعة مزمن زي ضغط/سكر، أعراض تنفسية، آلام مفاصل، صداع متكرر، استشارة نتيجة تحليل...) واحد ورا التاني.

لكل مريض: ابدأ بجملة قصيرة زي "مريض جديد، سيدة 60 سنة جاية بصداع متكرر من أسبوعين". رد بتفاصيل واقعية على أسئلة البوت. اقفل الكشف بوضوح — ومهم جدًا: سجّل موعد المتابعة القادم لو الحالة محتاجة، ونوّع بين:
- كشف يتقفل من غير أي متابعة (المريض تمام).
- "يرجع بعد أسبوع" لمراجعة نتيجة تحليل أو تحسّن حالة.
- "يرجع بعد شهر" لاستشارة متابعة لحالة مزمنة.
- حالة محتاجة عملية أو إجراء — اذكر إنه هيتحدد له ميعاد للعملية.

ابدأ كل مريض جديد بـ "[مريض رقم N]". لما تخلّص كل الكشوفات، اكتب END_TEST بس من غير أي كلام تاني.')
on conflict (bot_key) do nothing;

-- ----------------------------------------------------------------------------
-- قراءة قايمة كل البوتات (للتابات + بادچ الهوية المربوطة) — إداري فقط
-- ----------------------------------------------------------------------------
create or replace function public.admin_list_test_personas()
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
    select jsonb_agg(to_jsonb(t) order by t.bot_key)
    from (
      select p.bot_key, p.max_turns, p.test_staff_id, p.test_chat_id,
             length(p.persona_prompt) as prompt_length,
             p.updated_at, p.updated_by,
             s.full_name as test_doctor_name, s.status as test_doctor_status,
             w.id as test_workspace_id, w.name as test_workspace_name,
             o.name as test_org_name
        from bot_test_personas p
        left join staff s      on s.id = p.test_staff_id
        left join workspaces w on w.id = s.workspace_id
        left join orgs o       on o.id = s.org_id
    ) t
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_list_test_personas() to authenticated;

-- ----------------------------------------------------------------------------
-- قراءة شخصية بوت واحد كاملة (مع نص البرومبت) — إداري فقط
-- ----------------------------------------------------------------------------
create or replace function public.admin_get_test_persona(p_bot_key text)
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
    (select to_jsonb(p) from bot_test_personas p where p.bot_key = p_bot_key),
    jsonb_build_object('bot_key', p_bot_key, 'persona_prompt', '', 'max_turns', 150,
                        'test_staff_id', null, 'test_chat_id', null)
  );
end;
$$;
grant execute on function public.admin_get_test_persona(text) to authenticated;

-- ----------------------------------------------------------------------------
-- حفظ شخصية بوت / ربط هوية الدكتور التجريبي — إداري فقط
-- ----------------------------------------------------------------------------
-- p_test_staff_id/p_test_chat_id افتراضيًا null ويتحطّوا بـ coalesce على القيمة
-- الحالية، عشان نداء "حفظ نص البرومبت بس" ميمسحش هوية متربطة قبل كده.
create or replace function public.admin_set_test_persona(
  p_bot_key        text,
  p_persona_prompt text,
  p_max_turns      integer default null,
  p_test_staff_id  uuid default null,
  p_test_chat_id   text default null
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
  if p_bot_key not in ('ed', 'round', 'clinic') then
    raise exception 'AWN_BAD_INPUT: بوت مش معروف: %', p_bot_key;
  end if;
  if p_test_staff_id is not null
     and not exists (select 1 from staff where id = p_test_staff_id and role = 'doctor') then
    raise exception 'AWN_NOT_FOUND: الدكتور التجريبي مش موجود.';
  end if;

  insert into bot_test_personas
    (bot_key, persona_prompt, max_turns, test_staff_id, test_chat_id, updated_at, updated_by)
  values
    (p_bot_key, coalesce(p_persona_prompt, ''), coalesce(p_max_turns, 150),
     p_test_staff_id, p_test_chat_id, now(), v_email)
  on conflict (bot_key) do update
    set persona_prompt = excluded.persona_prompt,
        max_turns      = coalesce(excluded.max_turns, bot_test_personas.max_turns),
        test_staff_id  = coalesce(excluded.test_staff_id, bot_test_personas.test_staff_id),
        test_chat_id   = coalesce(excluded.test_chat_id, bot_test_personas.test_chat_id),
        updated_at = now(),
        updated_by = v_email;

  return (select to_jsonb(p) from bot_test_personas p where p.bot_key = p_bot_key);
end;
$$;
grant execute on function public.admin_set_test_persona(text, text, integer, uuid, text) to authenticated;

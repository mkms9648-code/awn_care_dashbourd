# لوحة تحكم عون إيجنت (موحّدة)

لوحة تحكم واحدة لكل منتجات عون إيجنت. موقع HTML/CSS/JS ثابت بالكامل (بدون أي
build step أو Node على السيرفر) — بيتكلم مباشرة مع Supabase عن طريق
`@supabase/supabase-js` من CDN. ترفعه لأي استضافة ستاتيك وتربطه بدومينك.

المنتجات:

- **عون كير** (Doctor Assistant) — مشروع Supabase `kaqoozpuvdvernvlmqbk`. **جاهز**.
- **فتحي ميزانية** (Fathi) — مشروع Supabase منفصل `jiniprotcrmsverqetmw`. **المرحلة الجاية**
  (متعطّل في `config.js` عن طريق `enabled: false` لحد ما نبني طبقة الأدمن بتاعته).

> الدخول للوحة بيتم على مشروع **عون كير** (اللي فيه `app_admins`). كل منتج بيتقرا/
> يتحكم من مشروعه هو — اللوحة بتنشئ عميل Supabase منفصل لكل منتج تلقائيًا.

## المحتوى

```
awn-admin/
  config.js                 ← الملف الوحيد اللي بتعدّله بعد الرفع (مفاتيح المنتجين)
  login.html                ← تسجيل الدخول (Supabase Auth على مشروع عون كير)
  index.html                ← موزّع: بيحوّل لصفحة النظرة العامة للمنتج
  assets/
    core.js                 ← عملاء Supabase للمنتجين + حراسة الدخول + أدوات
    ui.js                   ← نوافذ/تنبيهات/تأكيد/قوائم إجراءات (مكتبة الواجهة)
    shell.js                ← السايدبار: مبدّل المنتجات + تنقّل المنتج
    style.css               ← الأنماط + مكتبة المكوّنات
  awncare/                  ← صفحات عون كير
    overview.html           ← نظرة عامة على الاشتراكات
    subscriptions.html      ← التحكم: باقة كل عميل + تشغيل/إيقاف كل وحدة (توجلات)
    doctors.html            ← الأطباء: إنشاء + كود دخول + تفعيل/إيقاف + قنوات
    conversations.html      ← متابعة محادثة أي دكتور مع الـ AI + لينك تنفيذ n8n
  fathi/
    overview.html           ← Placeholder (قريبًا)
```

## خطوات التشغيل

### 1) شغّل المايجريشن الجديد في Supabase (عون كير)

من Supabase Dashboard (مشروع عون كير) → SQL Editor، نفّذ **بالترتيب** لو لسه:

- `sql/020_admin_dashboard.sql` (لو مش متنفّذ) — بيضيف
  `app_admins`, `app_is_admin()`, ودوال العرض `admin_workspaces_overview` /
  `admin_case_counts` / `admin_conversations_feed`.
- `sql/021_admin_doctor_channels.sql` — دالة قايمة الشاتس.
- **`sql/025_admin_control.sql`** (الجديد) — بيضيف طبقة
  **التحكم** (كتابة): `admin_feature_catalog`, `admin_workspace_detail`,
  `admin_set_workspace_feature`, `admin_set_workspace_plan`, `admin_list_doctors`,
  `admin_create_doctor`, `admin_issue_doctor_login`, `admin_set_doctor_status`,
  `admin_set_channel_active`, `admin_offboard_doctor`. كلها SECURITY DEFINER +
  بتتحقق `app_is_admin()` الأول، ومتاحة لـ authenticated بس.

### 2) عدّل `config.js`

كل المفاتيح متحطوطة أصلًا. لو اتغيّر أي حاجة، عدّل داخل `PRODUCTS.awncare`:
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, و`N8N_BASE_URL` (بدون `/` في الآخر — عشان
لينك التنفيذ في المحادثات يشتغل).

> مفتاح الـ anon عمومًا public وده طبيعي — كل الحماية جوّه الدوال نفسها عن طريق
> `app_is_admin()`، مش بإخفاء المفتاح.

### 3) ضيف نفسك كمدير

مفيش صفحة تسجيل حساب جديد (نفس فلسفة النظام — بيتضاف يدويًا لمرة واحدة):

1. Supabase (عون كير) → Authentication → Users → **Add user** — إيميلك وكلمة سر.
2. SQL Editor:
   ```sql
   insert into app_admins (id, email, role)
   select id, email, 'owner' from auth.users where email = 'you@example.com';
   ```
   (لأي زميل بعدين استخدم `'admin'` بدل `'owner'`.)

### 4) جرّبه محليًا (اختياري)

الصفحات بتستخدم ES modules، فمتصفح زي Chrome بيرفض `file://`. شغّل سيرفر ستاتيك:

```bash
npx serve .
# أو: python -m http.server 8080
```

وافتح `http://localhost:PORT/login.html`.

### 5) ارفعه واربطه بالدومين

ارفع محتوى فولدر `awn-admin/` كله لأي استضافة ستاتيك (Netlify / Cloudflare Pages /
FTP) وحوّل الدومين. مفيش أي سيرفر مطلوب.

## التحقق (Verification) — بعد الرفع أو محليًا

1. **الدخول:** افتح `login.html` وادخل بحساب الأدمن → المفروض يحوّلك على النظرة العامة.
2. **النظرة العامة:** `awncare/overview.html` بيعرض إحصائيات + جدول مساحات العمل.
3. **التحكم في الاشتراكات:** `awncare/subscriptions.html` — افتح أي عميل:
   - غيّر الباقة من القايمة → المفروض توست "اتغيّرت الباقة" وتتحدّث حالة الوحدات.
   - على أي وحدة اضغط **إيقاف** → المفروض حالة "موقوف". **تأكيد فعلي:** الدكتور
     في هذه المساحة لازم يتمنع من استخدام البوت ده (لأن `app_has_feature` بيقرا
     `feature_overrides` اللي التوجل بيكتب فيه). **تشغيل** بيفرضها حتى لو مش في الباقة،
     و**وراثة** بيرجّعها لسلوك الباقة.
4. **الأطباء والدخول:** `awncare/doctors.html`:
   - **دكتور جديد** → املأ الفورم → بعد الحفظ لازم تظهر نافذة فيها **كود الدخول**.
   - **كود دخول جديد** على دكتور موجود → لازم كود مختلف (القديم يبطل).
   - **إيقاف/تفعيل** → البادج بيتغيّر.
   - **قنوات الدكتور** → توجل أي قناة → يتحفظ.
5. **المحادثات:** `awncare/conversations.html` — اختار دكتور من القايمة → تظهر الرسايل،
   وكل رد AI فيه زرار يفتح التنفيذ في n8n (لو فيه سجل تنفيذ).

## المرحلة الجاية — فتحي

عشان نفعّل تبويب فتحي (`enabled: true` في `config.js`) محتاجين على مشروع فتحي:

- طبقة أدمن مطابقة لـ عون كير: جدول `app_admins` + دالة `app_is_admin()`
  (نفس منطق `020_admin_dashboard.sql`) — المدير بيبقى عنده مستخدم Auth على
  المشروعين، وبيسجّل دخول في الاتنين.
- دوال `admin_*` للقراءة (شركات + شات من `conversations`/`messages`) وللكتابة:
  - توجل `chat_enabled` + توجلات وحدات لكل شركة (نضيف عمود flags للشركات).
  - إنشاء شركة + `set_dashboard_code` (موجود) لإدارة كود الدخول (إنشاء/تغيير).
  - تفعيل/إيقاف شركة.
- صفحات `fathi/overview.html` (فعلية) + `subscriptions.html` + `clients.html` +
  `conversations.html` — بنفس مكوّنات `assets/` الجاهزة.

## النشر (GitHub Pages)

الريبو ده بينشر تلقائيًا على **awnagent.com** (ملف `CNAME`). اللوحة الموحّدة دي
موجودة في **جذر الريبو**، فبتفتح مباشرة على `https://awnagent.com/login.html`.
الداشبورد القديمة (`admin-dashboard/`) اتشالت واللوحة دي بقت البديل الكامل.
أي push على فرع `main` بيتنشر خلال دقايق.

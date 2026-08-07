# داشبورد المدير — Doctor Assistant

موقع HTML/CSS/JS ثابت بالكامل (من غير أي build step أو Node على السيرفر) — بيتكلم
مباشرة مع نفس Supabase بتاع النظام عن طريق `@supabase/supabase-js` من CDN. ده يعني
إنك تقدر ترفعه لأي استضافة ستاتيك (أو حتى استضافة عادية بالـ FTP) وتربطه بدومينك
من غير ما تحتاج تشغّل أي سيرفر Node.

## المحتوى

- `login.html` — تسجيل الدخول (Supabase Auth).
- `index.html` — نظرة عامة على الاشتراكات (مين مشترك في إيه باقة، وبيستخدم فعليًا
  إيه من عيادة/راوند/طوارئ).
- `doctors.html` — عدد الحالات لكل دكتور بالشهر (مدخل الحساب اليدوي).
- `conversations.html` — مراجعة محادثة أي دكتور مع الـ AI، مع لينك لتنفيذ كل رد
  في n8n.
- `config.js` — الملف الوحيد المفروض تعدّله بعد الرفع.
- `assets/` — الأنماط والكود المشترك (`style.css`, `supabase.js`, `nav.js`).

## خطوات التشغيل

### 1) شغّل المايجريشن في Supabase

من Supabase Dashboard → SQL Editor، نفّذ الملفين (بالترتيب) لو لسه ما اتنفّذوش:
- `../migrations/020_admin_dashboard.sql` — بيضيف:
  - جدول `flow_execution_log` (سجل تنفيذات n8n)
  - جدول `app_admins` (مين مسموح له يدخل الداشبورد)
  - الدوال `admin_conversations_feed` / `admin_case_counts` / `admin_workspaces_overview`
- `../migrations/021_admin_doctor_channels.sql` — بيضيف دالة `admin_doctor_channels`
  اللي بتغذّي قايمة "المحادثات" في صفحة مراجعة المحادثات (زي قايمة الشاتس في أي
  تطبيق مراسلة).

### 2) حدّث الـ 3 ورك-فلوز في n8n

الملفات دي اتعدّلت (فيها node جديد اسمه **Log Execution** بيسجّل رقم كل تنفيذ):
- `Clinic - n8n Workflow (Mobile Webhook).json`
- `Rounds (Round) - n8n Workflow (Mobile Webhook).json`
- `Dash (ED) - n8n Workflow (Mobile Webhook).json`

استوردهم (Import from File) في نفس الـ workflow القديم في n8n بتاعك (Overwrite)،
وتأكد إن الـ credential بتاع Postgres (اسمه "Round_note") اتماب صح على الـ node
الجديد — لو n8n طلب منك تختار credential يدوي، اختار نفس الـ credential
المستخدم في باقي نودز الـ workflow.

### 3) عدّل `config.js`

افتح `config.js` وحط فيه:
- `SUPABASE_URL` و `SUPABASE_ANON_KEY` — من Supabase Dashboard → Project Settings → API
  (الـ anon key ده عمومًا public وده طبيعي — كل الحماية الفعلية جوه الدوال نفسها
  عن طريق `app_is_admin()`، مش عن طريق إخفاء المفتاح).
- `N8N_BASE_URL` — رابط n8n بتاعك (من غير `/` في الآخر)، عشان لينك التنفيذ يشتغل.

### 4) ضيف نفسك كإداري

الداشبورد ده معندوش صفحة تسجيل حساب جديد (بنفس فلسفة النظام: أي عضو جديد
بيتضاف يدويًا، زي ما بيحصل مع الأطباء بالظبط):

1. من Supabase Dashboard → Authentication → Users → **Add user** — دخّل إيميلك
   وكلمة سر.
2. من SQL Editor نفّذ:
   ```sql
   insert into app_admins (id, email, role)
   select id, email, 'owner' from auth.users where email = 'you@example.com';
   ```
3. كرر الخطوتين لأي حد من فريقك هينضم بعدين (بس حط `role = 'admin'` بدل `'owner'`).

### 5) جرّبه محليًا (اختياري)

الصفحات بتستخدم ES modules، فمتصفحات زي Chrome بترفض تفتحها لو دبلكلكت على
الملف مباشرة (`file://`). شغّل سيرفر ستاتيك بسيط جوه الفولدر ده بدلًا من كده:

```bash
npx serve .
# أو: python -m http.server 8080
```

وبعدين افتح `http://localhost:PORT/login.html`.

### 6) ارفعه واربطه بالدومين

ارفع محتوى الفولدر ده (كل الملفات اللي جوه `admin-dashboard/`) لأي استضافة
ستاتيك — Netlify (سحب وإفلات)، Cloudflare Pages، أو حتى استضافة عادية بالـ FTP —
وحوّل الدومين بتاعك عليها. مفيش أي سيرفر أو Node مطلوب يشتغل ع السيرفر؛
كله بيتكلم مباشرة مع Supabase من المتصفح.

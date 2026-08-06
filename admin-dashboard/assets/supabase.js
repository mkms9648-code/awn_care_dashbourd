// ============================================================================
// عميل Supabase مشترك + حراسة الدخول (auth guard) لكل صفحات الداشبورد.
// محمّل كـ ES module من كل صفحة — <script type="module" src="assets/app.js">
// بيستخدم Supabase JS من CDN (esm.sh) عشان محتاجينش أي خطوة build.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cfg = window.APP_CONFIG || {};

if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.includes("YOUR-PROJECT")) {
  document.addEventListener("DOMContentLoaded", () => {
    document.body.innerHTML =
      '<div class="center-msg">لسه محتاج تعدّل ملف <code>config.js</code> بمفاتيح Supabase بتاعتك.</div>';
  });
  throw new Error("APP_CONFIG not set — edit config.js first.");
}

export const supabase = createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);

// بيتأكد إن فيه جلسة دخول + إن صاحبها موجود في app_admins. لو لأ، بيحوّل
// لصفحة الدخول أو بيوريه رسالة "مش مصرّح". لو تمام بيرجّع الجلسة.
export async function requireAdmin() {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session) {
    location.href = "login.html";
    return null;
  }

  const { data: isAdmin, error } = await supabase.rpc("app_is_admin");
  if (error || !isAdmin) {
    document.body.innerHTML =
      '<div class="center-msg">حسابك (' +
      escapeHtml(session.user.email || "") +
      ") مش مضاف كإداري في الداشبورد ده.<br>" +
      "لازم حد عنده وصول لقاعدة البيانات يضيفك:<br>" +
      '<code>insert into app_admins(id, email, role) select id, email, \'admin\' ' +
      "from auth.users where email = '" +
      escapeHtml(session.user.email || "") +
      "';</code></div>";
    return null;
  }

  return session;
}

export async function signOut() {
  await supabase.auth.signOut();
  location.href = "login.html";
}

export function n8nExecutionUrl(workflowId, executionId) {
  if (!workflowId || !executionId) return null;
  const base = (cfg.N8N_BASE_URL || "").replace(/\/+$/, "");
  return base + "/workflow/" + encodeURIComponent(workflowId) + "/executions/" + encodeURIComponent(executionId);
}

export function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[c]));
}

export function fmtDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return d.toLocaleString("ar-EG", { dateStyle: "medium", timeStyle: "short" });
}

// ============================================================================
// أدوات فتحي: عميل Supabase بتاع فتحي + بوابة "سر الأدمن" + غلاف نداء الدوال.
// فتحي مشروع منفصل بدون Supabase Auth للأدمن، فبنأمّن دواله بسر أدمن (bcrypt)
// بيتبعت مع كل نداء — نفس فلسفة كود دخول العميل الموجودة في فتحي.
// ============================================================================
import { client } from "./core.js";
import { openModal, toast } from "./ui.js";

export const fathi = client("fathi");
const KEY = "fathi-admin-secret";

export const getSecret = () => sessionStorage.getItem(KEY) || "";
export const setSecret = (s) => sessionStorage.setItem(KEY, s);
export const clearSecret = () => sessionStorage.removeItem(KEY);

// نداء دالة أدمن فتحي مع حقن السر. لو السر غلط بيرجّع error زي أي نداء.
export async function rpc(fn, args = {}) {
  return fathi.rpc(fn, { p_secret: getSecret(), ...args });
}

// بيتأكد إن فيه سر صالح — بيتحقق منه بنداء خفيف. لو مفيش/غلط بيطلبه بنافذة.
// بيرجّع true لو تمام، وبيوقف الصفحة (يفضل يطلب) لو المستخدم ألغى.
export async function ensureSecret() {
  if (getSecret()) {
    const { error } = await fathi.rpc("admin_list_companies", { p_secret: getSecret() });
    if (!error) return true;
    clearSecret();
  }
  return promptSecret();
}

function promptSecret() {
  return new Promise((resolve) => {
    const body = document.createElement("div");
    body.innerHTML = `
      <p class="muted" style="margin:0 0 14px">اللوحة دي بتدير عملاء فتحي. اكتب سر أدمن فتحي عشان تكمّل.</p>
      <div class="field"><label class="lbl">سر أدمن فتحي</label><input type="password" id="fs" autocomplete="off" /></div>
      <div class="hint">بيتحدد لمرة واحدة في Supabase: <code>select set_admin_secret('...')</code></div>`;
    const m = openModal({
      title: "دخول أدمن فتحي", icon: "ti-lock", body, actionsLeadSpacer: true,
      actions: [{
        label: "دخول", icon: "ti-login", onClick: async () => {
          const v = body.querySelector("#fs").value.trim();
          if (!v) { toast("اكتب السر", "error"); return; }
          const { error } = await fathi.rpc("admin_list_companies", { p_secret: v });
          if (error) { toast("سر غلط أو الطبقة مش متسطبة", "error"); return; }
          setSecret(v);
          m.close();
          resolve(true);
        },
      }],
    });
    // إغلاق النافذة من غير سر = رجوع للنظرة العامة بتاعت عون كير
    m.root.addEventListener("mousedown", (e) => {
      if (e.target === m.root) { m.close(); location.href = "../awncare/overview.html"; }
    });
  });
}

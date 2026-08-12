// ============================================================================
// النواة المشتركة: عملاء Supabase للمنتجين + حراسة دخول المدير + أدوات عامة.
// محمّلة كـ ES module من كل صفحة. بتستخدم supabase-js من CDN (بدون build step).
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cfg = window.APP_CONFIG || {};

if (!cfg.PRODUCTS || !cfg.PRODUCTS.awncare) {
  document.addEventListener("DOMContentLoaded", () => {
    document.body.innerHTML =
      '<div class="center-msg">لسه محتاج تظبط ملف <code>config.js</code> بمفاتيح Supabase.</div>';
  });
  throw new Error("APP_CONFIG not set — edit config.js first.");
}

// عميل Supabase واحد لكل منتج (كل منتج مشروع منفصل). عميل الأوث بس هو اللي
// بيحتفظ بجلسة (persistSession)؛ الباقي بيتكلم بمفتاح anon من غير جلسة.
const clients = {};
export function client(product) {
  if (!clients[product]) {
    const p = cfg.PRODUCTS[product];
    if (!p) throw new Error("unknown product: " + product);
    clients[product] = createClient(p.SUPABASE_URL, p.SUPABASE_ANON_KEY, {
      auth: {
        persistSession: product === cfg.AUTH_PRODUCT,
        autoRefreshToken: product === cfg.AUTH_PRODUCT,
        storageKey: "awn-admin-" + product,
      },
    });
  }
  return clients[product];
}

// عميل بدون جلسة (anon role) — للدوال الممنوحة لـ anon بس (زي app_* بتاعت
// بورد الدكتور). العميل العادي بيحمل جلسة المدير (authenticated) فمينفعش معاها.
const anonClients = {};
export function anonClient(product) {
  if (!anonClients[product]) {
    const p = cfg.PRODUCTS[product];
    if (!p) throw new Error("unknown product: " + product);
    anonClients[product] = createClient(p.SUPABASE_URL, p.SUPABASE_ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false, storageKey: "awn-anon-" + product },
    });
  }
  return anonClients[product];
}

export const authClient = client(cfg.AUTH_PRODUCT);
export const productConfig = (product) => cfg.PRODUCTS[product];
export const authProduct = cfg.AUTH_PRODUCT;

// المنتج النشط حاليًا — بيتحدد من ?p=... في اللينك، وإلا awncare افتراضيًا.
export function activeProduct() {
  const p = new URLSearchParams(location.search).get("p");
  return p && cfg.PRODUCTS[p] ? p : "awncare";
}

// بيطبّق لون accent المنتج على الصفحة كلها (متغيّرات CSS).
export function applyProductTheme(product) {
  const p = cfg.PRODUCTS[product];
  if (!p || !p.accent) return;
  const root = document.documentElement.style;
  root.setProperty("--accent", p.accent);
  if (product === "fathi") {
    root.setProperty("--accent-dark", "#0A2E20");
    root.setProperty("--accent-light", "#E8F2EC");
    root.setProperty("--accent-border", "#B0C9BC");
  }
}

// بيتأكد إن فيه جلسة دخول على مشروع الأوث + إن صاحبها في app_admins.
export async function requireAdmin() {
  const { data: { session } } = await authClient.auth.getSession();
  if (!session) {
    location.href = "login.html";
    return null;
  }
  const { data: isAdmin, error } = await authClient.rpc("app_is_admin");
  if (error || !isAdmin) {
    document.body.innerHTML =
      '<div class="center-msg">حسابك (' + escapeHtml(session.user.email || "") +
      ") مش مضاف كإداري.<br>لازم حد عنده صلاحية على قاعدة البيانات يضيفك:<br>" +
      "<code>insert into app_admins(id, email, role) select id, email, 'admin' " +
      "from auth.users where email = '" + escapeHtml(session.user.email || "") + "';</code></div>";
    return null;
  }
  return session;
}

export async function signOut() {
  await authClient.auth.signOut();
  location.href = "login.html";
}

export function n8nExecutionUrl(product, workflowId, executionId) {
  if (!workflowId || !executionId) return null;
  const base = (cfg.PRODUCTS[product]?.N8N_BASE_URL || "").replace(/\/+$/, "");
  return base + "/workflow/" + encodeURIComponent(workflowId) + "/executions/" + encodeURIComponent(executionId);
}

export function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

export function fmtDate(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("ar-EG", { dateStyle: "medium", timeStyle: "short" });
}

export function initials(name) {
  const parts = (name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
}

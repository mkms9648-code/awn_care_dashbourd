// ============================================================================
// مكتبة واجهة صغيرة: نوافذ (modals)، تنبيهات (toasts)، تأكيد، قوائم إجراءات،
// نسخ للحافظة. من غير أي مكتبة خارجية — كلها DOM بسيط.
// ============================================================================
import { escapeHtml } from "./core.js";

// ---- Toast ----------------------------------------------------------------
function toastHost() {
  let host = document.getElementById("toast-host");
  if (!host) {
    host = document.createElement("div");
    host.id = "toast-host";
    document.body.appendChild(host);
  }
  return host;
}

export function toast(message, type = "info", ms = 3200) {
  const el = document.createElement("div");
  el.className = "toast " + (type === "good" ? "good" : type === "error" ? "error" : "");
  const icon = type === "good" ? "ti-circle-check" : type === "error" ? "ti-alert-triangle" : "ti-info-circle";
  el.innerHTML = `<i class="ti ${icon}"></i><span></span>`;
  el.querySelector("span").textContent = message;
  toastHost().appendChild(el);
  requestAnimationFrame(() => el.classList.add("show"));
  setTimeout(() => {
    el.classList.remove("show");
    setTimeout(() => el.remove(), 220);
  }, ms);
}

// ---- Modal ----------------------------------------------------------------
// openModal({ title, subtitle, icon, body(HTMLElement|string), wide,
//             actions:[{label, variant, icon, onClick(close)}] }) -> { close, root }
export function openModal(opts = {}) {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";

  const actionsHtml = (opts.actions || [])
    .map((a, i) => `<button class="btn ${a.variant || ""}" data-act="${i}">${a.icon ? `<i class="ti ${a.icon}"></i>` : ""}${escapeHtml(a.label)}</button>`)
    .join("");

  overlay.innerHTML = `
    <div class="modal ${opts.wide ? "modal-wide" : ""}" role="dialog" aria-modal="true">
      <div class="modal-head">
        ${opts.icon ? `<div class="m-icon"><i class="ti ${opts.icon}"></i></div>` : ""}
        <div>
          <h3></h3>
          ${opts.subtitle ? `<div class="m-sub"></div>` : ""}
        </div>
        <button class="icon-btn m-close" title="إغلاق"><i class="ti ti-x"></i></button>
      </div>
      <div class="modal-body"></div>
      ${actionsHtml ? `<div class="modal-foot">${opts.actionsLeadSpacer ? '<div class="spacer"></div>' : ""}${actionsHtml}</div>` : ""}
    </div>`;

  overlay.querySelector("h3").textContent = opts.title || "";
  if (opts.subtitle) overlay.querySelector(".m-sub").textContent = opts.subtitle;

  const bodyEl = overlay.querySelector(".modal-body");
  if (opts.body instanceof HTMLElement) bodyEl.appendChild(opts.body);
  else bodyEl.innerHTML = opts.body || "";

  function close() {
    overlay.classList.remove("open");
    document.removeEventListener("keydown", onKey);
    setTimeout(() => overlay.remove(), 180);
  }
  function onKey(e) { if (e.key === "Escape") close(); }

  overlay.querySelector(".m-close").addEventListener("click", close);
  overlay.addEventListener("mousedown", (e) => { if (e.target === overlay) close(); });
  document.addEventListener("keydown", onKey);

  (opts.actions || []).forEach((a, i) => {
    overlay.querySelector(`[data-act="${i}"]`).addEventListener("click", () => a.onClick?.(close));
  });

  document.body.appendChild(overlay);
  requestAnimationFrame(() => overlay.classList.add("open"));

  // ركّز أول input لو موجود
  setTimeout(() => overlay.querySelector("input,select,textarea")?.focus(), 60);

  return { close, root: overlay };
}

// نافذة تأكيد بسيطة -> Promise<boolean>
export function confirmDialog({ title, message, confirmLabel = "تأكيد", danger = false, icon = "ti-help-circle" } = {}) {
  return new Promise((resolve) => {
    const m = openModal({
      title, icon,
      body: `<p style="margin:0;line-height:1.8;color:var(--ink)">${escapeHtml(message || "")}</p>`,
      actionsLeadSpacer: true,
      actions: [
        { label: "إلغاء", variant: "btn-neutral", onClick: (close) => { close(); resolve(false); } },
        { label: confirmLabel, variant: danger ? "btn-danger" : "", onClick: (close) => { close(); resolve(true); } },
      ],
    });
    m.root.addEventListener("mousedown", (e) => { if (e.target === m.root) resolve(false); });
  });
}

// ---- Row action menu (كباب ثلاث نقاط) ------------------------------------
// buildMenu([{label,icon,danger,onClick}]) -> HTMLElement جاهز يتحط في الصف
export function buildMenu(items = []) {
  const wrap = document.createElement("div");
  wrap.className = "menu";
  wrap.innerHTML = `<button class="icon-btn" title="إجراءات"><i class="ti ti-dots-vertical"></i></button><div class="menu-panel"></div>`;
  const panel = wrap.querySelector(".menu-panel");

  items.forEach((it) => {
    if (it.sep) { const s = document.createElement("div"); s.className = "menu-sep"; panel.appendChild(s); return; }
    const b = document.createElement("button");
    b.className = "menu-item" + (it.danger ? " danger" : "");
    b.innerHTML = `<i class="ti ${it.icon || "ti-point"}"></i><span></span>`;
    b.querySelector("span").textContent = it.label;
    b.addEventListener("click", () => { closeAllMenus(); it.onClick?.(); });
    panel.appendChild(b);
  });

  wrap.querySelector(".icon-btn").addEventListener("click", (e) => {
    e.stopPropagation();
    const wasOpen = wrap.classList.contains("open");
    closeAllMenus();
    if (!wasOpen) wrap.classList.add("open");
  });
  return wrap;
}
function closeAllMenus() { document.querySelectorAll(".menu.open").forEach((m) => m.classList.remove("open")); }
document.addEventListener("click", closeAllMenus);

// ---- Clipboard ------------------------------------------------------------
export async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast("اتنسخ للحافظة", "good", 1600);
  } catch {
    toast("مقدرش ينسخ تلقائيًا — انسخه يدويًا", "error");
  }
}

// حالة تحميل مؤقتة على زرار -> بيرجّع دالة استرجاع
export function busy(btn, label = "جاري…") {
  const prev = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = `<i class="ti ti-loader-2 spin"></i> ${escapeHtml(label)}`;
  return () => { btn.disabled = false; btn.innerHTML = prev; };
}

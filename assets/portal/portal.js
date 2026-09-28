/* FOX-1 device portal — vanilla ES2020, no framework, no build step.
   Nothing here makes an external request. Everything that comes from the
   device is inserted as text (textContent / text nodes), never as HTML; the
   only innerHTML is the static icon markup defined in this file. */
(() => {
'use strict';

/* ================================================================ helpers */

const D = document;
const SVGNS = 'http://www.w3.org/2000/svg';
const desk = window.matchMedia('(min-width: 960px)');
const PROPS = new Set(['value', 'checked', 'disabled', 'selected', 'readOnly']);

function h(tag, props, ...kids) {
  const el = D.createElement(tag);
  if (props) {
    for (const k of Object.keys(props)) {
      const v = props[k];
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k === 'style') el.style.cssText = v;
      else if (k === 'hidden') el.hidden = !!v;
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
      else if (PROPS.has(k)) el[k] = v;
      else el.setAttribute(k, v === true ? '' : String(v));
    }
  }
  return add(el, kids);
}
function add(el, kids) {
  for (const k of kids) {
    if (k == null || k === false || k === '') continue;
    if (Array.isArray(k)) add(el, k);
    else el.append(k instanceof Node ? k : D.createTextNode(String(k)));
  }
  return el;
}
function sv(tag, attrs, text) {
  const el = D.createElementNS(SVGNS, tag);
  if (attrs) for (const k of Object.keys(attrs)) if (attrs[k] != null) el.setAttribute(k, attrs[k]);
  if (text != null) el.textContent = text;
  return el;
}

const ICONS = {
  home: '<path d="M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
  micOff: '<path d="M3 3l18 18M9 9v2a3 3 0 0 0 5.1 2.1M15 10V6a3 3 0 0 0-5.7-1.3M5.5 11a6.5 6.5 0 0 0 10.4 5.2M18.5 11a6.5 6.5 0 0 1-.6 2.7M12 17.5V21"/>',
  pulse: '<path d="M3 12h4l2.5-6 5 12 2.5-6H21"/>',
  chat: '<path d="M20 11.5a7.5 7.5 0 0 1-11.2 6.6L4 19.5l1.4-4.3A7.5 7.5 0 1 1 20 11.5z"/>',
  more: '<circle cx="5.5" cy="12" r="1.4" fill="currentColor"/><circle cx="12" cy="12" r="1.4" fill="currentColor"/><circle cx="18.5" cy="12" r="1.4" fill="currentColor"/>',
  phone: '<path d="M5 4h3.5l1.8 4.5-2.3 1.4a11 11 0 0 0 6.1 6.1l1.4-2.3L20 15.5V19a1 1 0 0 1-1 1A16 16 0 0 1 4 5a1 1 0 0 1 1-1z"/>',
  book: '<path d="M12 6.5C10 5 7 4.5 4 5v13c3-.5 6 0 8 1.5 2-1.5 5-2 8-1.5V5c-3-.5-6 0-8 1.5zM12 6.5V19"/>',
  sliders: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
  watch: '<rect x="6.5" y="6" width="11" height="12" rx="3"/><path d="M9 6l.6-3h4.8l.6 3M9 18l.6 3h4.8l.6-3M12 9.5V12l1.5 1"/>',
  back: '<path d="M15 5l-7 7 7 7"/>',
  download: '<path d="M12 4v11M7.5 10.5 12 15l4.5-4.5M5 20h14"/>',
  upload: '<path d="M12 16V5M7.5 9.5 12 5l4.5 4.5M5 20h14"/>',
  chevL: '<path d="M14.5 6l-6 6 6 6"/>',
  chevR: '<path d="M9.5 6l6 6-6 6"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  trash: '<path d="M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13M10 11v5M14 11v5"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  checkSq: '<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M8.5 12.2l2.3 2.3 4.7-4.8"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  eyeOff: '<path d="M3 3l18 18M10.6 6A9.8 9.8 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a17 17 0 0 1-2.6 3.4M6.6 6.9C4 8.6 2.5 12 2.5 12S6 18.5 12 18.5a9 9 0 0 0 4.2-1M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
  battery: '<rect x="3" y="7.5" width="16" height="9" rx="2"/><path d="M21 11v2M6 10.5v3"/>',
  bolt: '<path d="M13 3 5 13.5h6L10 21l8-10.5h-6z"/>',
  ring: '<circle cx="12" cy="14" r="6.5"/><path d="M9.5 4.5h5L12 7.5z"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  steps: '<path d="M8.5 3.5c1.6 0 2.4 1.9 2.4 4.1S10 11.5 8.5 11.5 6.1 10 6.1 7.6 6.9 3.5 8.5 3.5zM15.5 8.5c1.6 0 2.4 1.9 2.4 4.1s-.9 3.9-2.4 3.9-2.4-1.5-2.4-3.9.8-4.1 2.4-4.1zM6.5 14.5l3.8.2-.3 2.6a1.8 1.8 0 0 1-3.6-.3zM13.6 19.5l3.8.2-.3 1.2"/>',
  heart: '<path d="M12 20s-7.5-4.6-7.5-10A4.2 4.2 0 0 1 12 7.3 4.2 4.2 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z"/>',
  moon: '<path d="M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10z"/>',
  drop: '<path d="M12 3.5s6 6.4 6 11a6 6 0 0 1-12 0c0-4.6 6-11 6-11z"/>',
  gauge: '<path d="M4.5 17.5a8.5 8.5 0 1 1 15 0"/><path d="M12 13.5l3.5-4"/>',
  alert: '<path d="M12 4 21 19.5H3z"/><path d="M12 10v4.5M12 17v.01"/>',
  info: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5M12 8v.01"/>',
  sparkle: '<path d="M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9zM18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/>',
  user: '<circle cx="12" cy="8.5" r="3.5"/><path d="M5 20a7 7 0 0 1 14 0"/>',
  external: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  power: '<path d="M12 3.5V12M7 6.5a7.5 7.5 0 1 0 10 0"/>',
  logout: '<path d="M14 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 8l-4 4 4 4M6 12h10"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.4 3.5 5.3 3.5 8.5s-1 6.1-3.5 8.5c-2.5-2.4-3.5-5.3-3.5-8.5s1-6.1 3.5-8.5z"/>',
  camera: '<path d="M4 8a1 1 0 0 1 1-1h3l1.5-2h5L16 7h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1z"/><circle cx="12" cy="13" r="3.5"/>',
  type: '<path d="M5 7V5h14v2M12 5v14M9 19h6"/>',
  calendar: '<rect x="4" y="5.5" width="16" height="14.5" rx="2"/><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4"/>',
  code: '<path d="M8.5 8 4.5 12l4 4M15.5 8l4 4-4 4"/>',
  shield: '<path d="M12 3.5 19 6v5.5c0 4.3-3 7.7-7 9-4-1.3-7-4.7-7-9V6z"/><path d="M12 9v3.5M12 15.5v.01"/>',
  wifi: '<path d="M3.5 9.5a12 12 0 0 1 17 0M6.5 12.8a7.5 7.5 0 0 1 11 0M9.5 16a3 3 0 0 1 5 0M12 19.5v.01"/>',
  wifiOff: '<path d="M3 3l18 18M8.5 16a4.5 4.5 0 0 1 7 0M5.5 12.8a8.5 8.5 0 0 1 4-2.2M18.5 12.8a8.5 8.5 0 0 0-2.3-1.6M2.5 9.5a13 13 0 0 1 4.3-2.8M21.5 9.5A13 13 0 0 0 12 5.5c-.8 0-1.6.1-2.4.2M12 19.5v.01"/>',
  list: '<path d="M9 6.5h11M9 12h11M9 17.5h11M4.5 6.5h.01M4.5 12h.01M4.5 17.5h.01"/>',
  flag: '<path d="M5 21V4.5M5 4.5h11l-2 4 2 4H5"/>',
  hand: '<path d="M7 11.5V6.5a1.5 1.5 0 0 1 3 0v4M10 10.5V5a1.5 1.5 0 0 1 3 0v5.5M13 10.5V6a1.5 1.5 0 0 1 3 0v6M16 10a1.5 1.5 0 0 1 3 0v4a6.5 6.5 0 0 1-6.5 6.5h-1A6 6 0 0 1 6 17l-2.3-3.7a1.5 1.5 0 0 1 2.5-1.6L7 13"/>',
};
function icon(name, cls) {
  const s = D.createElementNS(SVGNS, 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  s.setAttribute('class', 'ic' + (cls ? ' ' + cls : ''));
  s.setAttribute('aria-hidden', 'true');
  s.setAttribute('focusable', 'false');
  s.innerHTML = ICONS[name] || ''; // static markup from this file only
  return s;
}

/* ============================================================ formatting */

const nf = new Intl.NumberFormat();
const nf1 = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });
const fmtN = (n) => (n == null || !Number.isFinite(+n) ? '–' : nf.format(Math.round(+n)));
const tfmt = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const fmtTime = (d) => (d ? tfmt.format(d) : '–');
const names = (opt, n, mk) => Array.from({ length: n }, (_, i) => new Intl.DateTimeFormat(undefined, opt).format(mk(i)));
const WD = names({ weekday: 'short' }, 7, (i) => new Date(2026, 0, 4 + i)); // 4 Jan 2026 is a Sunday
const WDL = names({ weekday: 'long' }, 7, (i) => new Date(2026, 0, 4 + i));
const MON = names({ month: 'short' }, 12, (i) => new Date(2026, i, 1));
const MONL = names({ month: 'long' }, 12, (i) => new Date(2026, i, 1));
const pad = (n) => String(n).padStart(2, '0');
const cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
const plural = (n, one, many) => `${fmtN(n)} ${n === 1 ? one : many}`;
const enc = encodeURIComponent;

/** Local ISO-8601 without a zone, parsed as local time on every browser. */
function parseT(s) {
  if (!s) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?)?/.exec(String(s));
  if (!m) { const d = new Date(s); return isNaN(d) ? null : d; }
  return new Date(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0),
    m[7] ? +m[7].padEnd(3, '0').slice(0, 3) : 0);
}
const dkey = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const day0 = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
const dayDiff = (a, b) => Math.round((day0(a) - day0(b)) / 864e5);
function fmtDate(d, withYear) {
  const s = `${WD[d.getDay()]} ${d.getDate()} ${MON[d.getMonth()]}`;
  return (withYear ?? d.getFullYear() !== new Date().getFullYear()) ? `${s} ${d.getFullYear()}` : s;
}
function fmtDayRel(d) {
  if (!d) return '–';
  const n = dayDiff(new Date(), d);
  return n === 0 ? 'Today' : n === 1 ? 'Yesterday' : fmtDate(d);
}
const longDate = (d) => `${WDL[d.getDay()]} ${d.getDate()} ${MONL[d.getMonth()]}`;
function rel(d) {
  if (!d) return '';
  const now = new Date();
  const s = (now - d) / 1000;
  if (s < 45) return 'just now';
  if (s < 3600) return `${Math.max(1, Math.round(s / 60))} min ago`;
  const dd = dayDiff(now, d);
  if (dd === 0) return s < 6 * 3600 ? `${Math.floor(s / 3600)} h ago` : `today ${fmtTime(d)}`;
  if (dd === 1) return `yesterday ${fmtTime(d)}`;
  if (dd < 7) return `${WD[d.getDay()]} ${fmtTime(d)}`;
  return fmtDate(d);
}
function dur(sec) {
  if (sec == null) return '–';
  sec = Math.max(0, Math.round(sec));
  if (sec < 60) return `${sec} s`;
  if (sec < 3600) { const m = Math.floor(sec / 60), s = sec % 60; return s ? `${m} min ${s} s` : `${m} min`; }
  const hh = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
  return m ? `${hh} h ${m} min` : `${hh} h`;
}
function hm(min) {
  if (min == null) return '–';
  min = Math.round(min);
  const hh = Math.floor(min / 60), m = min % 60;
  return hh ? (m ? `${hh} h ${m} min` : `${hh} h`) : `${m} min`;
}
/** "7 h 10 min" for a big number: digits large, units small. */
function hmBig(min) {
  if (min == null) return ['–'];
  min = Math.round(min);
  const hh = Math.floor(min / 60), m = min % 60, out = [];
  if (hh) out.push(String(hh), h('small', null, 'h'));
  if (m || !hh) out.push(String(m), h('small', null, 'min'));
  return out;
}
const band = (v) => (v == null ? null : v <= 25 ? ['rest', 'Rest'] : v <= 50 ? ['low', 'Low'] : v <= 75 ? ['med', 'Medium'] : ['high', 'High']);
const initials = (name) => (name || '').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('');
const modelName = (m) => {
  const known = S.settings && S.settings.options.models.find((x) => x.value === m);
  if (known) return known.label;
  const s = String(m || '').replace(/^models\//, '').replace(/-preview.*$/, '').replace(/-\d{2}-\d{4}$/, '');
  return s.split('-').filter(Boolean).map((w) => (/^\d/.test(w) ? w : cap(w))).join(' ');
};
function shortRel(d) {
  if (!d) return '';
  const n = dayDiff(new Date(), d);
  if (n === 0) return (new Date() - d) < 6 * 3600e3 ? rel(d) : fmtTime(d);
  if (n === 1) return 'Yesterday';
  return n < 7 ? WD[d.getDay()] : `${d.getDate()} ${MON[d.getMonth()]}`;
}

/* ================================================================= state */

const S = {
  authed: false,
  off: false,
  force: false,
  returnTo: '#/home',
  lastHash: null,
  prevHash: null,
  cur: null,
  overview: null,
  settings: null, // {base, draft, options} — survives a sign-in so edits aren't lost
  notes: { q: '', filter: 'all', all: false },
  chatsQ: '',
  focusConv: null,
  loginNote: null,
  lockFor: 0,
  setupDone: null, // from /api/setup; false sends every page to #/setup
  aiName: 'FOX-1', // what the wearer calls the assistant (Settings → Name)
};
// The assistant's name wherever the Hub mentions it. Never hard-coded.
const aiName = () => S.aiName || 'FOX-1';
function learnName(n) { if (typeof n === 'string' && n.trim()) S.aiName = n.trim(); }

const pref = {
  get(k, d) { try { const v = localStorage.getItem('fox1.' + k); return v == null ? d : v; } catch (_) { return d; } },
  set(k, v) { try { localStorage.setItem('fox1.' + k, v); } catch (_) { /* private mode */ } },
};

/* =================================================================== api */

class ApiError extends Error {
  constructor(status, message, body) { super(message); this.status = status; this.body = body; }
}
// `poll`: a background refresh. The device does not count it as use, so a tab
// left open does not keep the portal on for ever.
async function api(path, { method = 'GET', body, auth = true, poll = false } = {}) {
  let res;
  try {
    const headers = {};
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (poll) headers['X-Portal-Poll'] = '1';
    res = await fetch(path, {
      method,
      credentials: 'same-origin',
      cache: 'no-store',
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch (_) {
    throw new ApiError(0, 'Can’t reach your device.');
  }
  let data = null;
  const text = await res.text().catch(() => '');
  if (text) { try { data = JSON.parse(text); } catch (_) { data = null; } }
  if (res.status === 401 && auth) { signedOut(); throw new ApiError(401, 'Signed out', data); }
  if (!res.ok || (data && data.ok === false)) {
    throw new ApiError(res.status, (data && data.error) || `The device answered with an error (${res.status}).`, data);
  }
  return data || {};
}
function signedOut() {
  if (!S.authed) return;
  S.authed = false;
  const r = parseHash();
  if (r.name !== 'login') S.returnTo = r.hash;
  S.force = true;
  history.replaceState(null, '', '#/login');
  route();
}
function refreshOverview() {
  return api('/api/overview').then((o) => { S.overview = o; learnName(o.assistant && o.assistant.name); paintSideFoot(); return o; }).catch(() => null);
}

/* ============================================================ components */

function toast(msg, kind = 'ok') {
  const box = D.getElementById('toasts');
  const t = h('div', { class: 'toast toast-' + kind, role: kind === 'error' ? 'alert' : 'status' },
    icon(kind === 'error' ? 'alert' : 'check'), h('span', { text: msg }));
  box.append(t);
  requestAnimationFrame(() => requestAnimationFrame(() => t.classList.add('in')));
  setTimeout(() => { t.classList.remove('in'); setTimeout(() => t.remove(), 300); }, kind === 'error' ? 5000 : 2800);
}

function confirmDialog({ title, body, ok = 'Delete', danger = true }) {
  const dlg = D.getElementById('dlg');
  if (typeof dlg.showModal !== 'function') return Promise.resolve(window.confirm(title + (body ? '\n\n' + body : '')));
  dlg.replaceChildren(h('form', { method: 'dialog', class: 'dlg-body' },
    h('h2', { class: 'dlg-title', id: 'dlg-t', text: title }),
    body && h('p', { class: 'dlg-text', id: 'dlg-d', text: body }),
    h('div', { class: 'dlg-actions' },
      h('button', { class: 'btn btn-ghost', value: 'cancel', text: 'Cancel' }),
      h('button', { class: 'btn ' + (danger ? 'btn-danger' : 'btn-primary'), value: 'ok', text: ok }))));
  dlg.setAttribute('aria-labelledby', 'dlg-t');
  if (body) dlg.setAttribute('aria-describedby', 'dlg-d'); else dlg.removeAttribute('aria-describedby');
  dlg.returnValue = '';
  return new Promise((resolve) => {
    const onClick = (e) => { if (e.target === dlg) dlg.close('cancel'); };
    dlg.addEventListener('click', onClick);
    dlg.addEventListener('close', () => { dlg.removeEventListener('click', onClick); resolve(dlg.returnValue === 'ok'); }, { once: true });
    dlg.showModal();
  });
}

function emptyState(ic, title, text, action) {
  return h('div', { class: 'empty' }, h('div', { class: 'empty-ic' }, icon(ic)), h('h3', { text: title }), text && h('p', { text }), action);
}
function errorState(err, retry) {
  const offline = err && err.status === 0;
  return h('div', { class: 'error-state', role: 'alert' },
    h('div', { class: 'empty-ic' }, icon(offline ? 'wifiOff' : 'alert')),
    h('h3', { text: offline ? 'Can’t reach your device' : 'Couldn’t load this' }),
    h('p', { text: offline
      ? 'Check that FOX-1 Hub is still on, and that this phone or computer is on the same Wi‑Fi as your device.'
      : (err && err.message) || 'The device didn’t answer as expected.' }),
    retry && h('button', { class: 'btn btn-ghost', type: 'button', onclick: retry }, icon('refresh'), 'Retry'));
}
function skel(kind) {
  const L = (w, cls = 'sk-line', style = '') => h('div', { class: 'sk ' + cls, style: (w ? `width:${w};` : '') + style });
  const wrap = h('div', { class: 'skel', role: 'status', 'aria-label': 'Loading' });
  const card = (n, field) => h('div', { class: 'card stack' }, L('50%', 'sk-title'),
    Array.from({ length: n }, (_, i) => (field && i % 2 ? L(null, 'sk', 'height:44px;border-radius:10px') : L(['88%', '34%', '76%'][i % 3]))));
  if (kind === 'rows') {
    for (let i = 0; i < 5; i++) {
      wrap.append(h('div', { class: 'row-flex', style: 'gap:12px;padding:8px 0' }, L(null, 'sk', 'width:40px;height:40px;border-radius:12px;flex:none'),
        h('div', { class: 'grow stack', style: 'gap:8px' }, L('46%'), L('28%'))));
    }
  } else if (kind === 'detail') {
    wrap.append(L('72%', 'sk-title', 'height:24px'), L('40%'), L(null, 'sk-card', 'height:68px'), L('30%'), L('96%'), L('90%'), L('70%'));
  } else if (kind === 'home') {
    wrap.append(L('44%', 'sk-title', 'height:28px'), L('34%'), L(null, 'sk-card', 'height:84px'), L(null, 'sk-tall', 'height:260px'), card(3));
  } else if (kind === 'health') {
    wrap.append(h('div', { class: 'kpis' }, Array.from({ length: 4 }, () => L(null, 'sk-card'))), h('div', { class: 'charts' }, L(null, 'sk-tall'), L(null, 'sk-tall')));
  } else {
    for (let i = 0; i < (kind === 'list' ? 5 : 3); i++) wrap.append(card(kind === 'form' ? 4 : 3, kind === 'form'));
  }
  return wrap;
}
const cardHead = (title, ic, right, cls) => h('div', { class: 'card-head' + (cls ? ' ' + cls : '') },
  h('h2', { class: 'card-title' }, ic && icon(ic), title), right);
const linkTo = (href, text, onclick) => h('a', { class: 'card-link', href, onclick }, text, icon('chevR'));
function lrow({ href, onclick, ic, tone, title, sub, end, current, avatar, wrap, target }) {
  const tag = href ? 'a' : 'button';
  return h(tag, {
    class: 'lrow', href, onclick, type: href ? null : 'button', target,
    rel: target ? 'noopener noreferrer' : null, 'aria-current': current ? 'page' : null,
  },
  avatar || (ic && h('span', { class: 'lrow-ic' + (tone ? ' ' + tone : '') }, icon(ic))),
  h('span', { class: 'lrow-main' }, h('span', { class: 'lrow-title', text: title }),
    sub && h('span', { class: 'lrow-sub' + (wrap ? ' wrap' : ''), text: sub })),
  h('span', { class: 'lrow-end' }, end, icon(target ? 'external' : 'chevR')));
}
function callout(tone, ic, title, text, action) {
  return h('div', { class: 'callout callout-' + tone, role: tone === 'danger' ? 'alert' : null },
    typeof ic === 'string' ? icon(ic) : ic, h('div', null, h('b', { text: title }), text && h('p', { text }), action));
}
function spinner() { return h('span', { class: 'spinner', 'aria-hidden': 'true' }); }
function avatarFor(name, known, lg) {
  const ini = known ? initials(name) : '';
  return h('span', { class: 'avatar' + (known ? '' : ' unknown') + (lg ? ' lg' : ''), 'aria-hidden': 'true' }, ini || icon('user'));
}
async function copyText(t) {
  try {
    if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(t); return true; }
  } catch (_) { /* fall through */ }
  const ta = h('textarea', { style: 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0', readonly: '' });
  ta.value = t;
  D.body.append(ta);
  ta.select();
  try { ta.setSelectionRange(0, t.length); } catch (_) { /* ignore */ }
  let ok = false;
  try { ok = D.execCommand('copy'); } catch (_) { ok = false; }
  ta.remove();
  return ok;
}
function debounce(fn, ms) {
  let t = null;
  const d = (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
  d.cancel = () => clearTimeout(t);
  return d;
}
function searchBox(value, label, onInput) {
  const inp = h('input', { class: 'input', type: 'search', placeholder: label, 'aria-label': label, value, enterkeyhint: 'search', autocomplete: 'off', spellcheck: 'false' });
  const clear = h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Clear search', hidden: !value }, icon('x'));
  inp.addEventListener('input', () => { clear.hidden = !inp.value; onInput(inp.value); });
  clear.addEventListener('click', () => { inp.value = ''; clear.hidden = true; onInput(''); inp.focus(); });
  inp.addEventListener('keydown', (e) => { if (e.key === 'Escape' && inp.value) { e.preventDefault(); clear.click(); } });
  return { el: h('div', { class: 'search', role: 'search' }, icon('search'), inp, clear), input: inp };
}
function highlight(text, q) {
  const words = (q || '').trim().split(/\s+/).filter(Boolean).map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  if (!words.length) return [text];
  const re = new RegExp('(' + words.join('|') + ')', 'gi');
  return String(text).split(re).map((part, i) => (i % 2 ? h('mark', { text: part }) : part));
}
/** Split panes: list + detail. On a phone the detail replaces the list. */
function splitNav(split) {
  let saved = 0;
  return (open) => {
    const was = split.classList.contains('has-detail');
    if (open && !was) {
      saved = window.scrollY;
      split.classList.add('has-detail');
      if (!desk.matches) window.scrollTo(0, 0);
    } else if (!open && was) {
      split.classList.remove('has-detail');
      if (!desk.matches) requestAnimationFrame(() => window.scrollTo(0, saved));
    }
  };
}
function replaceTo(hash) { history.replaceState(null, '', hash); route(); }

/* ================================================================= shell */

const $view = D.getElementById('view');
const $title = D.getElementById('top-title');
const $back = D.getElementById('top-back');
const $actions = D.getElementById('top-actions');

function decorateShell() {
  D.querySelectorAll('[data-icon]').forEach((a) => {
    const ic = icon(a.dataset.icon);
    if (a.closest('.tabbar')) a.prepend(h('span', { class: 'tab-ic' }, ic)); else a.prepend(ic);
  });
  $back.append(icon('back'));
  $back.addEventListener('click', () => {
    const to = $back.dataset.to;
    if (!to) return;
    if (S.prevHash === to) history.back(); else location.hash = to;
  });
  D.getElementById('skip').addEventListener('click', () => $view.focus());
}
function setTop({ title = '', back = null, actions = [] } = {}) {
  $title.textContent = title;
  D.title = title ? `${title} · FOX-1 Hub` : 'FOX-1 Hub';
  $back.hidden = !back;
  $back.dataset.to = back || '';
  $actions.replaceChildren(...actions.filter(Boolean));
}
const TAB_OF = { home: 'home', notes: 'notes', health: 'health', chats: 'chats', calls: 'chats', memory: 'more', settings: 'more', system: 'more' };
function markNav(name) {
  D.querySelectorAll('[data-nav]').forEach((a) => {
    if (a.dataset.nav === name) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
  D.querySelectorAll('[data-tab]').forEach((a) => {
    if (a.dataset.tab === TAB_OF[name]) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
}
function paintSideFoot() {
  const el = D.getElementById('side-foot');
  const p = S.overview && S.overview.portal;
  if (!p) { el.replaceChildren(); return; }
  const c = parseT(p.closesAt);
  el.replaceChildren(
    h('div', null, h('span', { class: 'dot ok' }), h('b', { text: 'Hub on' })),
    c && h('div', { text: `Closes ${fmtTime(c)} if left idle` }),
    p.address && h('div', { class: 'nowrap', style: 'overflow:hidden;text-overflow:ellipsis', text: p.address.replace(/^https?:\/\//, '') }));
}
function hideBoot() {
  const b = D.getElementById('boot');
  if (!b) return;
  b.classList.add('done');
  setTimeout(() => b.remove(), 300);
}
function bareScreen(ic, title, text, extra) {
  D.body.classList.add('bare');
  $view.replaceChildren(h('div', { class: 'bare-wrap' }, h('div', { class: 'bare-card' },
    h('div', { class: 'empty-ic', style: 'width:64px;height:64px;border-radius:20px;margin-bottom:16px' }, icon(ic, 'ic-lg')),
    h('h1', { text: title }), h('p', { text }), extra)));
  D.title = `${title} · FOX-1 Hub`;
}
function unreachable() {
  hideBoot();
  bareScreen('wifiOff', 'Can’t reach your device',
    'FOX-1 Hub may be off, or this phone or computer may be on a different Wi‑Fi. Turn it on from your device, then try again.',
    [h('button', { class: 'btn btn-primary', type: 'button', onclick: () => location.reload() }, icon('refresh'), 'Try again'),
      whereBox('On your device: swipe down to ', 'Controls', ' → ', 'Hub', '.')]);
}
function portalOff() {
  S.off = true;
  if (S.cur && S.cur.inst.leave) try { S.cur.inst.leave(); } catch (_) { /* ignore */ }
  S.cur = null;
  S.settings = null;
  bareScreen('power', 'FOX-1 Hub is off',
    'You can close this tab. Nothing on your device can be reached from here until FOX-1 Hub is turned on again.',
    whereBox('To open it again: on your device, swipe down to ', 'Controls', ' → ', 'Hub', ' and scan the new code.'));
}
function whereBox(...parts) {
  return h('div', { class: 'where' }, icon('watch'),
    h('div', null, parts.map((p, i) => (i % 2 ? h('b', { text: p }) : p))));
}

/* ================================================================ router */

const PAGES = {};
function parseHash() {
  const raw = location.hash.replace(/^#\/?/, '');
  const path = raw.split('?')[0];
  const parts = path.split('/').filter(Boolean).map((p) => { try { return decodeURIComponent(p); } catch (_) { return p; } });
  return { name: parts[0] || 'home', param: parts[1] || null, hash: '#/' + path };
}
let asking = false;
async function route() {
  if (S.off) return;
  const r = parseHash();
  if (!PAGES[r.name]) { history.replaceState(null, '', '#/home'); return route(); }
  if (r.name !== 'login' && !S.authed) { S.returnTo = r.hash; history.replaceState(null, '', '#/login'); return route(); }
  if (r.name === 'login' && S.authed) { history.replaceState(null, '', S.returnTo || '#/home'); return route(); }
  if (S.authed && S.setupDone === false && r.name !== 'setup') { history.replaceState(null, '', '#/setup'); return route(); }
  if (r.name === 'setup' && S.setupDone === true) { history.replaceState(null, '', '#/home'); return route(); }
  const cur = S.cur;
  if (cur && cur.name !== r.name && cur.inst.canLeave && !S.force) {
    if (asking) return;
    asking = true;
    const ok = await cur.inst.canLeave();
    asking = false;
    if (!ok) { history.replaceState(null, '', S.lastHash); return; }
  }
  S.force = false;
  if (r.hash !== S.lastHash) { S.prevHash = S.lastHash; S.lastHash = r.hash; }
  if (cur && cur.name === r.name && cur.inst.update) {
    cur.inst.update(r);
  } else {
    if (cur && cur.inst.leave) try { cur.inst.leave(); } catch (e) { console.error(e); }
    $view.replaceChildren();
    D.body.classList.remove('bare', 'has-savebar');
    setTop({ title: '' });
    S.cur = { name: r.name, inst: PAGES[r.name]($view, r) || {} };
    window.scrollTo(0, 0);
    if (S.prevHash && r.name !== 'login') $title.focus({ preventScroll: true });
  }
  markNav(r.name);
}

/* ================================================================= login */

PAGES.login = function pageLogin(view) {
  D.body.classList.add('bare');
  setTop({ title: 'Sign in' });
  let timer = null, busy = false;
  const input = h('input', {
    class: 'pin-input', id: 'pin', type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', pattern: '[0-9]*',
    maxlength: '6', enterkeyhint: 'go', autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false',
    'aria-label': 'Six-digit PIN', 'aria-describedby': 'pin-msg pin-where', autofocus: true,
  });
  const boxes = Array.from({ length: 6 }, () => h('span', { class: 'pin-box', 'aria-hidden': 'true' }));
  const wrap = h('div', { class: 'pin-wrap' }, boxes, input);
  const msg = h('p', { class: 'pin-msg', id: 'pin-msg', 'aria-live': 'assertive' });
  const btn = h('button', { class: 'btn btn-primary btn-block', type: 'submit', disabled: true }, 'Sign in');
  const form = h('form', { class: 'pin-form', novalidate: true, onsubmit: (e) => { e.preventDefault(); submit(); } }, wrap, msg, btn);
  const setMsg = (t, info) => { msg.textContent = t || ''; msg.classList.toggle('info', !!info); };
  const paint = () => {
    const v = input.value;
    boxes.forEach((b, i) => { b.textContent = v[i] || ''; b.classList.toggle('is-active', i === Math.min(v.length, 5)); });
    btn.disabled = busy || input.disabled || v.length !== 6;
  };
  input.addEventListener('input', () => {
    const v = input.value.replace(/\D/g, '').slice(0, 6);
    if (v !== input.value) input.value = v;
    if (msg.textContent && !input.disabled && !msg.classList.contains('info')) setMsg('');
    paint();
    if (v.length === 6) submit();
  });
  input.addEventListener('focus', () => { const n = input.value.length; try { input.setSelectionRange(n, n); } catch (_) { /* ignore */ } });
  input.addEventListener('select', paint);

  async function submit() {
    const pin = input.value;
    if (busy || pin.length !== 6 || input.disabled) return;
    busy = true;
    btn.textContent = 'Checking…';
    paint();
    try {
      await api('/api/auth', { method: 'POST', body: { pin }, auth: false });
      S.authed = true;
      const to = S.returnTo && !S.returnTo.startsWith('#/login') ? S.returnTo : '#/home';
      S.returnTo = '#/home';
      refreshOverview();
      await loadSetup();
      replaceTo(to);
    } catch (e) {
      busy = false;
      btn.textContent = 'Sign in';
      input.value = '';
      if (e.status === 429) {
        lock((e.body && e.body.retryIn) || 60);
      } else {
        setMsg(e.status === 0 ? 'Can’t reach your device. Is FOX-1 Hub still on?' : 'That PIN didn’t match. Check your device and try again.');
        wrap.classList.remove('shake');
        void wrap.offsetWidth;
        wrap.classList.add('shake');
        try { if (navigator.vibrate) navigator.vibrate(80); } catch (_) { /* ignore */ }
        input.focus();
      }
      paint();
    }
  }
  function lock(sec) {
    let left = Math.max(1, Math.ceil(sec));
    input.disabled = true;
    wrap.classList.add('is-locked');
    setMsg('Too many wrong tries. Wait a moment before trying again.');
    const tick = () => {
      if (left <= 0) {
        clearInterval(timer);
        timer = null;
        input.disabled = false;
        wrap.classList.remove('is-locked');
        btn.textContent = 'Sign in';
        setMsg('You can try again now.', true);
        paint();
        input.focus();
        return;
      }
      btn.textContent = `Try again in ${Math.floor(left / 60)}:${pad(left % 60)}`;
      left -= 1;
      paint();
    };
    clearInterval(timer);
    tick();
    timer = setInterval(tick, 1000);
  }

  view.append(h('div', { class: 'bare-wrap' }, h('div', { class: 'bare-card' },
    h('img', { class: 'bare-logo', src: '/icon.svg', alt: '' }),
    h('h1', { text: 'Sign in to your device' }),
    h('p', { text: 'Enter the 6-digit PIN shown on your FOX-1 device.' }),
    form,
    h('div', { class: 'where', id: 'pin-where' }, icon('watch'),
      h('div', null, 'On your device: swipe down to ', h('b', { text: 'Controls' }), ' → ', h('b', { text: 'Hub' }),
        '. The PIN is new each time FOX-1 Hub is turned on.')))));
  paint();
  if (S.loginNote) { setMsg(S.loginNote, true); S.loginNote = null; }
  if (S.lockFor) { lock(S.lockFor); S.lockFor = 0; }
  wrap.addEventListener('click', () => input.focus());
  requestAnimationFrame(() => { if (!input.disabled) input.focus(); });
  return { leave() { clearInterval(timer); D.body.classList.remove('bare'); } };
};

/* =========================================================== permissions */

// What FOX-1 may do on the device — the same list setup walks through, here
// for any time after. Answers happen on the device, so it keeps checking while
// it is on the page.
function permissionsCard() {
  const list = h('div', { class: 'setup-perms' }, skel('rows'));
  const note = h('p', { class: 'hint', style: 'margin-top:12px' });
  const card = h('section', { class: 'card set-card', id: 'permissions' }, cardHead('Permissions', 'shield'),
    h('p', { class: 'card-sub', text: 'What FOX-1 may do on your device. Tap Allow, then answer on the device. Only the microphone is required.' }),
    list, note);
  let st = null;
  const paint = () => {
    if (!st) return;
    list.replaceChildren(...st.permissions.map((p) => h('div', { class: 'setup-perm' },
      h('div', { class: 'setup-perm-t' },
        h('b', null, p.label, p.required ? h('span', { class: 'badge b-accent', style: 'margin-left:8px' }, 'Required') : null),
        h('span', { text: p.id === 'accessibility' && p.granted && st.keepsAccessibility ? p.why + ' Kept on automatically.' : p.why })),
      p.granted
        ? h('span', { class: 'badge b-ok' }, icon('check'), 'On')
        : h('button', { class: 'btn btn-sm', type: 'button', onclick: async () => {
          try {
            const r = await api('/api/setup/permission', { method: 'POST', body: { id: p.id } });
            toast(r.askedBy === 'prompt' ? 'Tap Allow on your device' : 'Switch FOX-1 on in the screen that opened on your device, then press Back');
          } catch (e) { toast(e.message, 'error'); }
        } }, 'Allow'))));
    note.textContent = st.keepsAccessibility ? ''
      : 'Android 8 switches Accessibility off whenever FOX-1 is updated or force-stopped (a battery saver’s “close all apps”, say). To have FOX-1 switch it back on by itself, run this once from a computer with ADB: adb shell pm grant ai.fox1 android.permission.WRITE_SECURE_SETTINGS';
    note.hidden = !note.textContent;
  };
  const load = async (poll) => {
    try { st = await api('/api/setup', { poll }); paint(); } catch (e) { if (!poll && e.status !== 401) list.replaceChildren(errorState(e, () => load(false))); }
  };
  load(false);
  const timer = setInterval(() => { if (!card.isConnected) { clearInterval(timer); return; } if (!D.hidden) load(true); }, 3000);
  return card;
}

/* ================================================================ backup */

// Backup & restore. One zip with notes and recordings, health, chats, memory,
// call history and settings; ClawPin writes the same format, which is how a
// wearer moves to FOX-1. `download: false` — only restore (setup's welcome).
function backupCard({ download = true } = {}) {
  let keys = false;
  const link = h('a', { class: 'btn btn-primary', href: '/api/backup', download: '' }, icon('download'), 'Download a backup');
  const keySw = h('button', { class: 'switch', type: 'button', role: 'switch', 'aria-checked': 'false', 'aria-labelledby': 'bk-keys-l' });
  keySw.addEventListener('click', () => {
    keys = !keys;
    keySw.setAttribute('aria-checked', String(keys));
    link.href = keys ? '/api/backup?keys=1' : '/api/backup';
  });
  const file = h('input', { type: 'file', accept: '.zip,application/zip', hidden: true });
  const restoreBtn = h('button', { class: 'btn', type: 'button', onclick: () => file.click() }, icon('upload'), 'Restore from a backup');
  file.addEventListener('change', async () => {
    const f = file.files && file.files[0];
    file.value = '';
    if (!f) return;
    const ok = await confirmDialog({
      title: 'Restore this backup?',
      body: `${f.name} — its notes, health and chats are added to your device, and its memory, call history and settings replace what’s there. FOX-1 restarts afterwards.`,
      ok: 'Restore', danger: false,
    });
    if (!ok) return;
    restoreBtn.disabled = true;
    restoreBtn.replaceChildren(h('span', { class: 'spinner', style: 'width:14px;height:14px;border-width:2px' }), 'Restoring…');
    try {
      const res = await fetch('/api/restore', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/zip' }, body: f });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `The device answered with an error (${res.status}).`);
      const r = data.restored || {};
      S.off = true;
      bareScreen('check', 'Restored',
        `${fmtN(r.files || 0)} files and ${fmtN(r.settings || 0)} settings came across${r.from && r.from !== 'fox1' ? ' from ' + (r.from === 'clawpin' ? 'ClawPin' : r.from) : ''}. Your device is restarting.`,
        whereBox(r.includesKeys ? 'When it’s back, open FOX-1 Hub again from ' : 'The backup had no API key, so the device will ask for setup: scan its ', r.includesKeys ? 'Controls → Hub' : 'new code', r.includesKeys ? ' on your device.' : ' to add it.'));
    } catch (e) {
      restoreBtn.disabled = false;
      restoreBtn.replaceChildren(icon('upload'), 'Restore from a backup');
      toast(e.message === 'Failed to fetch' ? 'Can’t reach your device.' : e.message, 'error');
    }
  });
  if (!download) return h('div', { class: 'setup-restore' }, restoreBtn, file);
  return h('section', { class: 'card' }, cardHead('Backup & restore', 'shield'),
    h('p', { class: 'hint', style: 'margin:-4px 0 12px', text: 'Everything that can’t be recreated — voice notes and their recordings, health history, chats, memory and call history — plus your settings, in one file on this phone.' }),
    h('div', { class: 'row-flex', style: 'justify-content:space-between;gap:12px;margin-bottom:12px' },
      h('span', { id: 'bk-keys-l', style: 'font-size:14px' }, 'Include API keys and tokens', h('small', { class: 'hint', style: 'display:block', text: 'Needed to skip setup after restoring. Keep the file private.' })), keySw),
    h('div', { class: 'btn-row' }, link, restoreBtn, file));
}

/* ================================================================= setup */

// First-time setup. Until it is done the device shows only this Hub's QR code
// and PIN, and every signed-in visit lands here.
async function loadSetup() {
  try {
    const s = await api('/api/setup');
    S.setupDone = !!s.done;
    learnName(s.name);
    return s;
  } catch (_) {
    return null;
  }
}

PAGES.setup = function pageSetup(view) {
  D.body.classList.add('bare');
  setTop({ title: 'Set up' });
  const STEPS = ['Welcome', 'Your AI', 'About you', 'Name & look', 'Permissions', 'Smart ring', 'Done'];
  let step = 0, st = null, opts = null, poll = null, busy = false;
  const draft = {};
  const wrap = h('div', { class: 'setup' });
  view.append(h('div', { class: 'bare-wrap' }, wrap));

  const save = (body) => api('/api/settings', { method: 'POST', body });
  const bar = () => h('div', { class: 'setup-bar', 'aria-hidden': 'true' },
    STEPS.map((_, i) => h('span', { class: i <= step ? 'on' : '' })));
  const head = (title, sub) => [
    h('p', { class: 'setup-step', text: `Step ${step + 1} of ${STEPS.length}` }),
    h('h1', { text: title }), sub && h('p', { class: 'setup-sub', text: sub })];
  const nav = (next, { label = 'Continue', disabled = false, skip = null, quiet = false } = {}) => h('div', { class: 'setup-nav' },
    step > 0 ? h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => go(step - 1) }, 'Back') : h('span'),
    h('div', { class: 'row-flex', style: 'gap:8px' },
      skip && h('button', { class: 'btn btn-quiet', type: 'button', onclick: skip }, 'Skip'),
      h('button', { class: 'btn ' + (quiet ? 'btn-ghost' : 'btn-primary'), type: 'button', disabled, onclick: next }, label)));
  const fieldOf = (label, ctl, hint, id) => h('div', { class: 'field' },
    h('label', { class: 'label', for: id, text: label }), ctl, hint && h('p', { class: 'hint', text: hint }));

  async function go(i) {
    clearInterval(poll);
    poll = null;
    step = Math.max(0, Math.min(STEPS.length - 1, i));
    await render();
    window.scrollTo(0, 0);
  }

  async function render() {
    if (!st) st = await loadSetup();
    if (!st) { wrap.replaceChildren(errorState(new ApiError(0, 'Can’t reach your device.'), render)); return; }
    const body = [bar()];
    if (step === 0) {
      body.push(h('img', { class: 'bare-logo', src: '/icon.svg', alt: '' }),
        ...head('Welcome to FOX-1', 'Let’s set up your device. It takes about five minutes, and you can change everything later in Settings.'),
        h('ol', { class: 'setup-list' },
          h('li', null, 'Connect FOX-1 to its AI'), h('li', null, 'Tell it about you'), h('li', null, 'Name it and pick its character'),
          h('li', null, 'Allow what it needs on your device')),
        nav(() => go(1), { label: 'Start' }),
        h('div', { class: 'setup-or' }, h('span', { text: 'Setting up again, or moving to a new device? Restore a backup instead.' }), backupCard({ download: false })));
    } else if (step === 1) {
      if (!opts) opts = await api('/api/settings/options').catch(() => ({ models: [], voices: [] }));
      const cur = S.settings && S.settings.base ? S.settings.base : await api('/api/settings').catch(() => ({}));
      const key = h('input', { class: 'input mono', id: 'su-key', type: 'password', autocomplete: 'off', spellcheck: 'false',
        placeholder: st.hasKey ? 'Saved — paste a new key to replace it' : 'Paste your Gemini API key', value: draft.key || '' });
      const model = h('select', { class: 'select', id: 'su-model' }, (opts.models || []).map((m) => h('option', { value: m.value, text: m.label })));
      model.value = draft.model || cur.gemini_model || (opts.models[0] && opts.models[0].value) || '';
      const voice = h('select', { class: 'select', id: 'su-voice' }, (opts.voices || []).map((v) => h('option', { value: v.name, text: `${v.name} · ${v.style}` })));
      voice.value = draft.voice || cur.gemini_voice || 'Kore';
      const next = h('button', { class: 'btn btn-primary', type: 'button' }, 'Continue');
      const paint = () => { next.disabled = busy || (!st.hasKey && !key.value.trim()); };
      key.addEventListener('input', () => { draft.key = key.value; paint(); });
      next.addEventListener('click', async () => {
        busy = true; paint();
        try {
          const b = { gemini_model: model.value, gemini_voice: voice.value };
          if (key.value.trim()) b.gemini_api_key = key.value.trim();
          await save(b);
          draft.model = model.value; draft.voice = voice.value;
          st = null;
          busy = false;
          go(2);
        } catch (e) { busy = false; paint(); toast(e.message, 'error'); }
      });
      body.push(...head('Connect FOX-1 to its AI', 'FOX-1 talks and sees through a live AI model. Today that is Gemini Live, which needs a free API key.'),
        h('div', { class: 'card setup-card' },
          fieldOf('Gemini API key', key, null, 'su-key'),
          h('a', { class: 'card-link', href: 'https://aistudio.google.com/apikey', target: '_blank', rel: 'noopener' }, 'Get a free key from Google AI Studio', icon('external')),
          fieldOf('Model', model, null, 'su-model'),
          fieldOf('Voice', voice, null, 'su-voice')),
        h('div', { class: 'setup-nav' }, h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => go(0) }, 'Back'), next));
      wrap.replaceChildren(...body);
      paint();
      return;
    } else if (step === 2) {
      const ta = h('textarea', { class: 'textarea', id: 'su-profile', rows: '5',
        placeholder: 'Name: Alex. I build hardware, I run on Tuesday mornings, and I like short answers.' });
      ta.value = draft.profile != null ? draft.profile : (st.profile || '');
      ta.addEventListener('input', () => { draft.profile = ta.value; });
      body.push(...head('Tell FOX-1 about you', 'Your name, and anything that helps it help you. It uses this in every conversation, and on calls it takes for you.'),
        h('div', { class: 'card setup-card' }, fieldOf('About you', ta, 'You can change this any time in Settings → About you.', 'su-profile')),
        nav(async () => {
          try { await save({ user_profile: ta.value.trim() }); st = null; go(3); } catch (e) { toast(e.message, 'error'); }
        }));
    } else if (step === 3) {
      const pick = async (m) => {
        try { await save({ mascot: m }); st.mascot = m; render(); } catch (e) { toast(e.message, 'error'); }
      };
      const choice = (m, name, sub) => h('button', { class: 'setup-choice', type: 'button', 'aria-pressed': String(st.mascot === m), onclick: () => pick(m) },
        h('b', { text: name }), h('span', { text: sub }));
      const nameIn = h('input', { class: 'input', id: 'su-name', type: 'text', maxlength: '24', autocomplete: 'off',
        placeholder: 'FOX-1', value: draft.name != null ? draft.name : (st.name || 'FOX-1') });
      nameIn.addEventListener('input', () => { draft.name = nameIn.value; });
      body.push(...head('Name your FOX-1', 'Call it anything you like — it answers to this name, on the device and on calls. Then pick how it looks; look at your device while you choose.'),
        h('div', { class: 'card setup-card' }, fieldOf('Name', nameIn, 'You can change it any time in Settings.', 'su-name')),
        h('div', { class: 'setup-choices' }, choice('fox', 'Fox', 'Warm and curious'), choice('bloub', 'Bloub', 'Soft and simple')),
        h('p', { class: 'hint', style: 'text-align:center', text: 'You can design every colour and movement later in Settings → Mascot.' }),
        nav(async () => {
          const name = nameIn.value.trim() || 'FOX-1';
          try { await save({ assistant_name: name }); learnName(name); st.name = name; go(4); } catch (e) { toast(e.message, 'error'); }
        }));
    } else if (step === 4) {
      const list = h('div', { class: 'card setup-card setup-perms' });
      const paintPerms = () => {
        list.replaceChildren(...st.permissions.map((p) => h('div', { class: 'setup-perm' },
          h('div', { class: 'setup-perm-t' },
            h('b', null, p.label, p.required ? h('span', { class: 'badge b-accent', style: 'margin-left:8px' }, 'Required') : null),
            h('span', { text: p.why })),
          p.granted
            ? h('span', { class: 'badge b-ok' }, icon('check'), 'On')
            : h('button', { class: 'btn btn-sm', type: 'button', onclick: async () => {
              try {
                const r = await api('/api/setup/permission', { method: 'POST', body: { id: p.id } });
                toast(r.askedBy === 'prompt' ? 'Tap Allow on your device' : 'Switch FOX-1 on in the screen that opened on your device, then press Back');
              } catch (e) { toast(e.message, 'error'); }
            } }, 'Allow'))));
        next.disabled = !st.permissions.find((p) => p.id === 'microphone').granted;
      };
      const next = h('button', { class: 'btn btn-primary', type: 'button', onclick: () => go(5) }, 'Continue');
      body.push(...head('Allow what FOX-1 needs', 'Android asks for each of these on your device itself. Tap Allow, then answer on the device. Only the microphone is required; each of the others turns on one feature.'),
        list,
        h('div', { class: 'setup-nav' }, h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => go(3) }, 'Back'), next));
      wrap.replaceChildren(...body);
      paintPerms();
      // Answers happen on the device, so keep checking.
      poll = setInterval(async () => {
        try { st = await api('/api/setup', { poll: true }); paintPerms(); } catch (_) { /* keep trying */ }
      }, 2000);
      return;
    } else if (step === 5) {
      const out = h('p', { class: 'hint', 'aria-live': 'polite', style: 'text-align:center' });
      const pair = h('button', { class: 'btn btn-primary', type: 'button' }, icon('ring'), st.ringPaired ? 'Ring paired' : 'Pair my ring');
      pair.disabled = st.ringPaired;
      pair.addEventListener('click', async () => {
        pair.disabled = true;
        out.textContent = 'Looking for your ring… keep it close to the device. This can take half a minute.';
        try {
          const r = await api('/api/setup/ring', { method: 'POST' });
          out.textContent = r.result || '';
          st.ringPaired = r.paired;
          pair.replaceChildren(icon('ring'), r.paired ? 'Ring paired' : 'Try again');
          pair.disabled = r.paired;
        } catch (e) { out.textContent = e.message; pair.disabled = false; }
      });
      body.push(...head('Smart ring', 'Optional. A ring lets you hold to talk, record voice notes and track your health. Charge it and keep it near the device.'),
        h('div', { class: 'card setup-card', style: 'align-items:center' }, pair, out),
        nav(() => go(6), { label: st.ringPaired ? 'Continue' : 'Skip for now', quiet: !st.ringPaired }));
    } else {
      const finish = h('button', { class: 'btn btn-primary btn-block', type: 'button', disabled: !st.canFinish }, 'Finish setup');
      finish.addEventListener('click', async () => {
        finish.disabled = true;
        try {
          await api('/api/setup/done', { method: 'POST' });
          S.setupDone = true;
          toast('FOX-1 is ready');
          replaceTo('#/home');
        } catch (e) { finish.disabled = false; toast(e.message, 'error'); }
      });
      body.push(h('img', { class: 'bare-logo', src: '/icon.svg', alt: '' }),
        ...head('You’re all set', st.canFinish
          ? 'Finish, and your device moves on to its watch face. Hold the ring or swipe up on the device to talk to FOX-1.'
          : 'FOX-1 still needs its API key and the microphone before it can talk. Go back and add them.'),
        h('div', { class: 'setup-nav', style: 'flex-direction:column;align-items:stretch;gap:12px' }, finish,
          h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => go(step - 1) }, 'Back')));
    }
    wrap.replaceChildren(...body);
  }

  render();
  return { leave() { clearInterval(poll); D.body.classList.remove('bare'); } };
};

/* ================================================================== home */

PAGES.home = function pageHome(view) {
  setTop({ title: 'Home' });
  const life = { alive: true };
  const root = h('div', { class: 'page' });
  view.append(root);
  let last = null;

  async function load(first, poll = false) {
    if (first) {
      if (S.overview) root.replaceChildren(...renderHome(S.overview, null));
      else root.replaceChildren(skel('home'));
    }
    try {
      const o = await api('/api/overview', { poll });
      if (!life.alive) return;
      S.overview = o;
      paintSideFoot();
      last = new Date();
      root.replaceChildren(...renderHome(o, last));
    } catch (e) {
      if (!life.alive || e.status === 401) return;
      if (!last && !S.overview) { root.replaceChildren(errorState(e, () => load(true))); return; }
      const u = root.querySelector('.updated');
      if (u) {
        u.classList.add('stale');
        u.replaceChildren(h('span', { class: 'dot warn' }),
          h('button', { class: 'btn-quiet btn btn-sm', type: 'button', style: 'min-height:32px;padding:0 8px;color:inherit', onclick: () => load(false) },
            'Couldn’t refresh · Retry'));
      }
    }
  }
  load(true);
  const timer = setInterval(() => { if (D.visibilityState === 'visible') load(false, true); }, 30000);
  const onVis = () => { if (D.visibilityState === 'visible' && (!last || Date.now() - last > 10000)) load(false, true); };
  D.addEventListener('visibilitychange', onVis);
  return { leave() { life.alive = false; clearInterval(timer); D.removeEventListener('visibilitychange', onVis); } };
};

function renderHome(o, at) {
  const now = new Date();
  const hr = now.getHours();
  const greet = hr < 5 ? 'Good night' : hr < 12 ? 'Good morning' : hr < 18 ? 'Good afternoon' : 'Good evening';
  const hero = h('div', { class: 'hero' },
    h('div', null, h('h2', { class: 'hero-title', text: greet }), h('p', { class: 'hero-sub', text: longDate(now) })),
    h('span', { class: 'updated', 'aria-live': 'polite' }, h('span', { class: 'dot ' + (at ? 'ok' : '') }),
      h('span', { text: at ? `Updated ${fmtTime(at)}` : 'Updating…' })));
  return [hero, statusCard(o),
    h('div', { class: 'home-grid' }, todayCard(o), attentionCard(o), notesCard(o), assistantCard(o))];
}

function statusCard(o) {
  const w = o.watch || {}, r = o.ring || {}, p = o.portal || {};
  const col = (ic, label, value, sub, lead, tag) => h('div', { class: 'st-col' },
    h('div', { class: 'st-label' }, icon(ic), label, tag),
    h('div', { class: 'st-value' }, lead, h('span', { text: value })),
    h('div', { class: 'st-sub', text: sub }));
  const wSub = w.charging ? 'Charging' : w.battery != null && w.battery <= 20 ? 'Low battery' : 'Battery';
  let rVal, rSub, rLead = null;
  if (!r.paired || r.link === 'unpaired') {
    rVal = 'Not paired';
    rSub = 'Pair one on the device in Settings';
  } else {
    rVal = { ready: 'Connected', connecting: 'Connecting', idle: 'Not connected' }[r.link] || cap(r.link || 'Unknown');
    rLead = h('span', { class: 'dot ' + (r.link === 'ready' ? 'ok' : r.link === 'connecting' ? 'warn' : '') });
    const ls = parseT(r.lastSync);
    rSub = [r.battery != null ? `${r.battery}%` : null, ls ? `synced ${rel(ls)}` : 'not synced yet'].filter(Boolean).join(' · ');
  }
  const closes = parseT(p.closesAt);
  return h('section', { class: 'card status-card', 'aria-label': 'Status' },
    col('battery', 'Device', w.battery != null ? `${w.battery}%` : '–', wSub, w.charging ? icon('bolt') : null),
    col('ring', 'Ring', rVal, rSub, null, rLead),
    col('wifi', closes ? 'Closes' : 'Hub', closes ? fmtTime(closes) : 'On', closes ? 'if the Hub sits idle' : 'Open'));
}

function metric(cls, ic, label, value, sub, extra, tag) {
  return h('div', { class: 'metric ' + cls },
    h('div', { class: 'metric-label' }, icon(ic), label, tag && h('span', { class: 'tag-est', text: tag })),
    h('div', { class: 'metric-value' }, value),
    sub && h('div', { class: 'metric-sub', text: sub }),
    extra);
}
function stageBar(n, lg) {
  const tot = (n.deep || 0) + (n.light || 0) + (n.rem || 0) + (n.awake || 0);
  if (!tot) return null;
  const seg = (cls, v) => (v > 0 ? h('span', { class: cls, style: `flex:${v}` }) : null);
  return h('div', {
    class: 'stagebar' + (lg ? ' lg' : ''), role: 'img',
    'aria-label': `Deep ${hm(n.deep)}, light ${hm(n.light)}, REM ${hm(n.rem)}, awake ${hm(n.awake)}`,
  }, seg('s-deep', n.deep), seg('s-light', n.light), seg('s-rem', n.rem), seg('s-awake', n.awake));
}
function stressMetric(v, provisional, cls = 'metric m-stress') {
  const b = band(v);
  return h('div', { class: cls },
    h('div', { class: 'metric-label' }, icon('gauge'), 'Stress', h('span', { class: 'tag-est', text: 'Estimate' })),
    h('div', { class: 'metric-value' }, v != null ? [String(v), h('small', null, '/ 100')] : '–'),
    h('div', { class: 'metric-sub' }, b ? h('span', { class: 'band-' + b[0], style: 'font-weight:600', text: b[1] }) : 'No estimate yet'),
    provisional && h('div', { class: 'metric-note', text: 'Still learning your baseline — it needs five days of data.' }));
}
function todayCard(o) {
  const t = o.today, r = o.ring || {};
  const head = cardHead('Today', null, linkTo('#/health', 'Health'));
  if (!t) {
    return h('section', { class: 'card span-2' }, head, emptyState('pulse', 'No health data yet today',
      r.paired ? 'The ring syncs with the device every 30 minutes while it’s connected.' : 'Pair a smart ring on the device to see steps, heart rate and sleep here.'));
  }
  const steps = r.liveSteps != null && r.liveSteps > (t.steps || 0) ? r.liveSteps : t.steps;
  const actSub = [t.distance != null ? `${nf1.format(t.distance / 1000)} km` : null, t.calories != null ? `${fmtN(t.calories)} kcal` : null].filter(Boolean).join(' · ');
  const n = t.night;
  const ls = parseT(r.lastSync);
  return h('section', { class: 'card span-2 flex', 'aria-label': 'Today' }, head,
    h('div', { class: 'metrics' },
      metric('m-steps', 'steps', 'Steps', steps != null ? fmtN(steps) : '–', actSub || 'So far today'),
      metric('m-heart', 'heart', 'Heart rate', t.hr ? [String(t.hr.avg), h('small', null, 'bpm')] : '–',
        t.hr ? `Range ${t.hr.min}–${t.hr.max}` : 'No readings yet'),
      metric('m-sleep', 'moon', 'Last night', n ? hmBig(n.asleep) : '–',
        n ? `Score ${n.score} · ${cap(n.label)}` : 'No sleep recorded', n && stageBar(n)),
      stressMetric(t.stress, t.stressProvisional)),
    r.paired && h('p', { class: 'card-foot' }, icon('ring'), [r.name, ls ? `synced ${rel(ls)}` : null, r.lastSyncSummary].filter(Boolean).join(' · ')));
}
function attentionCard(o) {
  const items = [];
  const claims = (o.memory && o.memory.claims) || 0;
  if (claims) {
    items.push(lrow({ href: '#/memory', ic: 'shield', tone: 'warn', title: `${plural(claims, 'claim', 'claims')} to review`, sub: 'What callers said, not yet verified', wrap: true }));
  }
  const waiting = (o.notes && o.notes.waiting) || 0;
  if (waiting) {
    items.push(lrow({ href: '#/notes', onclick: () => { S.notes.filter = 'waiting'; }, ic: 'clock', tone: 'accent',
      title: `${plural(waiting, 'note', 'notes')} waiting`, sub: 'Queued for transcription' }));
  }
  for (const n of (o.notes && o.notes.recent) || []) {
    if (n.status === 'failed') {
      items.push(lrow({ href: '#/notes/' + enc(n.id), ic: 'alert', tone: 'danger', title: 'A note wasn’t transcribed', sub: n.error || fmtDayRel(parseT(n.recordedAt)), wrap: true }));
    }
  }
  const r = o.ring || {};
  if (r.paired && r.link === 'idle') {
    const ls = parseT(r.lastSync);
    items.push(lrow({ href: '#/health', ic: 'ring', tone: 'warn', title: 'Ring isn’t connected', sub: ls ? `Last synced ${rel(ls)}` : 'It reconnects on its own when in range' }));
  }
  if (r.paired && r.battery != null && r.battery <= 15) items.push(lrow({ href: '#/health', ic: 'battery', tone: 'warn', title: 'Ring battery low', sub: `${r.battery}% left` }));
  const w = o.watch || {};
  if (w.battery != null && w.battery <= 15 && !w.charging) items.push(lrow({ href: '#/system', ic: 'battery', tone: 'danger', title: 'Device battery low', sub: `${w.battery}% left` }));
  return h('section', { class: 'card' }, cardHead('Needs attention'),
    items.length ? h('div', { class: 'list' }, items)
      : h('div', { class: 'all-clear' }, h('span', { class: 'lrow-ic' }, icon('check')), 'Nothing needs you right now.'));
}
function noteTitle(n) {
  return n.title || (n.status === 'pending' ? 'New recording' : n.status === 'failed' ? 'Untranscribed recording' : 'Voice note');
}
function notesCard(o) {
  const recent = (o.notes && o.notes.recent) || [];
  const head = cardHead('Recent notes', null, linkTo('#/notes', 'All notes'));
  if (!recent.length) {
    return h('section', { class: 'card span-2' }, head, emptyState('mic', 'No voice notes yet',
      'Quadruple-tap your ring to start recording, and again to stop. The note comes over to the device and is transcribed on its own.'));
  }
  return h('section', { class: 'card span-2' }, head, h('div', { class: 'list' }, recent.slice(0, 3).map((n) => {
    const t = parseT(n.recordedAt);
    const items = n.actionItems || [];
    return h('a', { class: 'lrow', href: '#/notes/' + enc(n.id), style: 'align-items:flex-start' },
      h('span', { class: 'lrow-ic accent' }, icon('mic')),
      h('span', { class: 'lrow-main' },
        h('span', { class: 'lrow-title clamp2', text: noteTitle(n) }),
        h('span', { class: 'lrow-sub', text: [rel(t), dur(n.duration), n.language].filter(Boolean).join(' · ') }),
        items.length ? h('ul', { class: 'note-actions' }, items.slice(0, 3).map((a) => h('li', null, icon('checkSq'), h('span', { text: a })))) : null),
      h('span', { class: 'lrow-end', style: 'align-self:center' }, statusBadge(n), icon('chevR')));
  })));
}
function assistantCard(o) {
  const c = o.conversations || {}, m = o.memory || {}, a = o.assistant || {}, ca = o.callAgent || {};
  const last = parseT(c.last);
  const kv = (k, v, sub) => h('div', null, h('dt', { text: k }), h('dd', null, v, sub && h('small', { text: ' ' + sub })));
  return h('section', { class: 'card' }, cardHead(aiName(), 'sparkle', linkTo('#/chats', 'Chats')),
    h('dl', { class: 'kv' },
      kv('Today', fmtN(c.today || 0), c.today === 1 ? 'chat' : 'chats'),
      kv('Last talked', last ? rel(last) : '—'),
      kv('Remembers', fmtN(m.facts || 0), 'facts'),
      kv('Call agent', ca.onDuty ? 'On duty' : 'Off')),
    a.model && h('p', { class: 'hint', style: 'margin-top:12px', text: `${modelName(a.model)}${a.voice ? ' · voice ' + a.voice : ''}` }));
}
function statusBadge(n) {
  if (n.status === 'pending') return h('span', { class: 'badge b-accent' }, h('span', { class: 'spinner', style: 'width:10px;height:10px;border-width:1.5px' }), 'Transcribing');
  if (n.status === 'failed') return h('span', { class: 'badge b-danger' }, icon('alert'), 'Failed');
  if (n.silent) return h('span', { class: 'badge' }, icon('micOff'), 'No speech');
  return null;
}

/* ================================================================= notes */

PAGES.notes = function pageNotes(view, route0) {
  const st = S.notes;
  const life = { alive: true };
  let list = null, silent = 0, seq = 0, detailId = null, pollT = null, listPollT = null;

  const search = searchBox(st.q, 'Search notes', debounce((v) => { st.q = v; load(false); }, 300));
  const chipDefs = [['all', 'All'], ['actions', 'Action items'], ['waiting', 'Waiting / failed']];
  const chips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Filter notes' }, chipDefs.map(([k, label]) =>
    h('button', { class: 'chip', type: 'button', 'data-k': k, onclick: () => { st.filter = k; renderList(); } }, label, h('span', { class: 'count' }))));
  const banner = h('div');
  const listEl = h('div', { class: 'stack' });
  const detail = h('div', { class: 'pane-detail' });
  const split = h('div', { class: 'split' }, h('div', { class: 'pane-list' }, search.el, chips, banner, listEl), detail);
  const openDetail = splitNav(split);
  view.append(split);

  const FILTERS = {
    all: () => true,
    actions: (n) => (n.actionItems || []).length > 0,
    waiting: (n) => n.status !== 'done',
  };

  async function load(showSkel, poll = false) {
    const my = ++seq;
    clearTimeout(listPollT);
    if (showSkel || !list) listEl.replaceChildren(skel('list'));
    else { const nl = listEl.querySelectorAll('.note-list'); nl.forEach((x) => x.classList.add('is-busy')); }
    const qs = new URLSearchParams();
    if (st.q.trim()) qs.set('q', st.q.trim());
    if (st.all) qs.set('all', '1');
    try {
      const d = await api('/api/notes' + (qs.toString() ? '?' + qs : ''), { poll });
      if (!life.alive || my !== seq) return;
      list = d.notes || [];
      silent = st.all ? list.filter((n) => n.silent).length : d.silent || 0;
      renderList();
      if (list.some((n) => n.status === 'pending')) listPollT = setTimeout(() => load(false, true), 15000);
    } catch (e) {
      if (!life.alive || my !== seq || e.status === 401) return;
      banner.replaceChildren();
      listEl.replaceChildren(errorState(e, () => load(true)));
    }
  }

  function renderList() {
    chips.querySelectorAll('.chip').forEach((c) => {
      const k = c.dataset.k;
      c.setAttribute('aria-pressed', String(st.filter === k));
      c.querySelector('.count').textContent = list ? fmtN(list.filter(FILTERS[k]).length) : '';
    });
    paintBanner();
    if (!list) return;
    const items = list.filter(FILTERS[st.filter]);
    if (!items.length) { listEl.replaceChildren(emptyNotes()); return; }
    const groups = new Map();
    for (const n of items) {
      const t = parseT(n.recordedAt) || new Date(0);
      const k = dkey(t);
      if (!groups.has(k)) groups.set(k, { d: t, notes: [] });
      groups.get(k).notes.push(n);
    }
    listEl.replaceChildren(...[...groups.values()].map((g) => h('section', { class: 'stack', style: 'gap:8px' },
      h('h2', { class: 'day-label' }, h('span', { text: fmtDayRel(g.d) }), h('span', { text: plural(g.notes.length, 'note', 'notes') })),
      h('div', { class: 'note-list' }, g.notes.map(noteCard)))));
  }
  function emptyNotes() {
    if (st.q.trim()) {
      return emptyState('search', `No notes match “${st.q.trim()}”`, 'Search looks at titles, summaries, transcripts, people and action items. Every word has to match.',
        h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => { search.input.value = ''; search.input.dispatchEvent(new Event('input')); } }, 'Clear search'));
    }
    if (st.filter === 'actions') return emptyState('checkSq', 'No action items', 'When a note asks you to do something, it shows up here.');
    if (st.filter === 'waiting') return emptyState('check', 'Nothing waiting', 'Every note has been transcribed.');
    return emptyState('mic', 'No voice notes yet',
      'Quadruple-tap your ring to start recording, and again to stop. It comes over to the device and is transcribed on its own — in English, Twi, Akan and more.');
  }
  function paintBanner() {
    if (!silent) { banner.replaceChildren(); return; }
    const txt = st.all
      ? `Showing ${plural(silent, 'recording', 'recordings')} with no speech`
      : `${plural(silent, 'recording', 'recordings')} with no speech ${silent === 1 ? 'is' : 'are'} hidden`;
    banner.replaceChildren(h('div', { class: 'banner' }, icon('micOff'), h('span', { class: 'banner-text', text: txt }),
      h('span', { class: 'banner-actions' },
        h('button', { class: 'btn btn-quiet', type: 'button', onclick: () => { st.all = !st.all; load(false); } }, st.all ? 'Hide them' : 'Show'),
        h('button', { class: 'btn btn-quiet danger', type: 'button', onclick: deleteSilent }, 'Delete them'))));
  }
  async function deleteSilent() {
    const ok = await confirmDialog({
      title: `Delete ${plural(silent, 'recording', 'recordings')} with no speech?`,
      body: 'They were transcribed and nothing was said in them. They’re removed from the device for good.',
      ok: 'Delete',
    });
    if (!ok) return;
    try {
      const d = await api('/api/notes/delete-silent', { method: 'POST', body: {} });
      toast(`Deleted ${plural(d.deleted != null ? d.deleted : silent, 'recording', 'recordings')}`);
      st.all = false;
      if (detailId && list && (list.find((n) => n.id === detailId) || {}).silent) replaceTo('#/notes');
      load(false);
    } catch (e) { if (e.status !== 401) toast(`Couldn’t delete: ${e.message}`, 'error'); }
  }
  function noteCard(n) {
    const t = parseT(n.recordedAt);
    const items = n.actionItems || [];
    return h('a', {
      class: 'note-card' + (n.silent ? ' is-silent' : ''), href: '#/notes/' + enc(n.id), 'data-id': n.id,
      'aria-current': n.id === detailId ? 'true' : null,
    },
    h('span', { class: 'note-top' }, h('span', { class: 'note-title', text: noteTitle(n) }), statusBadge(n)),
    h('span', { class: 'note-meta' }, h('span', { text: fmtTime(t) }), h('span', { class: 'sep', text: '·' }), h('span', { text: dur(n.duration) }),
      n.language && h('span', { class: 'lang' }, icon('globe'), n.language)),
    n.summary && h('span', { class: 'note-sum', text: n.summary }),
    items.length ? h('span', { class: 'note-foot' }, icon('checkSq'), plural(items.length, 'action item', 'action items')) : null);
  }
  function markActive() {
    listEl.querySelectorAll('.note-card').forEach((c) => {
      if (c.dataset.id === detailId) c.setAttribute('aria-current', 'true'); else c.removeAttribute('aria-current');
    });
  }

  async function showDetail(id, quiet) {
    clearTimeout(pollT);
    detailId = id;
    openDetail(!!id);
    markActive();
    if (!id) {
      setTop({ title: 'Notes' });
      detail.replaceChildren(h('div', { class: 'pane-empty' }, emptyState('mic', 'Choose a note', 'Its summary, action items, transcript and recording appear here.')));
      return;
    }
    setTop({ title: 'Voice note', back: '#/notes' });
    if (!quiet) { detail.replaceChildren(h('div', { class: 'detail' }, skel('detail'))); detail.scrollTop = 0; }
    try {
      const n = await api('/api/notes/' + enc(id), { poll: !!quiet });
      if (!life.alive || detailId !== id) return;
      const audio = detail.querySelector('audio');
      const keepAudio = quiet && audio && !audio.paused;
      if (!keepAudio) detail.replaceChildren(noteDetail(n));
      if (n.status === 'pending') pollT = setTimeout(() => showDetail(id, true), 8000);
      else if (quiet) load(false, true);
    } catch (e) {
      if (!life.alive || detailId !== id || e.status === 401 || quiet) return;
      detail.replaceChildren(h('div', { class: 'detail' }, e.status === 404
        ? emptyState('mic', 'This note is gone', 'It may have been deleted.', h('a', { class: 'btn btn-ghost', href: '#/notes' }, 'Back to notes'))
        : errorState(e, () => showDetail(id))));
    }
  }
  function noteDetail(n) {
    const t = parseT(n.recordedAt);
    const people = n.people || [], dates = n.dates || [], items = n.actionItems || [];
    const sec = (title, body, right) => h('section', { class: 'dsec' }, h('div', { class: 'dsec-head' }, h('h3', { class: 'dsec-title', text: title }), right), body);
    const parts = [h('div', { class: 'detail-head' },
      h('div', { class: 'detail-top' }, h('h2', { class: 'detail-title', text: noteTitle(n) }),
        h('a', { class: 'icon-btn desk-only', href: '#/notes', 'aria-label': 'Close note' }, icon('x'))),
      h('div', { class: 'detail-meta' }, h('span', { text: `${fmtDayRel(t)}, ${fmtTime(t)}` }), h('span', { class: 'faint', text: '·' }),
        h('span', { text: dur(n.duration) }), n.language && h('span', { class: 'lang' }, icon('globe'), n.language), statusBadge(n)))];

    if (n.status === 'pending') {
      parts.push(callout('accent', spinner(), 'Transcribing…',
        'This note is in the queue. Its summary and transcript appear here when they’re ready.' + (n.error ? ` Last try: ${n.error}` : '')));
    }
    if (n.status === 'failed') {
      parts.push(callout('danger', 'alert', 'Couldn’t transcribe this note', n.error || 'The last try failed.',
        h('button', { class: 'btn btn-sm btn-ghost', type: 'button', onclick: () => retry(n) }, icon('refresh'), 'Try again')));
    }
    parts.push(h('div', { class: 'audio-card' },
      h('audio', { controls: true, preload: 'none', src: `/api/notes/${enc(n.id)}/audio`, 'aria-label': 'Recording' }),
      h('span', { class: 'hint', text: 'The audio is rebuilt from the ring’s recording when you press play — it can take a second to start.' })));
    if (n.summary) parts.push(sec('Summary', h('p', { class: 'lead', text: n.summary })));
    if (items.length) {
      parts.push(sec('Action items', h('ul', { class: 'ai-list' }, items.map((a) => h('li', null, icon('checkSq'), h('span', { text: a }))))));
    }
    if (people.length || dates.length) {
      parts.push(sec('People and dates', h('div', { class: 'pill-list' },
        people.map((p) => h('span', { class: 'pill' }, icon('user'), p)),
        dates.map((d) => h('span', { class: 'pill' }, icon('calendar'), d)))));
    }
    if (n.status === 'done') {
      if (n.silent || !n.transcript) {
        parts.push(sec('Transcript', h('p', { class: 'muted', text: 'No speech was detected in this recording.' })));
      } else {
        const copyBtn = h('button', { class: 'btn btn-quiet btn-sm', type: 'button', onclick: async () => {
          const ok = await copyText(n.transcript);
          toast(ok ? 'Transcript copied' : 'Couldn’t copy — select the text instead', ok ? 'ok' : 'error');
        } }, icon('copy'), 'Copy');
        parts.push(h('section', { class: 'dsec' },
          h('div', { class: 'dsec-head' }, h('h3', { class: 'dsec-title' }, 'Transcript', n.language && h('span', { class: 'lang', text: n.language })), copyBtn),
          h('div', { class: 'transcript', lang: /twi|akan/i.test(n.language || '') && !/english/i.test(n.language || '') ? 'ak' : null, text: n.transcript })));
      }
    }
    const dl = h('dl', { class: 'meta-dl' });
    const row = (k, v, mono) => dl.append(h('dt', { text: k }), h('dd', { class: mono ? 'mono' : null, text: v }));
    row('Recorded', t ? `${fmtDate(t, true)}, ${fmtTime(t)}` : '–');
    row('Length', dur(n.duration));
    if (n.language) row('Language', n.language);
    row('Status', n.status === 'done' ? (n.silent ? 'Transcribed · no speech' : 'Transcribed') : n.status === 'pending' ? 'Waiting to be transcribed' : 'Failed');
    row('ID', n.id, true);
    parts.push(sec('Details', dl));
    parts.push(h('div', { class: 'detail-foot' },
      n.status === 'failed' && h('button', { class: 'btn btn-ghost', type: 'button', onclick: () => retry(n) }, icon('refresh'), 'Try again'),
      h('button', { class: 'btn btn-quiet danger', type: 'button', onclick: () => del(n) }, icon('trash'), 'Delete note')));
    return h('article', { class: 'detail' }, parts);
  }
  async function retry(n) {
    try {
      await api(`/api/notes/${enc(n.id)}/retry`, { method: 'POST', body: {} });
      toast('Queued for transcription');
      showDetail(n.id);
      load(false);
    } catch (e) { if (e.status !== 401) toast(`Couldn’t retry: ${e.message}`, 'error'); }
  }
  async function del(n) {
    const ok = await confirmDialog({ title: 'Delete this note?', body: `“${noteTitle(n)}” and its recording are removed from the device for good.`, ok: 'Delete' });
    if (!ok) return;
    try {
      await api('/api/notes/' + enc(n.id), { method: 'DELETE' });
      toast('Note deleted');
      if (list) list = list.filter((x) => x.id !== n.id);
      replaceTo('#/notes');
      load(false);
    } catch (e) { if (e.status !== 401) toast(`Couldn’t delete: ${e.message}`, 'error'); }
  }

  load(true);
  showDetail(route0.param);
  return {
    update(r) { showDetail(r.param); },
    leave() { life.alive = false; clearTimeout(pollT); clearTimeout(listPollT); },
  };
};

/* ================================================================ charts */

function nice(max, n = 3) {
  if (!(max > 0)) return { max: 1, ticks: [0, 1] };
  const raw = max / n, mag = Math.pow(10, Math.floor(Math.log10(raw))), f = raw / mag;
  const step = (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * mag;
  const top = Math.ceil(max / step) * step;
  const ticks = [];
  for (let v = 0; v <= top + step / 2; v += step) ticks.push(Math.round(v * 1e6) / 1e6);
  return { max: top, ticks };
}
const kfmt = (v) => (v >= 1000 ? `${nf1.format(v / 1000)}k` : fmtN(v));
function topBar(x, y, w, hh, r) {
  r = Math.max(0, Math.min(r, w / 2, hh));
  return `M${x},${y + hh}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + hh}Z`;
}
/**
 * A responsive SVG column chart. It is drawn at the container's real width
 * (so text is never stretched) and redrawn on resize. Hover, tap, or focus
 * and use ←/→ to read a column.
 */
function chart(cfg, cleanups) {
  const wrap = h('div', { class: 'chart', tabindex: '0', role: 'group', 'aria-roledescription': 'chart', 'aria-label': cfg.aria + '. Use the arrow keys to read each value.' });
  const tip = h('div', { class: 'chart-tip', 'aria-hidden': 'true' });
  const live = h('div', { class: 'sr', 'aria-live': 'polite' });
  wrap.append(tip);
  const H = cfg.height || 184, L = 40, R = cfg.rTicks ? 30 : 8, T = 12, B = 24;
  const lo = cfg.min || 0, hi = cfg.max;
  let W = 0, geo = null, hot = -1, svg = null, cols = [];

  function render() {
    const w = Math.round(wrap.clientWidth);
    if (!w || w === W) return;
    W = w;
    const pw = W - L - R, ph = H - T - B, n = cfg.cols.length, step = pw / n;
    const bw = Math.max(3, Math.min(30, step * (n > 14 ? 0.62 : 0.52)));
    const y = (v) => T + ph - ((v - lo) / (hi - lo || 1)) * ph;
    const yr = (v) => T + ph - (v / (cfg.rMax || 100)) * ph;
    geo = { y, yr, step, bw, base: T + ph, T, ph };
    const s = sv('svg', { width: W, height: H, viewBox: `0 0 ${W} ${H}`, 'aria-hidden': 'true' });
    for (const t of cfg.ticks) {
      const yy = Math.round(y(t)) + 0.5;
      s.append(sv('line', { class: 'gl' + (t === lo ? ' base' : ''), x1: L, x2: W - R, y1: yy, y2: yy }));
      s.append(sv('text', { class: 'ax', x: L - 8, y: yy + 4, 'text-anchor': 'end' }, cfg.fmtY(t)));
    }
    if (cfg.rTicks) {
      for (const v of cfg.rTicks) s.append(sv('text', { class: 'ax r', x: W - R + 6, y: Math.round(yr(v)) + 4, 'text-anchor': 'start' }, String(v)));
    }
    cols = cfg.cols.map((c, i) => {
      const cx = L + step * (i + 0.5);
      const g = sv('g', { class: 'col' + (c.dim ? ' dim' : '') });
      g.append(sv('rect', { class: 'hl', x: L + step * i + 1, y: T - 4, width: Math.max(1, step - 2), height: ph + 4, rx: 6 }));
      let top = geo.base;
      if (!c.empty) { const r = cfg.draw(g, c, { ...geo, cx }); if (r != null) top = r; }
      if (c.label && c.show !== false) g.append(sv('text', { class: 'ax', x: cx, y: H - 6, 'text-anchor': 'middle' }, c.label));
      s.append(g);
      return { g, cx, top };
    });
    s.append(sv('rect', { class: 'hit', x: L, y: 0, width: pw, height: H }));
    if (svg) svg.remove();
    svg = s;
    wrap.prepend(svg);
    if (hot >= 0) show(hot);
  }
  function idxAt(clientX) {
    const r = svg.getBoundingClientRect();
    return Math.max(0, Math.min(cfg.cols.length - 1, Math.floor((clientX - r.left - L) / geo.step)));
  }
  function show(i) {
    if (!svg) return;
    hot = i;
    cols.forEach((c, j) => c.g.classList.toggle('hot', j === i));
    const c = cfg.cols[i], tp = c.tip || { title: c.label, rows: [] };
    const rows = tp.rows && tp.rows.length ? tp.rows : [['', c.future ? 'Not yet' : 'No data']];
    tip.replaceChildren(h('b', { text: tp.title }), ...rows.map(([k, v, sw]) => h('div', null, h('span', null, sw && h('i', { class: sw }), k), h('span', { text: v }))));
    live.textContent = `${tp.title}: ${rows.map(([k, v]) => (k ? `${k} ${v}` : v)).join(', ')}`;
    tip.classList.add('on');
    const tw = tip.offsetWidth, cx = cols[i].cx, gap = geo.bw / 2 + 10;
    let left = cx < W / 2 ? cx + gap : cx - gap - tw;
    left = Math.max(0, Math.min(W - tw, left));
    tip.style.transform = `translate(${Math.round(left)}px, ${Math.round(Math.max(0, T - 8))}px)`;
  }
  function hide() { hot = -1; tip.classList.remove('on'); cols.forEach((c) => c.g.classList.remove('hot')); }
  const lastIdx = () => { for (let i = cfg.cols.length - 1; i >= 0; i--) if (!cfg.cols[i].empty) return i; return 0; };
  wrap.addEventListener('pointermove', (e) => { if (e.pointerType === 'mouse' && svg) show(idxAt(e.clientX)); });
  wrap.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse' && D.activeElement !== wrap) hide(); });
  wrap.addEventListener('pointerdown', (e) => { if (e.pointerType !== 'mouse' && svg) show(idxAt(e.clientX)); });
  wrap.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      e.preventDefault();
      const n = cfg.cols.length;
      show(hot < 0 ? lastIdx() : Math.max(0, Math.min(n - 1, hot + (e.key === 'ArrowRight' ? 1 : -1))));
    } else if (e.key === 'Home') { e.preventDefault(); show(0); } else if (e.key === 'End') { e.preventDefault(); show(cfg.cols.length - 1); } else if (e.key === 'Escape') hide();
  });
  wrap.addEventListener('blur', hide);
  const outside = (e) => { if (hot >= 0 && !wrap.contains(e.target)) hide(); };
  D.addEventListener('pointerdown', outside);
  cleanups.push(() => D.removeEventListener('pointerdown', outside));
  if ('ResizeObserver' in window) {
    const ro = new ResizeObserver(() => render());
    ro.observe(wrap);
    cleanups.push(() => ro.disconnect());
  } else {
    const f = () => render();
    window.addEventListener('resize', f);
    cleanups.push(() => window.removeEventListener('resize', f));
  }
  requestAnimationFrame(render);
  return h('div', null, wrap, live);
}
const drawBar = (clsOf) => (g, c, geo) => {
  const y0 = geo.y(c.v), hh = Math.max(2, geo.base - y0);
  g.append(sv('path', { class: clsOf(c), d: topBar(geo.cx - geo.bw / 2, geo.base - hh, geo.bw, hh, Math.min(4, geo.bw / 3)) }));
  return geo.base - hh;
};
function drawStack(g, c, geo) {
  const segs = [['c-deep', c.n.deep], ['c-light', c.n.light], ['c-rem', c.n.rem], ['c-awake', c.n.awake]].filter((x) => x[1] > 0);
  let yb = geo.base;
  segs.forEach(([cls, v], i) => {
    const hh = geo.base - geo.y(v);
    const last = i === segs.length - 1;
    g.append(last
      ? sv('path', { class: cls, d: topBar(geo.cx - geo.bw / 2, yb - hh, geo.bw, hh, Math.min(4, geo.bw / 3)) })
      : sv('rect', { class: cls, x: geo.cx - geo.bw / 2, y: yb - hh, width: geo.bw, height: Math.max(0, hh - 0.5) }));
    yb -= hh;
  });
  if (c.score != null) g.append(sv('circle', { class: 'sd', cx: geo.cx, cy: geo.yr(c.score), r: geo.bw > 10 ? 4.5 : 3.5 }));
  return Math.min(yb, c.score != null ? geo.yr(c.score) : yb);
}
function drawRange(g, c, geo) {
  const y1 = geo.y(c.hr.max), y2 = geo.y(c.hr.min), w = Math.max(4, geo.bw * 0.5);
  g.append(sv('rect', { class: 'rng', x: geo.cx - w / 2, y: y1, width: w, height: Math.max(3, y2 - y1), rx: w / 2 }));
  if (c.hr.avg != null) {
    const ya = geo.y(c.hr.avg), aw = Math.max(8, geo.bw * 0.9);
    g.append(sv('line', { class: 'avg', x1: geo.cx - aw / 2, x2: geo.cx + aw / 2, y1: ya, y2: ya }));
  }
  return y1;
}

/* ================================================================ health */

const PERIODS = ['day', 'week', 'month', 'year'];
function startOf(p, d) {
  if (p === 'day') return day0(d);
  if (p === 'week') return addDays(day0(d), -((d.getDay() + 6) % 7));
  if (p === 'month') return new Date(d.getFullYear(), d.getMonth(), 1);
  return new Date(d.getFullYear(), 0, 1);
}
function endOf(p, d) {
  if (p === 'day') return day0(d);
  if (p === 'week') return addDays(startOf('week', d), 6);
  if (p === 'month') return new Date(d.getFullYear(), d.getMonth() + 1, 0);
  return new Date(d.getFullYear(), 11, 31);
}
function shiftP(p, d, n) {
  if (p === 'day') return addDays(d, n);
  if (p === 'week') return addDays(d, 7 * n);
  if (p === 'month') return new Date(d.getFullYear(), d.getMonth() + n, 1);
  return new Date(d.getFullYear() + n, 0, 1);
}
function rangeText(a, b) {
  const yr = b.getFullYear() !== new Date().getFullYear() ? ` ${b.getFullYear()}` : '';
  if (a.getMonth() === b.getMonth()) return `${a.getDate()}–${b.getDate()} ${MON[b.getMonth()]}${yr}`;
  return `${a.getDate()} ${MON[a.getMonth()]} – ${b.getDate()} ${MON[b.getMonth()]}${yr}`;
}
function periodLabel(p, d) {
  const today = day0(new Date());
  if (p === 'day') {
    const n = dayDiff(today, d);
    return n === 0 ? ['Today', fmtDate(d)] : n === 1 ? ['Yesterday', fmtDate(d)] : [fmtDate(d), ''];
  }
  if (p === 'week') {
    const s = startOf('week', d), e = endOf('week', d), n = dayDiff(startOf('week', today), s) / 7;
    return n === 0 ? ['This week', rangeText(s, e)] : n === 1 ? ['Last week', rangeText(s, e)] : [rangeText(s, e), ''];
  }
  if (p === 'month') return [`${MONL[d.getMonth()]} ${d.getFullYear()}`, ''];
  return [String(d.getFullYear()), ''];
}

PAGES.health = function pageHealth(view) {
  setTop({ title: 'Health' });
  const life = { alive: true };
  let cleanups = [];
  let period = pref.get('health.period', 'week');
  if (!PERIODS.includes(period)) period = 'week';
  let anchor = day0(new Date()), seq = 0;

  const seg = h('div', { class: 'seg', role: 'group', 'aria-label': 'Period' },
    PERIODS.map((p) => h('button', { type: 'button', 'data-p': p, onclick: () => setPeriod(p) }, cap(p))));
  const prev = h('button', { class: 'icon-btn', type: 'button', onclick: () => move(-1) }, icon('chevL'));
  const next = h('button', { class: 'icon-btn', type: 'button', onclick: () => move(1) }, icon('chevR'));
  const label = h('div', { class: 'period-label', 'aria-live': 'polite' });
  const body = h('div', { class: 'page' });
  view.append(h('div', { class: 'page' }, h('div', { class: 'health-ctrl' }, seg, h('div', { class: 'period-nav' }, prev, label, next)), body));

  function setPeriod(p) {
    if (p === period) return;
    period = p;
    pref.set('health.period', p);
    const today = day0(new Date());
    if (anchor > today) anchor = today;
    load();
  }
  function move(dir) {
    const today = day0(new Date());
    const n = shiftP(period, anchor, dir);
    if (startOf(period, n) > today) return;
    anchor = n > today ? today : n;
    load();
  }
  function paintCtl() {
    seg.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.p === period)));
    const [main, sub] = periodLabel(period, anchor);
    label.replaceChildren(h('b', { text: main }), sub && h('span', { text: sub }));
    const atEnd = endOf(period, anchor) >= day0(new Date());
    next.disabled = atEnd;
    prev.setAttribute('aria-label', `Previous ${period}`);
    next.setAttribute('aria-label', atEnd ? `Next ${period} (not yet)` : `Next ${period}`);
  }
  function clearCharts() { cleanups.forEach((f) => f()); cleanups = []; }

  async function load() {
    const my = ++seq;
    paintCtl();
    clearCharts();
    body.replaceChildren(skel('health'));
    try {
      const d = await api(`/api/health/report?period=${period}&anchor=${dkey(anchor)}`);
      if (!life.alive || my !== seq) return;
      body.replaceChildren();
      renderReport(d);
    } catch (e) {
      if (!life.alive || my !== seq || e.status === 401) return;
      body.replaceChildren(errorState(e, load));
    }
  }

  function renderReport(d) {
    const tot = d.total || {};
    const days = d.days || [];
    const one = period === 'day' ? days.find((x) => x.day === dkey(anchor)) || days[0] || null : null;
    const hasData = (tot.days || 0) > 0 || !!one;
    if (!hasData) {
      const [main] = periodLabel(period, anchor);
      body.append(h('div', { class: 'card' }, emptyState('pulse', `No health data for ${/^(This|Last|Today|Yesterday)/.test(main) ? main.toLowerCase() : main}`,
        'The ring holds about a week of history and the device keeps everything it syncs. Days the ring wasn’t worn stay empty.')));
      return;
    }
    body.append(kpis(tot, one));
    const charts = h('div', { class: 'charts' });
    body.append(charts);
    if (period === 'day') dayCharts(charts, tot, one);
    else spanCharts(charts, d, tot, days);
  }

  function kpis(tot, one) {
    const isDay = period === 'day';
    const steps = isDay && one ? one.steps : tot.steps;
    let liveSteps = steps;
    const o = S.overview;
    if (isDay && dayDiff(new Date(), anchor) === 0 && o && o.ring && o.ring.liveSteps > (steps || 0)) liveSteps = o.ring.liveSteps;
    const hr = tot.hr || (one && one.hr), sp = tot.spo2 || (one && one.spo2);
    const night = one && one.night, sl = tot.sleep;
    const stress = tot.stress != null ? tot.stress : one && one.stress;
    const stepSub = isDay
      ? [one && one.distance != null ? `${nf1.format(one.distance / 1000)} km` : null, one && one.calories != null ? `${fmtN(one.calories)} kcal` : null].filter(Boolean).join(' · ')
      : tot.stepsPerDay != null ? `${fmtN(tot.stepsPerDay)} a day on average` : '';
    const sleepVal = isDay ? (night ? hmBig(night.asleep) : '–') : (sl && sl.nights ? hmBig(sl.minutes) : '–');
    const sleepSub = isDay
      ? (night ? `Score ${night.score} · ${cap(night.label)}` : 'No sleep recorded')
      : (sl && sl.nights ? `Score ${sl.score} · ${plural(sl.nights, 'night', 'nights')}` : 'No sleep recorded');
    return h('div', { class: 'kpis' },
      metric('card kpi m-steps', 'steps', 'Steps', liveSteps != null ? fmtN(liveSteps) : '–', stepSub),
      metric('card kpi m-heart', 'heart', 'Heart rate', hr ? [String(hr.avg), h('small', null, 'bpm')] : '–', hr ? `Range ${hr.min}–${hr.max}` : 'No readings'),
      metric('card kpi m-sleep', 'moon', isDay ? 'Sleep' : 'Sleep, average', sleepVal, sleepSub),
      metric('card kpi m-spo2', 'drop', 'Blood oxygen', sp ? [String(sp.avg), h('small', null, '%')] : '–', sp ? `Range ${sp.min}–${sp.max}%` : 'No readings'),
      stressMetric(stress, isDay && one && one.stressProvisional, 'card kpi wide m-stress'));
  }

  function chartCard(title, ic, headVal, content, foot, full) {
    return h('section', { class: 'card chart-card' + (full ? ' full' : '') },
      h('div', { class: 'card-head' }, h('h2', { class: 'card-title' }, icon(ic), title), headVal && h('div', { class: 'chart-head-val' }, headVal)),
      content, foot);
  }
  const sleepLegend = (withScore) => h('div', { class: 'legend chart-foot' },
    [['s-deep', 'Deep'], ['s-light', 'Light'], ['s-rem', 'REM'], ['s-awake', 'Awake']].map(([c, t]) => h('span', null, h('i', { class: c }), t)),
    withScore && h('span', null, h('i', { style: 'background:var(--accent);border-radius:50%' }), 'Score'));
  const stressNote = () => h('div', null,
    h('div', { class: 'legend chart-foot' }, [['sx-rest', 'Rest 0–25'], ['sx-low', 'Low 26–50'], ['sx-med', 'Medium 51–75'], ['sx-high', 'High 76+']].map(([c, t]) =>
      h('span', null, h('i', { style: `background:var(--${c})` }), t))),
    h('p', { class: 'chart-note' }, icon('info'), 'Estimated from heart rate — the ring has no HRV. Not a diagnosis.'));

  function dayCharts(root, tot, one) {
    const n = one && one.night;
    // Sleep
    let sleepBody;
    if (n) {
      const fa = parseT(n.fellAsleep), wk = parseT(n.woke);
      sleepBody = [stageBar(n, true),
        h('div', { class: 'legend chart-foot' }, [['s-deep', 'Deep', n.deep], ['s-light', 'Light', n.light], ['s-rem', 'REM', n.rem], ['s-awake', 'Awake', n.awake]]
          .map(([c, t, v]) => h('span', null, h('i', { class: c }), t, h('b', { text: hm(v || 0) })))),
        h('dl', { class: 'sleep-times' },
          h('div', null, h('dt', { text: 'Fell asleep' }), h('dd', { text: fa ? fmtTime(fa) : '–' })),
          h('div', null, h('dt', { text: 'Woke up' }), h('dd', { text: wk ? fmtTime(wk) : '–' }))),
        n.bouts != null ? h('p', { class: 'chart-note', text: n.bouts ? `Woke ${plural(n.bouts, 'time', 'times')} in the night` : 'Slept through the night' }) : null];
    } else {
      sleepBody = emptyState('moon', 'No sleep recorded', 'The night that ended this morning has no sleep data.');
    }
    root.append(chartCard('Sleep', 'moon', n ? [h('b', { text: hm(n.asleep) }), `Score ${n.score} · ${cap(n.label)}`] : null, sleepBody, null, true));
    // Heart rate
    const hr = tot.hr || (one && one.hr);
    let hrBody;
    if (hr) {
      const lo = Math.min(40, Math.floor((hr.min - 5) / 20) * 20), hi = Math.max(160, Math.ceil((hr.max + 5) / 20) * 20);
      const pct = (v) => `${((v - lo) / (hi - lo)) * 100}%`;
      const ticks = [];
      for (let v = lo; v <= hi; v += 40) ticks.push(v);
      hrBody = [h('div', { class: 'rangebar', role: 'img', 'aria-label': `Heart rate ranged from ${hr.min} to ${hr.max} bpm, averaging ${hr.avg}` },
        h('div', { class: 'track' }), h('div', { class: 'fill', style: `left:${pct(hr.min)};width:calc(${pct(hr.max)} - ${pct(hr.min)})` }),
        h('div', { class: 'mark', style: `left:${pct(hr.avg)}` }),
        h('div', { class: 'ticks' }, ticks.map((t) => h('span', { text: String(t) })))),
      h('dl', { class: 'kv', style: 'margin-top:12px' },
        h('div', null, h('dt', { text: 'Lowest' }), h('dd', null, String(hr.min), h('small', { text: ' bpm' }))),
        h('div', null, h('dt', { text: 'Highest' }), h('dd', null, String(hr.max), h('small', { text: ' bpm' })))),
      one && one.hr && one.hr.n ? h('p', { class: 'chart-note', text: `${fmtN(one.hr.n)} readings` }) : null];
    } else hrBody = emptyState('heart', 'No heart-rate readings', 'The ring measures through the day while it’s worn.');
    root.append(chartCard('Heart rate', 'heart', hr ? [h('b', { text: `${hr.avg} bpm` }), 'average'] : null, hrBody));
    // Stress
    const v = tot.stress != null ? tot.stress : one && one.stress;
    const b = band(v);
    const stressBody = v != null
      ? [h('div', { class: 'bandbar', role: 'img', 'aria-label': `Stress estimate ${v} of 100, ${b[1]}` },
        h('div', { class: 'bands' }, h('span'), h('span'), h('span'), h('span')),
        h('div', { class: 'pin', style: `left:${Math.max(0, Math.min(100, v))}%` }),
        h('div', { class: 'bl' }, h('span', { text: 'Rest' }), h('span', { text: 'Low' }), h('span', { text: 'Medium' }), h('span', { text: 'High' }))),
      one && one.stressProvisional ? h('p', { class: 'chart-note' }, icon('clock'), 'Still learning your baseline — it needs five days of data.') : null,
      h('p', { class: 'chart-note' }, icon('info'), 'Estimated from heart rate — the ring has no HRV. Not a diagnosis.')]
      : emptyState('gauge', 'No stress estimate', 'It’s worked out from heart rate while you’re still.');
    root.append(chartCard('Stress', 'gauge', v != null ? [h('b', { class: 'band-' + b[0], text: `${v} · ${b[1]}` }), 'estimate'] : null, stressBody));
  }

  function spanCharts(root, d, tot, days) {
    const today = day0(new Date());
    const from = parseT(tot.from) || startOf(period, anchor);
    const to = parseT(tot.to) || endOf(period, anchor);
    const bmap = new Map();
    for (const b of d.buckets || []) {
      const k = period === 'year' ? String(b.from || b.label || '').slice(0, 7) : String(b.from || b.label || '').slice(0, 10);
      bmap.set(k, b);
    }
    const dmap = new Map(days.map((x) => [x.day, x]));
    const cols = [];
    if (period === 'year') {
      const y = from.getFullYear();
      for (let m = 0; m < 12; m++) {
        const k = `${y}-${pad(m + 1)}`, first = new Date(y, m, 1);
        cols.push({ key: k, date: first, b: bmap.get(k), future: first > today, title: `${MONL[m]} ${y}` });
      }
    } else {
      for (let t = day0(from); t <= to; t = addDays(t, 1)) {
        const k = dkey(t);
        cols.push({ key: k, date: t, b: bmap.get(k), day: dmap.get(k), future: t > today, title: fmtDate(t) });
      }
    }
    const narrow = () => (cols.length === 12 ? (root.clientWidth || 360) < 520 : false);
    const lab = (c, i) => {
      if (period === 'week') return { label: WD[c.date.getDay()], show: true };
      if (period === 'month') { const dd = c.date.getDate(); return { label: String(dd), show: (dd - 1) % 7 === 0 }; }
      return { label: narrow() ? MON[i].charAt(0) : MON[i], show: true };
    };
    const has = (b) => b && (b.days == null || b.days > 0);

    // Steps
    const sc = cols.map((c, i) => {
      const v = has(c.b) && c.b.steps != null ? c.b.steps : c.day ? c.day.steps : null;
      const rows = v == null ? [] : [['Steps', fmtN(v)]];
      if (v != null && period === 'year' && c.b.stepsPerDay != null) rows.push(['Per day', fmtN(c.b.stepsPerDay)]);
      return { ...lab(c, i), v, empty: v == null, future: c.future, tip: { title: c.title, rows } };
    });
    const smax = nice(Math.max(1000, ...sc.filter((c) => !c.empty).map((c) => c.v)));
    root.append(chartCard('Steps', 'steps', [h('b', { text: fmtN(tot.steps) }), tot.stepsPerDay != null ? `${fmtN(tot.stepsPerDay)} a day` : ''],
      chart({ cols: sc, max: smax.max, ticks: smax.ticks, fmtY: kfmt, draw: drawBar(() => 'bar'), aria: `Steps per ${period === 'year' ? 'month' : 'day'}` }, cleanups)));

    // Sleep
    if (period === 'year') {
      const slc = cols.map((c, i) => {
        const s = has(c.b) && c.b.sleep && c.b.sleep.nights ? c.b.sleep : null;
        return { ...lab(c, i), v: s ? s.minutes : null, score: s ? s.score : null, empty: !s, future: c.future,
          tip: { title: c.title, rows: s ? [['Average', hm(s.minutes)], ['Score', String(s.score)], ['Nights', String(s.nights)]] : [] } };
      });
      const topH = sleepTop(slc);
      root.append(chartCard('Sleep', 'moon', sleepHead(tot),
        chart({ cols: slc, max: topH * 60, ticks: [0, topH * 30, topH * 60], fmtY: (v) => `${v / 60} h`, rTicks: [50, 100],
          draw: (g, c, geo) => {
            const top = drawBar(() => 'bar c-sleep')(g, c, geo);
            if (c.score != null) g.append(sv('circle', { class: 'sd', cx: geo.cx, cy: geo.yr(c.score), r: 4 }));
            return Math.min(top, c.score != null ? geo.yr(c.score) : top);
          }, aria: 'Average sleep per month' }, cleanups),
        h('div', { class: 'legend chart-foot' }, h('span', null, h('i', { style: 'background:var(--st-light)' }), 'Average sleep'),
          h('span', null, h('i', { style: 'background:var(--accent);border-radius:50%' }), 'Score (right axis)'))));
    } else {
      const slc = cols.map((c, i) => {
        const n = c.day && c.day.night;
        const rows = n ? [['Asleep', hm(n.asleep)], ['Deep', hm(n.deep), 's-deep'], ['Light', hm(n.light), 's-light'], ['REM', hm(n.rem), 's-rem'],
          ['Awake', hm(n.awake), 's-awake'], ['Score', `${n.score} · ${cap(n.label)}`]] : [];
        const total = n ? (n.deep || 0) + (n.light || 0) + (n.rem || 0) + (n.awake || 0) : null;
        return { ...lab(c, i), n, v: total, score: n ? n.score : null, empty: !n, future: c.future, tip: { title: c.title, rows } };
      });
      const topH = sleepTop(slc);
      root.append(chartCard('Sleep', 'moon', sleepHead(tot),
        chart({ cols: slc, max: topH * 60, ticks: [0, topH * 30, topH * 60], fmtY: (v) => `${v / 60} h`, rTicks: [50, 100], draw: drawStack,
          aria: 'Sleep stages per night with sleep score' }, cleanups), sleepLegend(true)));
    }

    // Heart rate
    const hc = cols.map((c, i) => {
      const hr = has(c.b) && c.b.hr ? c.b.hr : c.day && c.day.hr ? c.day.hr : null;
      return { ...lab(c, i), hr, empty: !hr || hr.min == null, future: c.future,
        tip: { title: c.title, rows: hr ? [['Average', `${hr.avg} bpm`], ['Range', `${hr.min}–${hr.max}`]] : [] } };
    });
    const hv = hc.filter((c) => !c.empty);
    const hlo = hv.length ? Math.max(0, Math.floor((Math.min(...hv.map((c) => c.hr.min)) - 5) / 20) * 20) : 40;
    const hhi = hv.length ? Math.ceil((Math.max(...hv.map((c) => c.hr.max)) + 5) / 20) * 20 : 160;
    const hstep = (hhi - hlo) / 20 > 5 ? 40 : 20;
    const hticks = [];
    for (let v = hlo; v <= hhi; v += hstep) hticks.push(v);
    root.append(chartCard('Heart rate', 'heart', tot.hr ? [h('b', { text: `${tot.hr.avg} bpm` }), `range ${tot.hr.min}–${tot.hr.max}`] : null,
      chart({ cols: hc, min: hlo, max: hticks[hticks.length - 1], ticks: hticks, fmtY: String, draw: drawRange, aria: 'Heart rate range and average' }, cleanups),
      h('div', { class: 'legend chart-foot' }, h('span', null, h('i', { style: 'background:var(--sx-high);opacity:.5' }), 'Lowest to highest'),
        h('span', null, h('i', { style: 'background:var(--sx-high);height:3px' }), 'Average'))));

    // Stress
    const xc = cols.map((c, i) => {
      const v = has(c.b) && c.b.stress != null ? c.b.stress : c.day && c.day.stress != null ? c.day.stress : null;
      const b = band(v);
      return { ...lab(c, i), v, empty: v == null, future: c.future, band: b, tip: { title: c.title, rows: v == null ? [] : [['Estimate', `${v} · ${b[1]}`]] } };
    });
    const tb = band(tot.stress);
    root.append(chartCard('Stress', 'gauge', tot.stress != null ? [h('b', { class: 'band-' + tb[0], text: `${tot.stress} · ${tb[1]}` }), 'average estimate'] : null,
      chart({ cols: xc, max: 100, ticks: [0, 25, 50, 75, 100], fmtY: String, draw: drawBar((c) => 'x-' + c.band[0]), aria: 'Stress estimate' }, cleanups),
      stressNote()));
  }
  function sleepTop(cs) {
    const mh = Math.max(0, ...cs.filter((c) => !c.empty).map((c) => c.v || 0)) / 60;
    return mh <= 8 ? 8 : mh <= 10 ? 10 : mh <= 12 ? 12 : Math.ceil(mh / 4) * 4;
  }
  function sleepHead(tot) {
    const s = tot.sleep;
    return s && s.nights ? [h('b', { text: hm(s.minutes) }), `avg · score ${s.score}`] : null;
  }

  load();
  return { leave() { life.alive = false; clearCharts(); } };
};

/* ================================================================= chats */

function chatSeg(active) {
  return h('nav', { class: 'seg', 'aria-label': 'Conversations' },
    h('a', { href: '#/chats', 'aria-current': active === 'chats' ? 'page' : null }, icon('sparkle', 'ic-sm'), aiName()),
    h('a', { href: '#/calls', 'aria-current': active === 'calls' ? 'page' : null }, icon('phone', 'ic-sm'), 'Calls'));
}

PAGES.chats = function pageChats(view, route0) {
  const life = { alive: true };
  let days = null, seqD = 0, seqS = 0, current = null;
  const search = searchBox(S.chatsQ, 'Search conversations', debounce((v) => { S.chatsQ = v; renderLeft(); }, 300));
  const listEl = h('div', { class: 'stack' });
  const detail = h('div', { class: 'pane-detail' });
  const split = h('div', { class: 'split' }, h('div', { class: 'pane-list' }, chatSeg('chats'), search.el, listEl), detail);
  const openDetail = splitNav(split);
  view.append(split);

  async function loadDays() {
    const my = ++seqD;
    listEl.replaceChildren(h('div', { class: 'card' }, skel('rows')));
    try {
      const d = await api('/api/conversations/days?limit=60');
      if (!life.alive || my !== seqD) return;
      days = d.days || [];
      renderLeft();
    } catch (e) {
      if (!life.alive || my !== seqD || e.status === 401) return;
      listEl.replaceChildren(errorState(e, loadDays));
    }
  }
  function renderLeft() {
    if (S.chatsQ.trim()) { runSearch(S.chatsQ.trim()); return; }
    seqS++;
    if (!days) { loadDays(); return; }
    if (!days.length) {
      listEl.replaceChildren(h('div', { class: 'card' }, emptyState('sparkle', 'No conversations yet',
        `Swipe up on the device, or press and hold the ring, and talk to ${aiName()}. What you both say is kept here.`)));
      return;
    }
    listEl.replaceChildren(h('div', { class: 'card', style: 'padding:8px' }, h('div', { class: 'list', style: 'margin:0' }, days.map((x) => {
      const t = parseT(x.day);
      return lrow({ href: '#/chats/' + enc(x.day), ic: 'chat', tone: dayDiff(new Date(), t) === 0 ? 'accent' : null, title: fmtDayRel(t),
        sub: `${plural(x.conversations, 'conversation', 'conversations')} · ${plural(x.turns, 'turn', 'turns')}`,
        current: x.day === current, end: dayDiff(new Date(), t) < 2 ? h('span', { text: fmtDate(t) }) : null });
    }))));
  }
  async function runSearch(q) {
    const my = ++seqS;
    listEl.replaceChildren(skel('list'));
    try {
      const d = await api('/api/conversations/search?q=' + enc(q));
      if (!life.alive || my !== seqS) return;
      const res = d.results || [];
      if (!res.length) {
        listEl.replaceChildren(emptyState('search', `Nothing matches “${q}”`, `Search covers the last 90 days of conversations with ${aiName()}.`));
        return;
      }
      listEl.replaceChildren(h('p', { class: 'hint', style: 'margin:0 4px', text: `${plural(res.length, 'match', 'matches')}${res.length >= 50 ? ' (showing the newest 50)' : ''}` }),
        ...res.map((r) => {
          const t = parseT(r.t);
          const who = r.role === 'user' ? 'You' : r.role === 'tool' ? 'Tool' : aiName();
          return h('a', { class: 'result', href: '#/chats/' + enc(r.day), onclick: () => { S.focusConv = r.conversationId; } },
            h('span', { class: 'result-meta' }, h('b', { text: who }), h('span', { text: `${fmtDayRel(parseT(r.day))} · ${fmtTime(t)}` })),
            h('span', { class: 'result-text' + (r.role === 'tool' ? ' tool' : '') }, highlight(r.text || '', q)));
        }));
    } catch (e) {
      if (!life.alive || my !== seqS || e.status === 401) return;
      listEl.replaceChildren(errorState(e, () => runSearch(q)));
    }
  }
  async function showDay(day) {
    current = day;
    openDetail(!!day);
    listEl.querySelectorAll('.lrow').forEach((a) => {
      if (a.getAttribute('href') === '#/chats/' + enc(day || '')) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    });
    if (!day) {
      setTop({ title: 'Chats' });
      detail.replaceChildren(h('div', { class: 'pane-empty' }, emptyState('chat', 'Choose a day', `Every conversation with ${aiName()} that day appears here, word for word.`)));
      return;
    }
    const t = parseT(day);
    setTop({ title: fmtDayRel(t), back: '#/chats' });
    detail.replaceChildren(h('div', { class: 'detail' }, skel('list')));
    detail.scrollTop = 0;
    try {
      const d = await api('/api/conversations?day=' + enc(day));
      if (!life.alive || current !== day) return;
      const convs = d.conversations || [];
      const focus = S.focusConv;
      S.focusConv = null;
      const cards = convs.map((c, i) => convCard(c, focus ? c.id === focus : i === convs.length - 1, c.id === focus));
      detail.replaceChildren(h('div', { class: 'detail' },
        h('div', { class: 'detail-head' },
          h('div', { class: 'detail-top' }, h('h2', { class: 'detail-title', text: t ? longDate(t) : day }),
            h('a', { class: 'icon-btn desk-only', href: '#/chats', 'aria-label': 'Close' }, icon('x'))),
          h('div', { class: 'detail-meta', text: `${plural(convs.length, 'conversation', 'conversations')} · ${plural(convs.reduce((a, c) => a + (c.turns || 0), 0), 'turn', 'turns')}` })),
        convs.length ? h('div', { class: 'convs' }, cards) : emptyState('chat', 'No conversations this day', '')));
      const f = detail.querySelector('.conv.focus');
      if (f) requestAnimationFrame(() => f.scrollIntoView({ block: 'start', behavior: 'smooth' }));
    } catch (e) {
      if (!life.alive || current !== day || e.status === 401) return;
      detail.replaceChildren(h('div', { class: 'detail' }, errorState(e, () => showDay(day))));
    }
  }

  renderLeft();
  showDay(route0.param);
  return { update(r) { showDay(r.param); }, leave() { life.alive = false; } };
};

function convCard(c, open, focus) {
  const s = parseT(c.start), e = parseT(c.end);
  const id = 'conv-' + String(c.id).replace(/[^\w-]/g, '');
  const body = h('div', { class: 'conv-body', id, hidden: !open });
  const btn = h('button', { class: 'conv-head', type: 'button', 'aria-expanded': String(!!open), 'aria-controls': id },
    h('span', { class: 'conv-time', text: fmtTime(s) === fmtTime(e) ? fmtTime(s) : `${fmtTime(s)} – ${fmtTime(e)}` }),
    h('span', { class: 'conv-turns' }, plural(c.turns || 0, 'turn', 'turns'), icon('chevR')),
    h('span', { class: 'conv-prev', text: c.preview || '' }));
  btn.addEventListener('click', () => {
    const o = btn.getAttribute('aria-expanded') !== 'true';
    btn.setAttribute('aria-expanded', String(o));
    body.hidden = !o;
    if (o && !body.firstChild) body.append(bubbles(c.entries || []));
  });
  if (open) body.append(bubbles(c.entries || []));
  return h('article', { class: 'conv' + (focus ? ' focus' : '') }, btn, body);
}
function bubbles(entries) {
  const out = h('div', { class: 'bubbles' });
  let prev = null;
  entries.forEach((e, i) => {
    if (e.role === 'tool') {
      out.append(h('div', { class: 'bubble-tool', title: 'Tool call' }, icon('code'), h('span', { text: e.text || '' })));
      return;
    }
    const me = e.role === 'user';
    if (prev !== e.role) out.append(h('div', { class: 'who' + (me ? ' me' : '') }, me ? 'You' : [icon('sparkle'), aiName()]));
    out.append(h('div', { class: 'bubble ' + (me ? 'me' : 'her'), text: e.text || '' }));
    let nx = null;
    for (let j = i + 1; j < entries.length; j++) if (entries[j].role !== 'tool') { nx = entries[j]; break; }
    if (!nx || nx.role !== e.role) out.append(h('time', { class: 'btime' + (me ? ' me' : ''), text: fmtTime(parseT(e.t)) }));
    prev = e.role;
  });
  if (!entries.length) out.append(h('p', { class: 'muted', text: 'Nothing was said.' }));
  return out;
}

/* ================================================================= calls */

PAGES.calls = function pageCalls(view, route0) {
  const life = { alive: true };
  let callers = null, current = null, loading = null;
  const listEl = h('div', { class: 'stack' });
  const detail = h('div', { class: 'pane-detail' });
  const split = h('div', { class: 'split' }, h('div', { class: 'pane-list' }, chatSeg('calls'), listEl), detail);
  const openDetail = splitNav(split);
  view.append(split);

  function load() {
    listEl.replaceChildren(h('div', { class: 'card' }, skel('rows')));
    loading = api('/api/calls').then((d) => {
      if (!life.alive) return;
      callers = d.callers || [];
      renderList();
      if (current) showCaller(current);
    }).catch((e) => {
      if (!life.alive || e.status === 401) return;
      listEl.replaceChildren(errorState(e, load));
      if (current) detail.replaceChildren(h('div', { class: 'detail' }, errorState(e, load)));
    });
    return loading;
  }
  function renderList() {
    if (!callers.length) {
      listEl.replaceChildren(h('div', { class: 'card' }, emptyState('phone', 'No calls yet',
        'When the call agent answers the phone for you, each call’s summary, promises and follow-ups appear here.')));
      return;
    }
    listEl.replaceChildren(h('div', { class: 'card', style: 'padding:8px' }, h('div', { class: 'list', style: 'margin:0' }, callers.map((c) => {
      const last = c.calls && c.calls[0] ? parseT(c.calls[0].at) : null;
      const open = (c.calls || []).some((k) => k.unresolved || k.callbackRequested);
      return lrow({ href: '#/calls/' + enc(c.key), avatar: avatarFor(c.contactName || c.display, !!c.contactName),
        title: c.contactName || c.display, current: c.key === current,
        sub: [c.contactName ? c.display : null, plural((c.calls || []).length, 'call', 'calls')].filter(Boolean).join(' · '),
        end: [open ? h('span', { class: 'dot warn', title: 'Something is still open', role: 'img', 'aria-label': 'Needs follow-up' }) : null,
          last ? h('span', { text: shortRel(last) }) : null] });
    }))));
  }
  async function showCaller(key) {
    current = key;
    openDetail(!!key);
    listEl.querySelectorAll('.lrow').forEach((a) => {
      if (a.getAttribute('href') === '#/calls/' + enc(key || '')) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    });
    if (!key) {
      setTop({ title: 'Calls' });
      detail.replaceChildren(h('div', { class: 'pane-empty' }, emptyState('phone', 'Choose a caller', 'Every call the agent took from them — what was said, promised, and claimed.')));
      return;
    }
    setTop({ title: 'Caller', back: '#/calls' });
    if (!callers) { detail.replaceChildren(h('div', { class: 'detail' }, skel('detail'))); return; }
    const c = callers.find((x) => x.key === key);
    if (!c) {
      detail.replaceChildren(h('div', { class: 'detail' }, emptyState('phone', 'No calls from this number', 'It may have been removed.', h('a', { class: 'btn btn-ghost', href: '#/calls' }, 'All callers'))));
      return;
    }
    const name = c.contactName || c.display;
    setTop({ title: name, back: '#/calls' });
    detail.scrollTop = 0;
    detail.replaceChildren(h('div', { class: 'detail' },
      h('div', { class: 'detail-top' },
        h('div', { class: 'caller-head grow' }, avatarFor(name, !!c.contactName, true),
          h('div', { style: 'min-width:0' }, h('h2', { text: name }), h('p', { text: [c.contactName ? c.display : 'Not in your contacts', plural((c.calls || []).length, 'call', 'calls')].join(' · ') }))),
        h('a', { class: 'icon-btn desk-only', href: '#/calls', 'aria-label': 'Close' }, icon('x'))),
      h('div', { class: 'row-flex' }, h('a', { class: 'btn btn-ghost btn-sm', href: 'tel:' + String(c.display || '').replace(/[^\d+]/g, '') }, icon('phone'), 'Call back'),
        h('a', { class: 'btn btn-quiet btn-sm', href: '#/memory' }, icon('book'), `What ${aiName()} knows`)),
      h('div', { class: 'stack' }, (c.calls || []).map(callCard))));
  }
  load();
  showCaller(route0.param);
  return { update(r) { showCaller(r.param); }, leave() { life.alive = false; } };
};
function callCard(k) {
  const t = parseT(k.at);
  const list = (items) => h('ul', null, items.map((x) => h('li', null, h('span', { text: x }))));
  return h('article', { class: 'card call-card' },
    h('div', { class: 'call-top' }, h('div', { class: 'call-when', text: t ? `${fmtDate(t)} · ${fmtTime(t)}` : '–' }), h('div', { class: 'call-dur', text: dur(k.seconds) })),
    (k.unresolved || k.abrupt || k.callbackRequested) ? h('div', { class: 'badges' },
      k.unresolved && h('span', { class: 'badge b-warn' }, icon('flag'), 'Unresolved'),
      k.abrupt && h('span', { class: 'badge b-danger' }, icon('x'), 'Cut off'),
      k.callbackRequested && h('span', { class: 'badge b-accent' }, icon('phone'), 'Callback requested')) : null,
    k.summary ? h('p', { class: 'call-sum', text: k.summary }) : h('p', { class: 'muted', text: 'No summary for this call.' }),
    (k.commitments || []).length ? h('div', { class: 'call-sec' }, h('h4', null, icon('hand'), 'You promised'), list(k.commitments)) : null,
    (k.actionItems || []).length ? h('div', { class: 'call-sec' }, h('h4', null, icon('checkSq'), 'Action items'), list(k.actionItems)) : null,
    (k.callerAsserted || []).length ? h('div', { class: 'call-sec claims' }, h('h4', null, icon('shield'), 'They said (unverified)'), list(k.callerAsserted),
      h('p', { class: 'claim-note', text: 'The caller’s own claims. Nobody has checked them.' })) : null);
}

/* ================================================================ memory */

PAGES.memory = function pageMemory(view) {
  setTop({ title: 'Memory' });
  const life = { alive: true };
  let facts = null, q = '';
  const text = h('textarea', { class: 'textarea', id: 'mem-text', rows: '2', placeholder: 'e.g. My sister Abena’s birthday is on 4 March', maxlength: '500' });
  const about = h('select', { class: 'select', id: 'mem-about', 'aria-label': 'About' });
  const addBtn = h('button', { class: 'btn btn-primary', type: 'submit', disabled: true }, icon('plus'), 'Remember');
  text.addEventListener('input', () => { addBtn.disabled = !text.value.trim(); });
  text.addEventListener('keydown', (e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); form.requestSubmit ? form.requestSubmit() : addFact(); } });
  const form = h('form', { class: 'card add-form', onsubmit: (e) => { e.preventDefault(); addFact(); } },
    h('label', { class: 'card-title', for: 'mem-text' }, icon('sparkle'), `Tell ${aiName()} something to remember`),
    text, h('div', { class: 'add-row' }, about, addBtn));
  const filter = searchBox('', `Filter what ${aiName()} remembers`, (v) => { q = v; render(); });
  const content = h('div', { class: 'mem-grid' });
  view.append(h('div', { class: 'page' }, form, filter.el, content));

  async function load() {
    content.replaceChildren(h('div', { class: 'span-all' }, skel()));
    try {
      const d = await api('/api/memory');
      if (!life.alive) return;
      facts = d.facts || [];
      render();
    } catch (e) {
      if (!life.alive || e.status === 401) return;
      content.replaceChildren(h('div', { class: 'span-all' }, errorState(e, load)));
    }
  }
  function paintAbout() {
    const cur = about.value;
    const subj = new Map();
    for (const f of facts || []) if (f.subject && !subj.has(f.subject)) subj.set(f.subject, f.subjectLabel || f.subject);
    about.replaceChildren(h('option', { value: '', text: 'About you' }), [...subj].map(([k, v]) => h('option', { value: k, text: `About ${v}` })));
    about.value = [...about.options].some((o) => o.value === cur) ? cur : '';
  }
  const who = (f) => {
    const s = f.source || '';
    if (/^the wearer$/i.test(s)) return `You told ${aiName()}`;
    if (/^confirmed by the wearer/i.test(s)) return 'Confirmed by you';
    return cap(s) || 'Unknown';
  };
  function matches(f) {
    if (!q.trim()) return true;
    const hay = `${f.text} ${f.subjectLabel || ''} ${f.source || ''}`.toLowerCase();
    return q.toLowerCase().split(/\s+/).filter(Boolean).every((w) => hay.includes(w));
  }
  function render() {
    paintAbout();
    if (!facts) return;
    if (!facts.length) {
      content.replaceChildren(h('div', { class: 'card span-all' }, emptyState('book', `${aiName()} doesn’t remember anything yet`,
        'Tell it something above, or just say “remember that…” to the device.')));
      return;
    }
    const shown = facts.filter(matches);
    if (!shown.length) {
      content.replaceChildren(h('div', { class: 'span-all' }, emptyState('search', `Nothing matches “${q.trim()}”`, 'The filter looks at the fact, who it’s about, and who said it.')));
      return;
    }
    const claims = shown.filter((f) => f.trust === 'claimed');
    const known = shown.filter((f) => f.trust !== 'claimed');
    const mine = known.filter((f) => !f.subject);
    const bySubj = new Map();
    for (const f of known) {
      if (!f.subject) continue;
      if (!bySubj.has(f.subject)) bySubj.set(f.subject, { label: f.subjectLabel || f.subject, facts: [] });
      bySubj.get(f.subject).facts.push(f);
    }
    const out = [];
    if (claims.length) {
      out.push(h('section', { class: 'card span-all' }, cardHead('Needs review', 'shield', h('span', { class: 'badge b-warn', text: fmtN(claims.length) })),
        h('p', { class: 'hint', style: 'margin:-4px 0 12px', text: `Callers said these about themselves. ${aiName()} treats them as claims until you confirm them.` }),
        claims.map((f) => h('div', { class: 'claim' },
          h('div', { class: 'claim-who' }, icon('user'), `${cap(f.source || 'A caller')} said${f.subjectLabel ? ` · about ${f.subjectLabel}` : ''} · ${rel(parseT(f.at))}`),
          h('p', { class: 'claim-text', text: f.text }),
          h('div', { class: 'claim-actions' },
            h('button', { class: 'btn btn-sm btn-primary', type: 'button', onclick: () => confirmFact(f) }, icon('check'), 'Confirm'),
            h('button', { class: 'btn btn-sm btn-ghost', type: 'button', onclick: () => forget(f, true) }, 'Discard'))))));
    }
    const factList = (fs) => h('div', { class: 'facts' }, fs.map((f) => h('div', { class: 'fact' },
      h('div', { class: 'fact-main' }, h('p', { class: 'fact-text', text: f.text }), h('p', { class: 'fact-meta', text: `${who(f)} · ${rel(parseT(f.at))}` })),
      h('button', { class: 'icon-btn danger', type: 'button', 'aria-label': `Forget: ${f.text.slice(0, 60)}`, title: 'Forget', onclick: () => forget(f) }, icon('trash')))));
    out.push(h('section', { class: 'card' }, cardHead('About you', 'user', h('span', { class: 'card-sub', text: fmtN(mine.length) })),
      mine.length ? factList(mine) : h('p', { class: 'muted', text: q ? 'Nothing here matches.' : 'Nothing yet.' })));
    for (const [key, g] of bySubj) {
      out.push(h('section', { class: 'card' }, cardHead(g.label, null, linkTo('#/calls/' + enc(key), 'Calls')),
        h('p', { class: 'hint', style: 'margin:-6px 0 4px', text: 'About this caller' }), factList(g.facts)));
    }
    content.replaceChildren(...out);
  }
  async function addFact() {
    const t = text.value.trim();
    if (!t) return;
    addBtn.disabled = true;
    try {
      const d = await api('/api/memory', { method: 'POST', body: { text: t, about: about.value } });
      if (d.fact && facts) facts.unshift(d.fact);
      text.value = '';
      toast(`${aiName()} will remember that`);
      render();
      if (!d.fact) load();
    } catch (e) {
      if (e.status !== 401) toast(`Couldn’t save: ${e.message}`, 'error');
    } finally { addBtn.disabled = !text.value.trim(); }
  }
  async function confirmFact(f) {
    try {
      await api(`/api/memory/${enc(f.id)}/confirm`, { method: 'POST', body: {} });
      toast(`Confirmed — ${aiName()} will treat it as fact`);
      load();
    } catch (e) { if (e.status !== 401) toast(`Couldn’t confirm: ${e.message}`, 'error'); }
  }
  async function forget(f, isClaim) {
    const ok = await confirmDialog(isClaim
      ? { title: 'Discard this claim?', body: `“${f.text}” — ${aiName()} won’t keep it, even as a claim.`, ok: 'Discard' }
      : { title: 'Forget this?', body: `“${f.text}” — ${aiName()} won’t remember it any more.`, ok: 'Forget' });
    if (!ok) return;
    try {
      await api('/api/memory/' + enc(f.id), { method: 'DELETE' });
      facts = facts.filter((x) => x.id !== f.id);
      toast(isClaim ? 'Claim discarded' : 'Forgotten');
      render();
    } catch (e) { if (e.status !== 401) toast(`Couldn’t remove it: ${e.message}`, 'error'); }
  }
  load();
  return { leave() { life.alive = false; } };
};

/* ============================================================== settings */

const SET_BOOL = new Set(['call_agent_on_duty', 'camera_mirror']);
const SET_INT = new Set(['auto_answer_delay', 'stand_down_after', 'openclaw_port', 'camera_rotation', 'camera_quality', 'watch_font_weight']);
const CAM_KEYS = ['camera_resolution', 'camera_quality', 'camera_rotation', 'camera_mirror', 'camera_aspect_ratio'];
const WF_KEYS = ['watch_font_family', 'watch_font_weight', 'watch_font_size_factor', 'watch_time_x', 'watch_time_y'];
const LIVE = new Set([...CAM_KEYS, ...WF_KEYS, 'mascot']);
function nv(k, v) {
  if (SET_BOOL.has(k)) return v === true || v === 'true';
  if (SET_INT.has(k)) { const n = parseInt(v, 10); return Number.isFinite(n) ? n : null; }
  if (k === 'agent_relay_port') { if (v === '' || v == null) return null; const n = parseInt(v, 10); return Number.isFinite(n) ? n : null; }
  if (k === 'watch_font_size_factor' || k === 'watch_time_x' || k === 'watch_time_y') { const n = parseFloat(v); return Number.isFinite(n) ? Math.round(n * 100) / 100 : null; }
  return v == null ? '' : String(v);
}
function dirtyKeys() {
  const F = S.settings;
  if (!F) return [];
  return Object.keys(F.draft).filter((k) => !LIVE.has(k) && nv(k, F.draft[k]) !== nv(k, F.base[k]));
}

PAGES.settings = function pageSettings(view) {
  setTop({ title: 'Settings' });
  const life = { alive: true };
  const root = h('div', { class: 'settings' });
  let camOn = false, camImg = null, frame = null, camBadge = null, wfBadge = null;
  const pushCam = debounce(() => pushLive('/api/camera', CAM_KEYS, camBadge, () => { if (camOn) startCam(); }), 250);
  const pushWf = debounce(() => pushLive('/api/watchface', WF_KEYS, wfBadge), 150);
  // The character applies at once too; its design card then changes with it.
  const pushMascot = debounce(() => pushLive('/api/settings', ['mascot'], null, reloadAvatar), 60);
  async function reloadAvatar() {
    try { S.avatar = await api('/api/avatar'); } catch (e) { if (e.status === 401) return; }
    if (life.alive) render();
  }

  const saveTxt = h('span');
  const saveBtn = h('button', { class: 'btn btn-primary btn-sm', type: 'button', onclick: save }, 'Save');
  const bar = h('div', { class: 'savebar', role: 'region', 'aria-label': 'Unsaved changes', inert: true },
    h('div', { class: 'savebar-in' }, h('span', { class: 'savebar-text' }, h('span', { class: 'dot warn' }), saveTxt),
      h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onclick: discard }, 'Discard'), saveBtn));
  view.append(root, bar);

  function refreshDirty() {
    const n = dirtyKeys().length;
    bar.classList.toggle('on', n > 0);
    bar.inert = n === 0;
    D.body.classList.toggle('has-savebar', n > 0);
    saveTxt.textContent = n === 1 ? '1 unsaved change' : `${n} unsaved changes`;
  }

  async function load() {
    root.replaceChildren(skel('form'));
    try {
      if (!S.settings || !dirtyKeys().length) {
        const [s, opt, av] = await Promise.all([
          api('/api/settings'),
          api('/api/settings/options').catch((e) => { if (e.status === 401) throw e; return null; }),
          api('/api/avatar').catch((e) => { if (e.status === 401) throw e; return null; }),
        ]);
        if (!life.alive) return;
        S.avatar = av;
        S.settings = { base: { ...s }, draft: { ...s }, options: { models: (opt && opt.models) || [], voices: (opt && opt.voices) || [], mascots: (opt && opt.mascots) || [] } };
      }
      render();
    } catch (e) {
      if (!life.alive || e.status === 401) return;
      root.replaceChildren(errorState(e, load));
    }
  }

  function render() {
    const F = S.settings;
    stopCam();
    const set = (k, v) => {
      F.draft[k] = v;
      if (CAM_KEYS.includes(k)) pushCam();
      else if (WF_KEYS.includes(k)) pushWf();
      else if (k === 'mascot') pushMascot();
      else refreshDirty();
    };

    /* ---- field builders (closures over F) */
    const field = (label, ctl, hint, id, described) => {
      const hid = hint ? id + '-h' : null;
      if (hid) (described || ctl).setAttribute('aria-describedby', hid);
      return h('div', { class: 'field' }, h('label', { class: 'label', for: id, text: label }), ctl, hint && h('p', { class: 'hint', id: hid, text: hint }));
    };
    const fText = (k, label, o = {}) => {
      const id = 's-' + k;
      const inp = h('input', {
        class: 'input' + (o.mono ? ' mono' : ''), id, type: o.secret ? 'password' : 'text', value: F.draft[k] == null ? '' : String(F.draft[k]),
        placeholder: o.placeholder, inputmode: o.inputmode, autocomplete: 'off', autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false',
      });
      inp.addEventListener('input', () => set(k, inp.value));
      if (!o.secret) return field(label, inp, o.hint, id);
      const tg = h('button', { class: 'icon-btn', type: 'button', 'aria-label': `Show ${label}`, 'aria-pressed': 'false' }, icon('eye'));
      tg.addEventListener('click', () => {
        const show = inp.type === 'password';
        inp.type = show ? 'text' : 'password';
        tg.setAttribute('aria-pressed', String(show));
        tg.setAttribute('aria-label', `${show ? 'Hide' : 'Show'} ${label}`);
        tg.replaceChildren(icon(show ? 'eyeOff' : 'eye'));
      });
      inp.classList.add('has-end');
      return field(label, h('div', { class: 'input-wrap' }, inp, tg), o.hint, id, inp);
    };
    const fArea = (k, label, o = {}) => {
      const id = 's-' + k;
      const ta = h('textarea', { class: 'textarea' + (o.tall ? ' tall' : '') + (o.mono ? ' mono' : ''), id, rows: String(o.rows || 4), placeholder: o.placeholder, spellcheck: o.mono ? 'false' : null });
      ta.value = F.draft[k] == null ? '' : String(F.draft[k]);
      ta.addEventListener('input', () => set(k, ta.value));
      return field(label, ta, o.hint, id);
    };
    const fSelect = (k, label, opts, o = {}) => {
      const id = 's-' + k;
      const cur = String(F.draft[k] == null ? '' : F.draft[k]);
      const all = opts.some((x) => String(x.value) === cur) ? opts : [...opts, { value: cur, label: cur }];
      const sel = h('select', { class: 'select', id }, all.map((x) => h('option', { value: String(x.value), text: x.label })));
      sel.value = cur;
      sel.addEventListener('change', () => { set(k, sel.value); if (o.onChange) o.onChange(sel.value); });
      return field(label, sel, o.hint, id);
    };
    const fSwitch = (k, label, hint, onToggle, value) => {
      const id = 's-' + k;
      const on = value != null ? value : nv(k, F.draft[k]);
      const sw = h('button', { class: 'switch', id, type: 'button', role: 'switch', 'aria-checked': String(!!on), 'aria-describedby': hint ? id + '-h' : null });
      sw.addEventListener('click', () => {
        const v = sw.getAttribute('aria-checked') !== 'true';
        sw.setAttribute('aria-checked', String(v));
        if (onToggle) onToggle(v); else set(k, v);
      });
      return h('div', { class: 'switch-row' }, h('div', { class: 'field-text' }, h('label', { class: 'label', for: id, text: label }),
        hint && h('span', { class: 'hint', id: id + '-h', text: hint })), sw);
    };
    const fRadio = (k, label, opts, hint) => {
      const name = 's-' + k;
      const list = h('div', { class: 'radio-list' });
      opts.forEach((o) => {
        const inp = h('input', { type: 'radio', name, value: o.value, checked: F.draft[k] === o.value });
        inp.addEventListener('change', () => {
          list.querySelectorAll('.radio').forEach((x) => x.classList.toggle('is-on', x.querySelector('input').checked));
          set(k, o.value);
        });
        list.append(h('label', { class: 'radio' + (F.draft[k] === o.value ? ' is-on' : '') }, inp, h('span', { class: 'rmark' }),
          h('span', null, h('span', { class: 'radio-title', text: o.label }), o.desc && h('span', { class: 'radio-desc', text: o.desc }))));
      });
      return h('fieldset', { class: 'field', style: 'border:0;margin:0;padding:0;min-width:0', 'aria-describedby': hint ? name + '-h' : null },
        h('legend', { class: 'label', style: 'padding:0;margin-bottom:6px', text: label }), list, hint && h('p', { class: 'hint', id: name + '-h', text: hint }));
    };
    const fSeg = (k, label, opts, onChange) => {
      const id = 's-' + k;
      const cur = String(F.draft[k]);
      const seg = h('div', { class: 'seg', role: 'group', 'aria-labelledby': id + '-l' }, opts.map((o) => h('button', {
        type: 'button', 'aria-pressed': String(String(o.value) === cur), onclick: () => {
          seg.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', String(b === btnOf(o))));
          set(k, o.value);
          if (onChange) onChange(o.value);
        }, 'data-v': String(o.value),
      }, o.label)));
      const btnOf = (o) => seg.querySelector(`[data-v="${String(o.value).replace(/"/g, '')}"]`);
      return h('div', { class: 'field' }, h('span', { class: 'label', id: id + '-l', text: label }), seg);
    };
    const fRange = (k, label, o) => {
      const id = 's-' + k;
      const val = nv(k, F.draft[k]) != null ? nv(k, F.draft[k]) : o.def;
      const inp = h('input', { type: 'range', id, min: String(o.min), max: String(o.max), step: String(o.step), value: String(val), 'aria-valuetext': o.fmt(val) });
      const out = h('output', { class: 'range-val', for: id, text: o.fmt(val) });
      const paintP = () => inp.style.setProperty('--p', `${((+inp.value - o.min) / (o.max - o.min)) * 100}%`);
      paintP();
      inp.addEventListener('input', () => {
        const v = +inp.value;
        out.textContent = o.fmt(v);
        inp.setAttribute('aria-valuetext', o.fmt(v));
        paintP();
        set(k, v);
      });
      return field(label, h('div', { class: 'range-row' }, inp, out), o.hint, id, inp);
    };
    const sectionCard = (title, ic, sub, ...kids) => h('section', { class: 'card set-card' }, cardHead(title, ic), sub && h('p', { class: 'card-sub', text: sub }), kids);

    /* ---- Assistant */
    const models = F.options.models.map((m) => ({ value: m.value, label: m.label || m.value }));
    const curModel = String(F.draft.gemini_model || '');
    const modelSel = h('select', { class: 'select', id: 's-gemini_model' },
      models.map((m) => h('option', { value: m.value, text: m.label })));
    // The device only keeps a model it offers, so this matches after a load.
    modelSel.value = models.some((m) => m.value === curModel) ? curModel : (models[0] ? models[0].value : '');
    modelSel.addEventListener('change', () => set('gemini_model', modelSel.value));
    const modelHint = h('p', { class: 'hint', text: `Extended Thinking reasons in the background while ${aiName()} talks — better on multi-step tasks, slower to finish them. Phone calls always use 3.8 Live.` });
    const voices = F.options.voices.map((v) => ({ value: v.name, label: v.style ? `${v.name} — ${v.style}` : v.name }));

    const assistant = sectionCard('Assistant', 'sparkle', null,
      fText('gemini_api_key', 'Gemini API key', { secret: true, mono: true, placeholder: 'AIza…', hint: `Kept on the device. ${aiName()} uses it to reach Gemini Live.` }),
      h('div', { class: 'field' }, h('label', { class: 'label', for: 's-gemini_model', text: 'Model' }), modelSel, modelHint),
      fSelect('gemini_voice', 'Voice', voices, { hint: `How ${aiName()} sounds, on the device and on calls.` }),
      fSelect('stand_down_after', 'Stand down after', [1, 2, 5, 10].map((m) => ({ value: String(m), label: m === 1 ? '1 minute of quiet' : `${m} minutes of quiet` })),
        { hint: `Then the conversation ends and ${aiName()} keeps its key points. Shorter costs less; the next hold takes a second or two longer to answer.` }));

    /* ---- Prompts */
    const persona = sectionCard('AI Persona', 'user', null,
      fText('assistant_name', 'Name', { placeholder: 'FOX-1',
        hint: 'What your assistant is called — on the device, here in FOX-1 Hub, and on calls.' }),
      fArea('ai_persona', 'Who the assistant is', { rows: 4, placeholder: 'You are {name}, an AI assistant. You are…',
        hint: 'Character. Used by the device assistant AND when answering phone calls. Write {name} for its name, so a rename reaches it.' }));
    const sysPrompt = sectionCard('System Prompt', 'sliders', null,
      fArea('system_prompt', 'Custom instructions', { tall: true, rows: 10, placeholder: 'System prompt for the AI…',
        hint: 'Instructions for the device assistant only — never sent to the call agent. {name} becomes its name.' }));
    const profile = sectionCard('About you', 'user', null,
      fArea('user_profile', 'User profile', { rows: 4, placeholder: 'Name, preferences, context about yourself…',
        hint: 'Shared with the device assistant and with the call agent.' }));

    /* ---- Phone calls */
    const calls = sectionCard('Phone calls', 'phone', null,
      fSwitch('call_agent_on_duty', 'Call agent on duty', 'On — connects the board and takes calls. Holds the Bluetooth link and a wake lock. Off by default.'),
      h('div', { class: 'divider' }),
      fText('call_agent_device', 'Board address', { mono: true, placeholder: '34:5F:45:04:FB:1E', hint: 'The ESP32 call bridge. Pair it first.' }),
      h('div', { style: 'height:16px' }),
      fRadio('auto_answer_mode', 'Pick up incoming calls', [
        { value: 'off', label: 'Never — I answer my own phone' },
        { value: 'known', label: 'Only callers already on file' },
        { value: 'everyone', label: 'Anyone not blocked' },
      ], 'The agent answers on your behalf and introduces itself as an AI. Off by default.'),
      h('div', { style: 'height:16px' }),
      fRange('auto_answer_delay', 'Let it ring first', { min: 2, max: 30, step: 1, def: 6, fmt: (v) => `${v} s`,
        hint: 'Never zero — you always get the chance to answer it yourself.' }),
      h('div', { style: 'height:16px' }),
      fArea('auto_answer_blocked', 'Never answer these', { rows: 2, mono: true, placeholder: '0200000001, 0209999999', hint: 'Wins over everything below.' }),
      h('div', { style: 'height:16px' }),
      fArea('auto_answer_always', 'Always answer these', { rows: 2, mono: true, placeholder: '0200000003', hint: 'Answered even if they are not on file.' }),
      h('div', { class: 'divider' }),
      fArea('call_agent_prompt', 'Call Agent — phone call instructions', { tall: true, rows: 12, placeholder: 'How to behave when answering the phone…',
        hint: 'The only instructions a caller’s session sees. Persona and User Profile are added automatically; the System Prompt above is not.' }));

    /* ---- Agent */
    const oc = h('div', { class: 'sub-fields', hidden: F.draft.agent_provider_type === 'agentRelay' },
      fText('openclaw_host', 'Host', { mono: true, placeholder: 'http://192.168.1.42' }),
      fText('openclaw_port', 'Port', { mono: true, inputmode: 'numeric', placeholder: '18789' }),
      fText('openclaw_token', 'Token', { secret: true, mono: true }));
    const ar = h('div', { class: 'sub-fields', hidden: F.draft.agent_provider_type !== 'agentRelay' },
      fText('agent_relay_host', 'Host', { mono: true, placeholder: 'http://192.168.1.42' }),
      fText('agent_relay_port', 'Port (optional)', { mono: true, inputmode: 'numeric', placeholder: 'Leave empty if none' }),
      fText('agent_relay_token', 'Token', { secret: true, mono: true }));
    const agent = sectionCard('Agent', 'code', `Where ${aiName()} sends tasks it can’t do on the device.`,
      fSeg('agent_provider_type', 'Provider', [{ value: 'openClaw', label: 'OpenClaw' }, { value: 'agentRelay', label: 'Agent Relay' }], (v) => {
        oc.hidden = v === 'agentRelay';
        ar.hidden = v !== 'agentRelay';
      }), oc, ar);

    /* ---- Camera (live) */
    camBadge = h('span', { class: 'badge b-accent live-badge', text: 'Applied live' });
    frame = h('div', { class: 'cam-frame', hidden: true });
    const camera = h('section', { class: 'card set-card' }, cardHead('Camera', 'camera', camBadge),
      h('p', { class: 'card-sub', text: 'Changes go to the device as you make them. Use the preview to line the lens up.' }),
      fSwitch('cam_preview', 'Live preview', 'Streams from the device camera while it’s on.', (v) => {
        camOn = v;
        frame.hidden = !v;
        if (v) startCam(); else stopCam();
      }, camOn),
      frame,
      h('div', { style: 'height:16px' }),
      fSelect('camera_resolution', 'Resolution', [{ value: 'low', label: 'Low (240p)' }, { value: 'medium', label: 'Medium (480p)' }, { value: 'high', label: 'High (720p)' }]),
      fRange('camera_quality', 'JPEG quality', { min: 10, max: 100, step: 5, def: 70, fmt: (v) => String(v) }),
      fSeg('camera_rotation', 'Rotation', [0, 90, 180, 270].map((v) => ({ value: v, label: `${v}°` }))),
      h('div', { style: 'height:8px' }),
      fSwitch('camera_mirror', 'Mirror', 'Flip the picture horizontally.'),
      h('div', { style: 'height:8px' }),
      fSelect('camera_aspect_ratio', 'Aspect ratio', [{ value: 'original', label: 'Original' }, { value: 'landscape', label: 'Landscape (4:3)' },
        { value: 'portrait', label: 'Portrait (3:4)' }, { value: 'square', label: 'Square (1:1)' }]));

    /* ---- Mascot */
    const mascots = (F.options.mascots || []).map((m) => ({ value: m.value, label: m.label || m.value }));
    // A design from the avatar web tool ("Settings for the app" downloads
    // avatar-settings.json). Sent at once rather than through the save bar:
    // it is a whole file, not a field.
    const designFile = h('input', { type: 'file', accept: '.json,application/json', hidden: true });
    designFile.addEventListener('change', async () => {
      const f = designFile.files && designFile.files[0];
      designFile.value = '';
      if (!f) return;
      let params;
      try { params = JSON.parse(await f.text()); } catch (_) { toast('That file is not an avatar design.', 'error'); return; }
      try {
        const r = await api('/api/avatar', { method: 'POST', body: { params } });
        toast('Design loaded on the device');
        if (r.mascot) { F.base.mascot = r.mascot; F.draft.mascot = r.mascot; }
        reloadAvatar();
      } catch (e) { if (e.status !== 401) toast(e.message, 'error'); }
    });
    const resetDesign = async () => {
      if (!(await confirmDialog({ title: 'Reset the design?', body: 'The mascot goes back to its default colours, shape and motion.', ok: 'Reset' }))) return;
      try { await api('/api/avatar', { method: 'POST', body: { reset: true } }); toast('Design reset'); reloadAvatar(); }
      catch (e) { if (e.status !== 401) toast(e.message, 'error'); }
    };
    const mascot = sectionCard('Mascot', 'sparkle', `The character on the watch face, the AI screen and the app list. It follows what ${aiName()} is doing — listening, thinking, speaking.`,
      fSelect('mascot', 'Character', mascots.length ? mascots : [{ value: 'bloub', label: 'Bloub' }, { value: 'fox', label: 'Fox' }]),
      h('div', { class: 'field' },
        h('label', { class: 'label', text: 'Design' }),
        h('div', { style: 'display:flex;gap:8px;flex-wrap:wrap' },
          h('button', { class: 'btn', type: 'button', onclick: () => designFile.click() }, 'Load design…'),
          h('button', { class: 'btn btn-quiet', type: 'button', onclick: resetDesign }, 'Reset design')),
        h('p', { class: 'hint', text: 'Bloub and the fox only. In the avatar design tool, use “Settings for the app” and load the file it saves — or fine-tune it below.' }),
        designFile));

    /* ---- Mascot design (live) — built from the device's own description of
       every setting, so nothing here has to be kept in step with it */
    const designBadge = h('span', { class: 'badge b-accent live-badge', text: 'Applied live' });
    const pending = {};
    const pushDesign = debounce(async () => {
      const changes = { ...pending };
      for (const k of Object.keys(pending)) delete pending[k];
      if (!Object.keys(changes).length) return;
      try {
        const r = await api('/api/avatar', { method: 'POST', body: { changes } });
        if (S.avatar && r.params) S.avatar.params = r.params;
        if (designBadge.isConnected) {
          designBadge.textContent = 'Updated';
          clearTimeout(designBadge._t);
          designBadge._t = setTimeout(() => { designBadge.textContent = 'Applied live'; }, 1500);
        }
      } catch (e) { if (e.status !== 401) toast(e.message, 'error'); }
    }, 120);
    const setDesign = (k, v) => { if (S.avatar) S.avatar.params[k] = v; pending[k] = v; pushDesign(); };
    const dControl = (sp) => {
      const id = 'd-' + sp.key, cur = S.avatar.params[sp.key];
      if (sp.kind === 'toggle') return fSwitch('d_' + sp.key, sp.label, sp.help, (v) => setDesign(sp.key, v), !!cur);
      let ctl;
      if (sp.kind === 'color') {
        ctl = h('input', { class: 'input', type: 'color', id, value: String(cur || '#000000'), style: 'height:44px;padding:4px;cursor:pointer' });
        ctl.addEventListener('input', () => setDesign(sp.key, ctl.value));
      } else if (sp.kind === 'choice') {
        ctl = h('select', { class: 'select', id }, sp.choices.map((c) => h('option', { value: c.value, text: c.label })));
        ctl.value = String(cur);
        ctl.addEventListener('change', () => setDesign(sp.key, ctl.value));
      } else {
        const places = sp.step >= 1 ? 0 : sp.step >= 0.1 ? 1 : 2;
        const fmt = (v) => `${(+v).toFixed(places)}${sp.unit ? (sp.unit === '°' ? '°' : ' ' + sp.unit) : ''}`;
        const inp = h('input', { type: 'range', id, min: String(sp.min), max: String(sp.max), step: String(sp.step), value: String(cur) });
        const out = h('output', { class: 'range-val', for: id, text: fmt(cur) });
        const paint = () => inp.style.setProperty('--p', `${((+inp.value - sp.min) / (sp.max - sp.min)) * 100}%`);
        paint();
        inp.addEventListener('input', () => { out.textContent = fmt(inp.value); paint(); setDesign(sp.key, +inp.value); });
        ctl = h('div', { class: 'range-row' }, inp, out);
      }
      return h('div', { class: 'field' }, h('label', { class: 'label', for: id, text: sp.label }), ctl, h('p', { class: 'hint', text: sp.help }));
    };
    const palettes = () => h('div', { style: 'display:flex;gap:8px;flex-wrap:wrap;margin:4px 0 12px' },
      (S.avatar.palettes || []).map((pal, i) => h('button', {
        class: 'btn btn-sm', type: 'button', title: pal.name,
        onclick: async () => {
          try {
            const r = await api('/api/avatar', { method: 'POST', body: { palette: i } });
            S.avatar.params = r.params;
            render();
          } catch (e) { if (e.status !== 401) toast(e.message, 'error'); }
        },
      }, h('span', { 'aria-hidden': 'true', style: `display:inline-block;width:16px;height:16px;border-radius:50%;margin-right:6px;vertical-align:-3px;background:${pal.body};box-shadow:0 0 0 3px ${pal.bg},0 0 0 4px rgba(255,255,255,.25)` }), pal.name)));
    let design;
    if (!S.avatar) {
      design = h('section', { class: 'card set-card' }, cardHead('Mascot design', 'sparkle'),
        h('p', { class: 'card-sub', text: 'The device did not send its design settings. Reopen this page to try again.' }));
    } else {
      const who = S.avatar.params.character;
      const groups = (S.avatar.groups || []).map((g) => {
        const specs = S.avatar.specs.filter((sp) => sp.group === g && sp[who] !== false);
        if (!specs.length) return null;
        return h('details', { class: 'set-group', open: g === 'Colour', style: 'border-top:1px solid var(--line, rgba(255,255,255,.08));padding:8px 0' },
          h('summary', { style: 'cursor:pointer;font-weight:600;padding:8px 0;min-height:32px' }, g),
          g === 'Colour' ? palettes() : null,
          specs.map(dControl));
      });
      design = h('section', { class: 'card set-card' }, cardHead('Mascot design', 'sparkle', designBadge),
        h('p', { class: 'card-sub', text: `Every setting of ${who === 'fox' ? 'the fox' : 'Bloub'}. Look at the device while you change them — they apply straight away.` }),
        groups);
    }

    /* ---- Watch face (live) */
    wfBadge = h('span', { class: 'badge b-accent live-badge', text: 'Applied live' });
    const watchface = h('section', { class: 'card set-card' }, cardHead('Watch face', 'type', wfBadge),
      h('p', { class: 'card-sub', text: 'Look at the device while you adjust — it updates straight away.' }),
      fSelect('watch_font_family', 'Font', ['Rajdhani', 'Space Grotesk', 'Outfit', 'Orbitron', 'Exo 2', 'Chakra Petch'].map((f) => ({ value: f, label: f }))),
      fSelect('watch_font_weight', 'Weight', [[100, 'Thin'], [300, 'Light'], [400, 'Regular'], [500, 'Medium'], [600, 'SemiBold'], [700, 'Bold'], [800, 'ExtraBold']]
        .map(([v, l]) => ({ value: v, label: `${l} (${v})` }))),
      fRange('watch_font_size_factor', 'Clock size', { min: 0.08, max: 0.5, step: 0.01, def: 0.35, fmt: (v) => `${Math.round(v * 100)}%`, hint: 'Share of the screen the time takes up.' }),
      fRange('watch_time_x', 'Time across', { min: 0, max: 1, step: 0.01, def: 0.5, fmt: (v) => `${Math.round(v * 100)}%`, hint: 'Bloub and the fox: where the time sits, from the left edge.' }),
      fRange('watch_time_y', 'Time down', { min: 0, max: 1, step: 0.01, def: 0.74, fmt: (v) => `${Math.round(v * 100)}%`, hint: 'Bloub and the fox: where the time sits, from the top.' }));

    root.replaceChildren(assistant, persona, sysPrompt, profile, permissionsCard(), calls, agent, camera, mascot, design, watchface);
    if (camOn) { frame.hidden = false; startCam(); }
    refreshDirty();
  }

  async function pushLive(path, keys, badge, after) {
    const F = S.settings;
    if (!F) return;
    const body = {};
    for (const k of keys) { const v = nv(k, F.draft[k]); if (v !== nv(k, F.base[k])) body[k] = v; }
    if (!Object.keys(body).length) return;
    try {
      await api(path, { method: 'POST', body });
      Object.assign(F.base, body);
      if (badge && badge.isConnected) {
        badge.textContent = 'Updated';
        clearTimeout(badge._t);
        badge._t = setTimeout(() => { badge.textContent = 'Applied live'; }, 1500);
      }
      if (after) after();
    } catch (e) {
      if (e.status !== 401) toast(e.status === 0 ? 'Couldn’t reach the device — change not applied' : `Couldn’t apply: ${e.message}`, 'error');
    }
  }
  function startCam() {
    if (!frame) return;
    stopCam(true);
    camImg = h('img', { alt: 'Live view from the device camera', src: '/api/camera/stream?t=' + Date.now() });
    camImg.addEventListener('error', () => {
      if (!camImg) return;
      frame.replaceChildren(h('div', null, icon('camera'), 'Couldn’t open the camera stream.'));
      camImg = null;
    });
    frame.replaceChildren(camImg);
  }
  function stopCam(keep) {
    if (camImg) {
      const img = camImg;
      camImg = null;
      img.src = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';
      img.remove();
    }
    if (!keep && frame) frame.replaceChildren();
  }
  const onVis = () => {
    if (D.visibilityState === 'hidden') stopCam();
    else if (camOn && !camImg) startCam();
  };
  D.addEventListener('visibilitychange', onVis);

  async function save() {
    const F = S.settings;
    const keys = dirtyKeys();
    if (!keys.length) return;
    const d = F.draft;
    const fail = (msg, id) => { toast(msg, 'error'); const el = D.getElementById(id); if (el) el.focus(); };
    const port = (k, optional) => {
      const raw = String(d[k] == null ? '' : d[k]).trim();
      if (optional && raw === '') return true;
      return /^\d+$/.test(raw) && +raw >= 1 && +raw <= 65535;
    };
    if (keys.includes('openclaw_port') && !port('openclaw_port')) return fail('The OpenClaw port must be a number from 1 to 65535.', 's-openclaw_port');
    if (keys.includes('agent_relay_port') && !port('agent_relay_port', true)) return fail('The Agent Relay port must be a number from 1 to 65535, or empty.', 's-agent_relay_port');
    const body = {};
    for (const k of keys) body[k] = nv(k, d[k]);
    if ('auto_answer_delay' in body) body.auto_answer_delay = Math.max(2, Math.min(30, body.auto_answer_delay || 6));
    saveBtn.disabled = true;
    saveBtn.textContent = 'Saving…';
    try {
      await api('/api/settings', { method: 'POST', body });
      Object.assign(F.base, body);
      Object.assign(F.draft, body);
      if ('assistant_name' in body) learnName(body.assistant_name || 'FOX-1');
      toast(keys.length === 1 ? 'Setting saved' : 'Settings saved');
      refreshDirty();
    } catch (e) {
      if (e.status !== 401) toast(e.status === 0 ? 'Couldn’t reach your device — nothing was saved.' : `Couldn’t save: ${e.message}`, 'error');
    } finally {
      saveBtn.disabled = false;
      saveBtn.textContent = 'Save';
    }
  }
  function discard() {
    const F = S.settings;
    if (!F) return;
    for (const k of Object.keys(F.draft)) if (!LIVE.has(k)) F.draft[k] = F.base[k];
    render();
    toast('Changes discarded');
  }

  load();
  return {
    async canLeave() {
      const n = dirtyKeys().length;
      if (!n) return true;
      const ok = await confirmDialog({ title: 'Leave without saving?', body: `You have ${n === 1 ? 'an unsaved change' : `${n} unsaved changes`} in Settings.`, ok: 'Discard changes' });
      if (ok) { const F = S.settings; for (const k of Object.keys(F.draft)) if (!LIVE.has(k)) F.draft[k] = F.base[k]; }
      return ok;
    },
    leave() {
      life.alive = false;
      stopCam();
      pushCam.cancel();
      pushWf.cancel();
      D.removeEventListener('visibilitychange', onVis);
      D.body.classList.remove('has-savebar');
    },
  };
};

/* ================================================================ system */

PAGES.system = function pageSystem(view) {
  setTop({ title: desk.matches ? 'System' : 'More' });
  const life = { alive: true };
  const portalCard = h('section', { class: 'card' }, cardHead('FOX-1 Hub', 'wifi'), skel('rows'));
  const watchCard = h('section', { class: 'card' }, cardHead('Device', 'watch'), skel('rows'));
  const pages = h('section', { class: 'card mobile-only', style: 'padding:8px' }, h('div', { class: 'list', style: 'margin:0' },
    lrow({ href: '#/settings', ic: 'sliders', title: 'Settings', sub: 'Assistant, calls, camera, watch face' }),
    lrow({ href: '#/memory', ic: 'book', title: 'Memory', sub: `What ${aiName()} remembers` }),
    lrow({ href: '#/calls', ic: 'phone', title: 'Calls', sub: 'What the call agent handled' })));
  const dev = h('section', { class: 'card' }, cardHead('Developer', 'code'),
    h('p', { class: 'hint', style: 'margin:-4px 0 8px', text: 'Diagnostic pages on the device. They open in a new tab.' }),
    h('div', { class: 'list' },
      lrow({ href: '/logs', target: '_blank', ic: 'list', title: 'Live log', sub: 'What the device is logging, live' }),
      lrow({ href: '/api/logs/files', target: '_blank', ic: 'clock', title: 'Saved logs', sub: 'Earlier sessions, kept on disk' }),
      lrow({ href: '/ring', target: '_blank', ic: 'ring', title: 'Ring console', sub: 'Every ring command as a button' }),
      lrow({ href: '/api/bridge/recordings', target: '_blank', ic: 'mic', title: 'Call-bridge recordings', sub: 'Test recordings from the call bridge' })));
  view.append(h('div', { class: 'page' }, pages, h('div', { class: 'sys-grid' }, portalCard, watchCard, backupCard(), dev),
    h('p', { class: 'hint', style: 'text-align:center;margin-top:8px', text: 'FOX-1 Hub' })));

  async function load() {
    try {
      const o = await api('/api/overview');
      if (!life.alive) return;
      S.overview = o;
      paintSideFoot();
      paint(o);
    } catch (e) {
      if (!life.alive || e.status === 401) return;
      portalCard.replaceChildren(cardHead('FOX-1 Hub', 'wifi'), errorState(e, load), portalButtons());
      watchCard.replaceChildren(cardHead('Device', 'watch'), errorState(e, load));
    }
  }
  function portalButtons() {
    return h('div', { class: 'btn-row' },
      h('button', { class: 'btn btn-danger', type: 'button', onclick: stop }, icon('power'), 'Turn off FOX-1 Hub'),
      h('button', { class: 'btn btn-ghost', type: 'button', onclick: signOut }, icon('logout'), 'Sign out'));
  }
  function paint(o) {
    const p = o.portal || {}, w = o.watch || {}, r = o.ring || {}, a = o.assistant || {};
    const closes = parseT(p.closesAt);
    const addr = p.address || location.origin;
    portalCard.replaceChildren(cardHead('FOX-1 Hub', 'wifi', h('span', { class: 'badge b-ok' }, h('span', { class: 'dot ok', style: 'width:6px;height:6px;box-shadow:none' }), 'On')),
      h('div', { class: 'addr' }, h('span', { text: addr }),
        h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Copy address', onclick: async () => {
          const ok = await copyText(addr);
          toast(ok ? 'Address copied' : 'Couldn’t copy the address', ok ? 'ok' : 'error');
        } }, icon('copy'))),
      h('p', { class: 'hint', style: 'margin-top:12px', text: closes
        ? `Closes at ${fmtTime(closes)} unless it’s used before then — it turns itself off after 30 minutes without a visit. Signing out doesn’t turn it off.`
        : 'It turns itself off after 30 minutes without a visit.' }),
      portalButtons());
    const ls = parseT(r.lastSync);
    const kv = (k, v, sub) => h('div', null, h('dt', { text: k }), h('dd', null, v, sub && h('small', { text: ' ' + sub })));
    watchCard.replaceChildren(cardHead('Device', 'watch'),
      h('dl', { class: 'kv' },
        kv('Battery', w.battery != null ? `${w.battery}%` : '–', w.charging ? 'charging' : ''),
        kv('Ring', !r.paired ? 'Not paired' : { ready: 'Connected', connecting: 'Connecting', idle: 'Not connected' }[r.link] || cap(r.link || '–'),
          r.paired && r.battery != null ? `${r.battery}%` : ''),
        kv('Model', modelName(a.model) || '–'),
        kv('Voice', a.voice || '–')),
      r.paired && h('p', { class: 'hint', style: 'margin-top:12px', text: [r.name, ls ? `last synced ${rel(ls)}` : null, r.lastSyncSummary].filter(Boolean).join(' · ') }));
  }
  async function stop() {
    const ok = await confirmDialog({ title: 'Turn off FOX-1 Hub?', body: 'This page stops working straight away, on every device signed in. To open it again, turn FOX-1 Hub on from your device.', ok: 'Turn off' });
    if (!ok) return;
    try {
      await api('/api/portal/stop', { method: 'POST', body: {} });
      portalOff();
    } catch (e) {
      if (e.status === 0) portalOff(); // the device closed the connection as it went
      else if (e.status !== 401) toast(`Couldn’t turn it off: ${e.message}`, 'error');
    }
  }
  load();
  return { leave() { life.alive = false; } };
};

async function signOut() {
  try { await api('/api/logout', { method: 'POST', body: {}, auth: false }); } catch (_) { /* signed out either way */ }
  S.authed = false;
  S.settings = null;
  S.overview = null;
  S.loginNote = 'You’re signed out. Enter the PIN to sign back in.';
  S.returnTo = '#/home';
  S.force = true;
  paintSideFoot();
  replaceTo('#/login');
}

/* ================================================================== boot */

async function boot() {
  decorateShell();
  // A new QR code scanned into a tab that is already open is only a hash
  // change, not a page load: start over so the PIN in it is used.
  window.addEventListener('hashchange', () => {
    if (/(?:^|[#&?/])pin=\d{6}(?!\d)/.test(location.hash)) { location.reload(); return; }
    route();
  });
  window.addEventListener('beforeunload', (e) => { if (dirtyKeys().length) { e.preventDefault(); e.returnValue = ''; } });
  desk.addEventListener && desk.addEventListener('change', () => { if (S.cur && S.cur.name === 'system') setTop({ title: desk.matches ? 'System' : 'More' }); });

  // The QR code on the device carries the PIN in the fragment; take it out of
  // the address bar before anything else happens.
  const m = /(?:^|[#&?/])pin=(\d{6})(?!\d)/.exec(location.hash);
  if (m) {
    history.replaceState(null, '', location.pathname + location.search + '#/home');
    try {
      await api('/api/auth', { method: 'POST', body: { pin: m[1] }, auth: false });
      S.authed = true;
    } catch (e) {
      if (e.status === 0) return unreachable();
      if (e.status === 429) S.lockFor = (e.body && e.body.retryIn) || 60;
      else S.loginNote = 'That code has expired — the PIN is new each time FOX-1 Hub is turned on. Enter the one on your device.';
    }
  } else {
    try {
      await api('/api/session', { auth: false });
      S.authed = true;
    } catch (e) {
      if (e.status === 0) return unreachable();
    }
  }
  if (S.authed) await loadSetup();
  hideBoot();
  route();
  if (S.authed) refreshOverview();
}

boot();
})();

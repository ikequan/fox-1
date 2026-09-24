/// `/ring` — drive the smart ring from a phone or laptop browser while the
/// Smart Ring screen is open on the device. Buttons post to `/api/ring/send`
/// (opcode + payload hex) or `/api/ring/action`; the log is `/api/logs?q=RING`.
///
/// Raw string: the `$` in the script must not be Dart interpolation.
const ringConsoleHtml = r'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ring console</title>
<style>
:root{--bg:#0a0a0a;--card:#151515;--line:#262626;--text:#e8e8e8;--dim:#8a8a8a;
  --accent:#00e5cc;--bad:#ff6b6b;--warn:#ffb74d}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);
  font:14px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:10px;
  padding:12px 16px;background:rgba(10,10,10,.92);backdrop-filter:blur(6px);
  border-bottom:1px solid var(--line)}
h1{font-size:16px;margin:0;font-weight:600}
.pill{margin-left:auto;font-size:12px;padding:3px 10px;border-radius:99px;
  border:1px solid var(--line);color:var(--dim)}
.pill.on{color:var(--accent);border-color:var(--accent)}
.pill.off{color:var(--bad);border-color:var(--bad)}
main{display:grid;gap:14px;padding:14px 16px 90px;max-width:1280px;margin:0 auto}
@media(min-width:900px){main{grid-template-columns:minmax(0,1fr) minmax(0,1fr);
  align-items:start}#logcard{position:sticky;top:64px}}
section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
h2{font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--dim);
  margin:0 0 10px;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(112px,1fr));gap:8px}
button{font:inherit;color:var(--text);background:#1f1f1f;border:1px solid var(--line);
  border-radius:9px;padding:10px 8px;cursor:pointer;min-height:42px}
button:hover{border-color:#3a3a3a}
button:active{transform:translateY(1px)}
button.primary{border-color:var(--accent);color:var(--accent)}
button small{display:block;color:var(--dim);font-size:11px;font-family:ui-monospace,monospace}
.days{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px}
.days button{min-height:34px;padding:6px 12px;flex:1 0 auto}
.days button.sel{background:#10302b;border-color:var(--accent);color:var(--accent)}
.note{color:var(--dim);font-size:12px;margin:8px 0 0}
form{display:flex;gap:8px;flex-wrap:wrap}
input{font:14px ui-monospace,monospace;color:var(--text);background:#0f0f0f;
  border:1px solid var(--line);border-radius:9px;padding:10px;min-width:0}
#op{width:80px}#payload{flex:1 1 160px}
#log{height:52vh;overflow:auto;margin:0;padding:10px;background:#0c0c0c;
  border:1px solid var(--line);border-radius:9px;
  font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;
  word-break:break-word;color:#bdbdbd}
.logbar{display:flex;gap:10px;align-items:center;margin-bottom:8px;color:var(--dim);
  font-size:12px}
.logbar label{display:flex;gap:6px;align-items:center}
#toast{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:3;
  padding:10px 16px;border-radius:10px;background:#1f1f1f;border:1px solid var(--line);
  max-width:92vw;font-size:13px}
#toast.ok{border-color:var(--accent)}#toast.bad{border-color:var(--bad)}
</style></head><body>
<header><h1>Ring console</h1><span id="status" class="pill">…</span></header>
<main>
<div style="display:grid;gap:14px">

<section><h2>Device</h2><div class="grid">
  <button data-op="06" data-payload="00 00">Battery<small>06</small></button>
  <button data-op="25">Device info<small>25</small></button>
  <button data-op="37" data-payload="00 00">Features<small>37</small></button>
  <button data-action="setTime">Set time<small>01</small></button>
  <button data-op="1D">Steps today<small>1D</small></button>
  <button data-op="2F" data-payload="00 00">Audio state<small>2F</small></button>
  <button data-action="heartbeat">Heartbeat on/off<small>3E</small></button>
</div></section>

<section><h2>History — pick a day</h2>
<div class="days" id="days">
  <button class="sel" data-d="0">today</button><button data-d="1">-1</button>
  <button data-d="2">-2</button><button data-d="3">-3</button><button data-d="4">-4</button>
  <button data-d="5">-5</button><button data-d="6">-6</button>
</div>
<div class="grid">
  <button data-op="21" data-withday>Step history<small>21 + day</small></button>
  <button data-op="22" data-withday>Sleep<small>22 + day</small></button>
  <button data-op="24" data-withday>Health<small>24 + day</small></button>
  <button class="primary" data-action="syncWeek">Sync 7 days<small>into the device</small></button>
  <button data-action="sync">Sync now<small>since last sync</small></button>
</div>
<p class="note">Synced history, and week / month / year reports, as JSON:
<a href="/api/ring/health" style="color:var(--accent)">/api/ring/health</a>.</p>
</section>

<section><h2>Live measurements</h2><div class="grid">
  <button data-op="07">HR on<small>07</small></button>
  <button data-op="08">HR off<small>08</small></button>
  <button data-op="17" data-payload="01">SpO₂ on<small>17 01</small></button>
  <button data-op="17" data-payload="00">SpO₂ off<small>17 00</small></button>
  <button data-op="14" data-payload="01">Temp on<small>14 01</small></button>
  <button data-op="14" data-payload="00">Temp off<small>14 00</small></button>
</div>
<p class="note">A live heart-rate reading took about 2¾ minutes to arrive on hardware.</p>
</section>

<section><h2>HRV / BP probe — opcode 0F</h2><div class="grid">
  <button data-op="0F" data-payload="00 01">type 0 on<small>0F 00 01</small></button>
  <button data-op="0F" data-payload="01 01">type 1 on<small>0F 01 01</small></button>
  <button data-op="0F" data-payload="02 01">type 2 on<small>0F 02 01</small></button>
  <button data-op="0F" data-payload="00 00">type 0 off<small>0F 00 00</small></button>
  <button data-op="0F" data-payload="01 00">type 1 off<small>0F 01 00</small></button>
  <button data-op="0F" data-payload="02 00">type 2 off<small>0F 02 00</small></button>
</div>
<p class="note">LoraFit builds this command (openCloseBpBsHrv) but has no decoder for any
reply. The ring echoes the two bytes back; turn one on, wait a few minutes like a
heart-rate reading, and watch the log for an opcode it has never shown before.</p>
</section>

<section><h2>Recordings</h2><div class="grid">
  <button data-op="3D">Count<small>3D</small></button>
  <button class="primary" data-action="moveAll">Move all to device<small>34 / 36</small></button>
</div>
<p class="note">Needs Settings → Smart Ring open on the device. Moves each recording oldest
first and deletes it from the ring once the copy is saved. Listen at <a href="/api/ring/recordings" style="color:var(--accent)">/api/ring/recordings</a>.</p>
</section>

<section><h2>Custom command</h2>
<form id="custom"><input id="op" placeholder="op hex" autocomplete="off">
<input id="payload" placeholder="payload hex, e.g. 00 01" autocomplete="off">
<button class="primary" type="submit">Send</button></form>
</section>
</div>

<section id="logcard"><h2>Ring log</h2>
<div class="logbar"><label><input type="checkbox" id="follow" checked> follow</label>
<span id="count"></span></div>
<pre id="log">loading…</pre></section>
</main>
<div id="toast" hidden></div>
<script>
const $ = s => document.querySelector(s);
let day = 0;

function toast(msg, ok) {
  const t = $('#toast');
  t.textContent = msg; t.className = ok ? 'ok' : 'bad'; t.hidden = false;
  clearTimeout(t._h); t._h = setTimeout(() => t.hidden = true, 2600);
}

async function post(url, body) {
  try {
    const r = await fetch(url, {method: 'POST',
      headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
    const j = await r.json();
    toast(j.message, j.ok);
  } catch (e) { toast('device unreachable — ' + e, false); }
  setTimeout(tickLog, 300);
}

document.addEventListener('click', e => {
  const b = e.target.closest('button');
  // Only the custom form's button belongs to the form's own handler. Not
  // `b.type === 'submit'` — every <button> reports "submit" unless it says
  // otherwise, which silently disabled the whole page in the first build.
  if (!b || b.form) return;
  if (b.dataset.d !== undefined) {
    day = +b.dataset.d;
    document.querySelectorAll('#days button').forEach(x => x.classList.toggle('sel', x === b));
    return;
  }
  if (b.dataset.action) return post('/api/ring/action', {name: b.dataset.action});
  if (b.dataset.op !== undefined) {
    let p = b.dataset.payload || '';
    if (b.hasAttribute('data-withday')) p = (p + ' ' + day.toString(16).padStart(2, '0')).trim();
    post('/api/ring/send', {op: b.dataset.op, payload: p});
  }
});

$('#custom').addEventListener('submit', e => {
  e.preventDefault();
  post('/api/ring/send', {op: $('#op').value, payload: $('#payload').value});
});

async function tickStatus() {
  const s = $('#status');
  try {
    const j = await (await fetch('/api/ring/status')).json();
    s.textContent = !j.open ? 'ring service off' : j.connected ? 'ring connected' : 'not connected';
    s.className = 'pill ' + (j.connected ? 'on' : 'off');
  } catch (e) { s.textContent = 'device unreachable'; s.className = 'pill off'; }
}

async function tickLog() {
  const out = $('#log');
  try {
    const t = await (await fetch('/api/logs?q=' + encodeURIComponent('[RING]'))).text();
    const atBottom = out.scrollTop + out.clientHeight >= out.scrollHeight - 40;
    const lines = t ? t.split('\n').map(l => l.replace('[RING] ', '')) : [];
    out.textContent = lines.length ? lines.join('\n') : '(nothing yet)';
    $('#count').textContent = lines.length + ' lines';
    if ($('#follow').checked && atBottom) out.scrollTop = out.scrollHeight;
  } catch (e) { out.textContent = 'disconnected — ' + e; }
}

tickStatus(); tickLog();
setInterval(tickStatus, 2000); setInterval(tickLog, 1500);
</script></body></html>
''';

#!/usr/bin/env bun
/** Optional ntfy client for Codex's opt-in approval API. */

type Json = Record<string, any>;
const env = (name: string, fallback = "") => Bun.env[name]?.trim() || fallback;
const API_URL = env("CODEX_APPROVAL_API_URL", "http://127.0.0.1:10010").replace(/\/$/, "");
const API_TOKEN = env("CODEX_APPROVAL_API_TOKEN");
const NTFY_URL = env("NTFY_URL", "http://localhost:8086").replace(/\/$/, "");
const NTFY_TOPIC = env("NTFY_TOPIC", "codex");
const NTFY_TOKEN = env("CODEX_NTFY_PUBLISH_TOKEN", env("NTFY_OPENCODE_TOKEN", env("NTFY_TOKEN")));
const HOOK_TOKEN = env("CODEX_NTFY_HOOK_TOKEN");
const PORT = Number(env("CODEX_NTFY_PLUGIN_PORT", "10011"));
function detectLanHost() {
  try {
    const result = Bun.spawnSync(["ip", "route", "get", "1.1.1.1"]);
    const text = new TextDecoder().decode(result.stdout);
    const match = text.match(/\bsrc\s+(\d+\.\d+\.\d+|[0-9a-f:]+)\b/i);
    if (match) return match[1];
  } catch {}
  return "127.0.0.1";
}
const HOST = env("CODEX_NTFY_CALLBACK_HOST", detectLanHost());
const PANEL_TOKEN = `${crypto.randomUUID()}-${crypto.randomUUID()}`;

if (!API_TOKEN || !NTFY_TOKEN || !HOOK_TOKEN) {
  console.error("codex-ntfy-plugin: requiere CODEX_APPROVAL_API_TOKEN, CODEX_NTFY_HOOK_TOKEN y token de publicación ntfy");
  process.exit(2);
}

const apiHeaders = { Authorization: `Bearer ${API_TOKEN}`, "Content-Type": "application/json" };
const hookHeaders = { Authorization: `Bearer ${HOOK_TOKEN}`, "Content-Type": "application/json" };
const panelUrl = `http://${HOST}:${PORT}/panel/${PANEL_TOKEN}`;
const announced = new Set<string>();

async function api(path: string, init: RequestInit = {}) {
  return fetch(`${API_URL}${path}`, { ...init, headers: { ...apiHeaders, ...(init.headers || {}) } });
}
async function state(): Promise<Json> {
  const response = await api("/v1/state");
  if (!response.ok) throw new Error(`Codex API HTTP ${response.status}`);
  return response.json();
}
async function publish(request: Json) {
  const id = request.id;
  const actions = [
    { action: "http", label: "Aceptar", method: "POST", url: `http://${HOST}:${PORT}/approve/${encodeURIComponent(id)}/allow`, headers: hookHeaders, clear: true },
    { action: "http", label: "Denegar", method: "POST", url: `http://${HOST}:${PORT}/approve/${encodeURIComponent(id)}/deny`, headers: hookHeaders, clear: true },
    { action: "view", label: "⋯", url: panelUrl, clear: false },
  ];
  const response = await fetch(`${NTFY_URL}/${encodeURIComponent(NTFY_TOPIC)}`, {
    method: "POST", headers: { Authorization: `Bearer ${NTFY_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ title: request.kind === "fileChange" ? "Codex: cambio pendiente" : "Codex: comando pendiente", message: `${request.reason || ""}${request.cwd ? `\ncwd: ${request.cwd}` : ""}\n${request.command || "Solicita aplicar cambios"}`, priority: "urgent", tags: "warning,lock", actions }),
  });
  if (!response.ok) throw new Error(`ntfy HTTP ${response.status}`);
}
async function remoteAction(id: string, action: string, body: Json = {}) {
  const response = await api(`/v1/approvals/${encodeURIComponent(id)}`, { method: "POST", body: JSON.stringify({ action, ...body }) });
  if (!response.ok) throw new Error(`approval HTTP ${response.status}`);
}
function page() {
  return `<!doctype html><meta name="viewport" content="width=device-width"><title>Codex ntfy</title><style>body{font:16px system-ui;max-width:900px;margin:2em auto;padding:0 1em;background:#111;color:#eee}article{border:1px solid #555;border-radius:8px;padding:1em;margin:1em 0}button,input,textarea{font:inherit;padding:.55em;margin:.2em;background:#222;color:#eee;border:1px solid #777;border-radius:5px}pre{white-space:pre-wrap;word-break:break-word}.muted{color:#aaa}</style><h1>Codex · aprobaciones</h1><p class="muted">Panel vivo; la TUI sigue siendo la interfaz principal.</p><main id="app">Cargando…</main><script>
const base=location.pathname, esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function get(){let r=await fetch(base+'/state');return r.json()}; async function post(id,a,b={}){let r=await fetch(base+'/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,action:a,...b})});let j=await r.json();if(!j.ok)alert(j.reason);render()}; async function steer(id){let text=document.querySelector('[data-steer="'+CSS.escape(id)+'"]').value.trim();if(!text)return alert('Escribe el mensaje');let r=await fetch(base+'/steer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,text})});let j=await r.json();if(!j.ok)alert(j.reason);render()};
function card(p){return '<article><b>'+esc(p.kind)+' · '+esc(p.id)+'</b><pre>'+esc(p.command||'Cambio de archivos')+'</pre><span class="muted">'+esc(p.cwd||'')+'</span><br><textarea data-steer="'+esc(p.id)+'" rows="2" cols="50" placeholder="Mensaje para steer"></textarea><br><button onclick="post(\''+esc(p.id)+'\',\'allow\')">Aceptar</button><button onclick="post(\''+esc(p.id)+'\',\'deny\')">Denegar</button><button onclick="steer(\''+esc(p.id)+'\')">Enviar steer</button><br><input id="p-'+esc(p.id)+'" placeholder="Prefijo exacto"><button onclick="post(\''+esc(p.id)+'\',\'pattern\',{prefix:document.getElementById(\'p-'+esc(p.id)+'\').value})">Permitir prefijo</button><button onclick="post(\''+esc(p.id)+'\',\'session\')">Permitir sesión</button></article>'};
async function render(){let s=await get();document.querySelector('#app').innerHTML=(s.pending.length?s.pending.map(card).join(''):'<p>No hay solicitudes pendientes.</p>')+'<h2>Historial</h2>'+s.history.map(x=>'<article><b>'+esc(x.action)+'</b> · '+esc(x.id)+'</article>').join('')};render();setInterval(render,2000);
</script>`;
}

const server = Bun.serve({ hostname: "0.0.0.0", port: PORT, async fetch(request) {
  const url = new URL(request.url);
  if (url.pathname === `/panel/${PANEL_TOKEN}` && request.method === "GET") return new Response(page(), { headers: { "content-type": "text/html; charset=utf-8" } });
  if (url.pathname === `/panel/${PANEL_TOKEN}/state` && request.method === "GET") { const response = await state(); return new Response(await response.text(), { status: response.status, headers: { "content-type": "application/json" } }); }
  if (url.pathname === `/panel/${PANEL_TOKEN}/action` && request.method === "POST") { const body = await request.json(); try { await remoteAction(body.id, body.action, body); return Response.json({ ok: true }); } catch (error) { return Response.json({ ok: false, reason: String(error) }, { status: 502 }); } }
  if (url.pathname === `/panel/${PANEL_TOKEN}/steer` && request.method === "POST") { const body = await request.json(); try { const current = await state(); const pending = (current.pending || []).find((item: Json) => item.id === body.id); if (!pending) return Response.json({ ok: false, reason: "solicitud ya resuelta" }, { status: 404 }); const response = await api("/v1/steer", { method: "POST", body: JSON.stringify({ threadId: pending.threadId, turnId: pending.turnId, text: body.text }) }); if (!response.ok) throw new Error(`steer HTTP ${response.status}`); return Response.json({ ok: true }); } catch (error) { return Response.json({ ok: false, reason: String(error) }, { status: 502 }); } }
  const match = url.pathname.match(/^\/approve\/([^/]+)\/(allow|deny)$/);
  if (match && request.method === "POST") { if (request.headers.get("authorization") !== `Bearer ${HOOK_TOKEN}`) return Response.json({ ok: false }, { status: 401 }); try { await remoteAction(decodeURIComponent(match[1]), match[2]); return Response.json({ ok: true }); } catch (error) { return Response.json({ ok: false, reason: String(error) }, { status: 502 }); } }
  if (url.pathname === "/healthz") return new Response("ok");
  return new Response("not found", { status: 404 });
}});

console.error(`codex-ntfy-plugin: panel ${panelUrl}`);
if (HOST === "127.0.0.1" || HOST === "0.0.0.0") console.error("codex-ntfy-plugin: no se detectó una IP LAN; define CODEX_NTFY_CALLBACK_HOST para que ntfy pueda acceder desde el teléfono");
async function poll() {
  try { const current = await state(); for (const request of current.pending || []) if (!announced.has(request.id)) { announced.add(request.id); await publish(request); } for (const id of [...announced]) if (!(current.pending || []).some((request: Json) => request.id === id)) announced.delete(id); }
  catch (error) { console.error(`codex-ntfy-plugin: ${String(error)}`); }
}
await poll(); setInterval(poll, 2000);

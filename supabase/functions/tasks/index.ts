// 自动工程实作课 · 后台工作
// Supabase → Edge Functions → 名字：tasks
// 要关掉「Verify JWT」（每分钟的定时工作没有 JWT；里面自己会检查）
//
// action:
//   cron          每分钟一次（pg_cron 叫）：资料有变就备份到 Google Drive；6 天没登入就推播提醒
//   connect       老师在「设定」按「连接 Google Drive」后，拿 Google 给的 code 换成长期的连线
//   disconnect    老师断开 Google Drive
//   backup-now    老师按「马上备份」
//   test-push     老师按「测试推播」
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const GOOGLE_ID = Deno.env.get("GOOGLE_CLIENT_ID") ?? "";
const GOOGLE_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET") ?? "";
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const APP_URL = "https://iotbpclass.github.io/CloudServer/";
const FOLDER_NAME = "自动工程实作课_云端备份";
const KEEP_DAILY = 60;

const noSession = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(URL, SERVICE, noSession);

async function rpc(name: string, args: Record<string, unknown> = {}) {
  const r = await admin.rpc(name, args);
  if (r.error) throw new Error(name + "：" + r.error.message);
  return r.data;
}

function todayMYT() {
  return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

// ---------------------------------------------------------------- Google Drive
async function googleToken(body: Record<string, string>) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: GOOGLE_ID, client_secret: GOOGLE_SECRET, ...body }),
  });
  const j = await res.json();
  if (!res.ok) {
    if (j.error === "invalid_grant") throw new Error("Google 连线失效了，去「设定」重新连接 Google Drive");
    throw new Error("Google 登入失败：" + (j.error_description || j.error || res.status));
  }
  return j;
}

async function drive(token: string, path: string, init: RequestInit = {}, upload = false) {
  const base = upload ? "https://www.googleapis.com/upload/drive/v3/" : "https://www.googleapis.com/drive/v3/";
  const res = await fetch(base + path, {
    ...init,
    headers: { Authorization: "Bearer " + token, ...(init.headers || {}) },
  });
  if (res.status === 204) return null;
  const text = await res.text();
  const j = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const err = new Error("Google Drive：" + (j?.error?.message || res.status)) as Error & { status?: number };
    err.status = res.status;
    throw err;
  }
  return j;
}

async function ensureFolder(token: string, folderId: string | null) {
  if (folderId) {
    try {
      const f = await drive(token, "files/" + folderId + "?fields=id,trashed");
      if (f && !f.trashed) return folderId;
    } catch (e) {
      if ((e as { status?: number }).status !== 404) throw e;
    }
  }
  const created = await drive(token, "files?fields=id", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: FOLDER_NAME, mimeType: "application/vnd.google-apps.folder" }),
  });
  return created.id as string;
}

async function listFolder(token: string, folderId: string) {
  const q = encodeURIComponent("'" + folderId + "' in parents and trashed = false");
  const j = await drive(token, "files?q=" + q + "&fields=files(id,name)&pageSize=1000");
  return (j?.files ?? []) as { id: string; name: string }[];
}

async function putFile(token: string, folderId: string, name: string, content: string, existingId?: string) {
  if (existingId) {
    await drive(token, "files/" + existingId + "?uploadType=media", {
      method: "PATCH",
      headers: { "Content-Type": "application/json; charset=utf-8" },
      body: content,
    }, true);
    return;
  }
  const boundary = "iotclass" + crypto.randomUUID().replace(/-/g, "");
  const body =
    "--" + boundary + "\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n" +
    JSON.stringify({ name, parents: [folderId], mimeType: "application/json" }) + "\r\n" +
    "--" + boundary + "\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n" +
    content + "\r\n--" + boundary + "--";
  await drive(token, "files?uploadType=multipart&fields=id", {
    method: "POST",
    headers: { "Content-Type": "multipart/related; boundary=" + boundary },
    body,
  }, true);
}

async function runBackup(force: boolean) {
  const info = await rpc("svc_backup_info");
  if (!info.refresh_token) return { skipped: "not-connected" };
  if (!force && info.stamp === info.last_stamp) return { skipped: "no-change" };
  try {
    const data = await rpc("svc_backup_export");
    const content = JSON.stringify(data, null, 2);
    const tok = await googleToken({ refresh_token: info.refresh_token, grant_type: "refresh_token" });
    const folderId = await ensureFolder(tok.access_token, info.folder_id);
    const files = await listFolder(tok.access_token, folderId);
    const byName = new Map(files.map((f) => [f.name, f.id]));
    const dailyName = "daily_" + todayMYT() + ".json";
    await putFile(tok.access_token, folderId, "latest.json", content, byName.get("latest.json"));
    await putFile(tok.access_token, folderId, dailyName, content, byName.get(dailyName));
    // 每天一份，留最近 60 天
    const daily = files.map((f) => f.name).filter((n) => /^daily_\d{4}-\d{2}-\d{2}\.json$/.test(n));
    if (!daily.includes(dailyName)) daily.push(dailyName);
    daily.sort();
    for (const old of daily.slice(0, Math.max(0, daily.length - KEEP_DAILY))) {
      const id = byName.get(old);
      if (id) await drive(tok.access_token, "files/" + id, { method: "DELETE" }).catch(() => null);
    }
    await rpc("svc_backup_done", { p_stamp: info.stamp, p_folder: folderId, p_error: null });
    return { ok: true, at: new Date().toISOString() };
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    await rpc("svc_backup_done", { p_stamp: null, p_folder: null, p_error: msg }).catch(() => null);
    return { ok: false, error: msg };
  }
}

// ---------------------------------------------------------------- 推播
async function sendPush(subs: unknown[], payload: Record<string, unknown>) {
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) throw new Error("还没设定 VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY");
  webpush.setVapidDetails(APP_URL, VAPID_PUBLIC, VAPID_PRIVATE);
  let sent = 0;
  for (const sub of subs as { endpoint: string }[]) {
    try {
      await webpush.sendNotification(sub, JSON.stringify(payload), { TTL: 24 * 3600 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await rpc("svc_push_remove", { p_endpoint: sub.endpoint }).catch(() => null);
    }
  }
  return sent;
}

async function runReminder() {
  const subs = await rpc("svc_reminder_due");
  if (!subs || !subs.length) return 0;
  return await sendPush(subs, {
    title: "自动工程实作课",
    body: "已经 6 天没有登入老师页了。点一下进去，Supabase 才不会被暂停。",
    url: APP_URL + "#/t/classes",
  });
}

// ---------------------------------------------------------------- 入口
async function isTeacher(req: Request) {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return false;
  const user = createClient(URL, ANON, { ...noSession, global: { headers: { Authorization: auth } } });
  const r = await user.rpc("is_teacher");
  return !r.error && r.data === true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ ok: false }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body.action ?? "");

    if (action === "cron") {
      const ok = await rpc("svc_cron_ok", { p_secret: req.headers.get("x-cron-secret") ?? "" });
      if (!ok) return reply({ ok: false, error: "secret" }, 403);
      const out: Record<string, unknown> = {};
      try { out.reminder = await runReminder(); } catch (e) { out.reminder_error = String((e as Error).message); }
      out.backup = await runBackup(false);
      return reply({ ok: true, ...out });
    }

    if (!(await isTeacher(req))) return reply({ ok: false, error: "要先登入老师账号" }, 403);

    if (action === "connect") {
      if (!GOOGLE_ID || !GOOGLE_SECRET) return reply({ ok: false, error: "Edge Function 还没设定 GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET" });
      const tok = await googleToken({ code: String(body.code ?? ""), redirect_uri: "postmessage", grant_type: "authorization_code" });
      if (!tok.refresh_token) {
        return reply({ ok: false, error: "Google 没给长期连线。去 myaccount.google.com/permissions 移除这个 app，再连接一次。" });
      }
      let email = "";
      try {
        const about = await drive(tok.access_token, "about?fields=user(emailAddress)");
        email = about?.user?.emailAddress ?? "";
      } catch (_e) { /* 拿不到 email 没关系 */ }
      await rpc("svc_google_save", { p_refresh: tok.refresh_token, p_email: email });
      const backup = await runBackup(true);
      return reply({ ok: true, email, backup });
    }

    if (action === "disconnect") {
      await rpc("svc_google_save", { p_refresh: null, p_email: null });
      return reply({ ok: true });
    }

    if (action === "backup-now") {
      return reply({ ok: true, backup: await runBackup(true) });
    }

    if (action === "test-push") {
      const subs = await rpc("svc_push_all");
      if (!subs || !subs.length) return reply({ ok: false, error: "还没有装置开推播" });
      const sent = await sendPush(subs, { title: "自动工程实作课", body: "✅ 推播测试成功！6 天没登入时会这样提醒你。", url: APP_URL + "#/t/settings" });
      return reply({ ok: true, sent });
    }

    return reply({ ok: false, error: "不知道要做什么" }, 400);
  } catch (e) {
    console.error(e);
    return reply({ ok: false, error: String((e as Error)?.message ?? e) }, 500);
  }
});

// 自动工程实作课 · 学生登入（名字 + 6 位 PIN）
// Supabase → Edge Functions → 名字：student-login
// 要关掉「Verify JWT」（学生还没登入，没有 JWT）
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// 跟 Server.py 的 name_key 一样：空白合并、去头尾、小写
function nameKey(value: unknown) {
  return String(value ?? "").replace(/\s+/g, " ").trim().toLowerCase().slice(0, 40);
}

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ ok: false, code: "method" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const key = nameKey(body.name);
    const pin = String(body.pin ?? "").trim();
    if (!key || !pin) return reply({ ok: false, code: "empty" });

    const admin = createClient(URL, SERVICE, noSession);

    // 同一个名字 10 分钟错 10 次就锁
    const locked = await admin.rpc("svc_login_locked", { p_key: key });
    if (locked.error) throw locked.error;
    if (locked.data) return reply({ ok: false, code: "locked" });

    const found = await admin.rpc("svc_find_student", { p_key: key, p_pin: pin });
    if (found.error) throw found.error;
    const student = (found.data ?? [])[0];
    if (!student) {
      await admin.rpc("svc_login_fail", { p_key: key });
      return reply({ ok: false, code: "wrong" });
    }
    await admin.rpc("svc_login_clear", { p_key: key });

    // 每个学生背后有一个 Supabase 账号（假 email，不会寄信）
    const email = "s" + String(student.id).replace(/-/g, "") + "@students.iotbpclass.example.com";
    let uid: string | null = student.auth_user_id ?? null;
    if (!uid) {
      const created = await admin.auth.admin.createUser({
        email,
        email_confirm: true,
        password: crypto.randomUUID() + crypto.randomUUID(),
        app_metadata: { role: "student", student_id: student.id },
      });
      if (!created.error && created.data.user) uid = created.data.user.id;
    }

    const link = await admin.auth.admin.generateLink({ type: "magiclink", email });
    if (link.error) throw link.error;
    if (!uid) uid = link.data.user.id;
    if (uid !== student.auth_user_id) {
      const saved = await admin.rpc("svc_set_auth_user", { p_student: student.id, p_uid: uid });
      if (saved.error) throw saved.error;
    }

    const anon = createClient(URL, ANON, noSession);
    const verified = await anon.auth.verifyOtp({
      token_hash: link.data.properties.hashed_token,
      type: "magiclink",
    });
    if (verified.error || !verified.data.session) throw verified.error ?? new Error("拿不到登入资格");

    return reply({
      ok: true,
      name: student.name,
      access_token: verified.data.session.access_token,
      refresh_token: verified.data.session.refresh_token,
    });
  } catch (e) {
    console.error(e);
    return reply({ ok: false, code: "server", error: String((e as Error)?.message ?? e) }, 500);
  }
});

// 自动工程实作课 云端版 · 设定
// 这几样都是公开的（任何人打开网页都看得到），放在这里没问题。
// ⚠ Supabase 的 secret key（sb_secret_… 或 service_role）绝对不要放进这里。
window.IOT_CONFIG = {
  SUPABASE_URL: "https://tqotlmqqutcklnvrqoom.supabase.co",
  SUPABASE_KEY: "sb_publishable_S5gWWI3h-5G7eKaFEt82rA_iFQcicu4",

  // Google Cloud → OAuth 用户端 ID（设定步骤第 5 步拿到后贴在这里）
  GOOGLE_CLIENT_ID: "",

  // 推播用的公开钥匙（跟 Edge Function 的 VAPID_PUBLIC_KEY 一样）
  VAPID_PUBLIC_KEY: "BNumU90Qlgs_gBYwj7SaNLWfmS4U5qi0mVyiAbISpr9ckseNYN3gJivzo8G_VIMi-IedUedw9163CG-zJGJxuC4",

  // 给家长的 WhatsApp 开头用的称呼
  TEACHER_NAME: "林老师",

  VERSION: "第 1 阶段 · 2026-11-27"
};

// Envoie les notifications Web Push du habit tracker.
// Actions:
//   key   → clé publique VAPID (générée et gardée en base au premier appel; la clé privée ne sort jamais de Supabase)
//   test  → notification d'essai à l'utilisateur connecté
//   check → appelée par le trigger sur `checks`: prévient les autres quand quelqu'un finit sa journée
//   cron  → appelée chaque heure par pg_cron: rappel à 21 h (heure de Montréal) s'il reste des habitudes
// `check` et `cron` exigent l'en-tête x-push-token, un jeton généré dans Postgres (table push_config).
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP_URL = "https://jacobchessman.github.io/habitudes/";
const TZ = "America/Toronto";
const REMINDER_HOUR = 21;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

const localDay = (d = new Date()) => new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
const localHour = (d = new Date()) => Number(new Intl.DateTimeFormat("en-CA", { timeZone: TZ, hour: "numeric", hourCycle: "h23" }).format(d));
const daysBefore = (k: string, n: number) => { const d = new Date(k + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() - n); return d.toISOString().slice(0, 10); };
const prevDay = (k: string) => { const d = new Date(k + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() - 1); return d.toISOString().slice(0, 10); };

async function config() {
  const { data: c, error } = await admin.from("push_config").select("*").eq("id", 1).single();
  if (error) throw error;
  if (!c.vapid_public) {
    const k = webpush.generateVAPIDKeys();
    await admin.from("push_config").update({ vapid_public: k.publicKey, vapid_private: k.privateKey }).eq("id", 1).is("vapid_public", null);
    return config(); // relire: si deux appels ont couru, le premier écrit gagne
  }
  webpush.setVapidDetails(APP_URL, c.vapid_public, c.vapid_private);
  return c;
}

async function send(userIds: string[], payload: Record<string, unknown>) {
  if (!userIds.length) return 0;
  const { data: subs } = await admin.from("push_subscriptions").select("*").in("user_id", userIds);
  let sent = 0;
  await Promise.all((subs || []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ url: APP_URL, ...payload }));
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await admin.from("push_subscriptions").delete().eq("id", s.id); // abonnement mort
      else console.error("push", code, (e as Error).message);
    }
  }));
  return sent;
}

// Une seule fois par personne, par jour et par sorte: renvoie true si c'est la première fois.
async function once(user_id: string, day: string, kind: string) {
  const { data } = await admin.from("push_log").upsert({ user_id, day, kind }, { onConflict: "user_id,day,kind", ignoreDuplicates: true }).select();
  return (data || []).length > 0;
}

async function dayState(user_id: string, day: string) {
  const [{ data: habits }, { data: checks }] = await Promise.all([
    admin.from("habits").select("id,name,created_at").eq("user_id", user_id),
    admin.from("checks").select("habit_id,day").eq("user_id", user_id).gte("day", daysBefore(day, 400)).lte("day", day),
  ]);
  const set = new Set((checks || []).map((c) => c.habit_id + c.day));
  const active = (habits || []).filter((h) => localDay(new Date(h.created_at)) <= day || set.has(h.id + day));
  const left = active.filter((h) => !set.has(h.id + day));
  const streakTo = (hid: string, k: string) => { let n = 0; while (set.has(hid + k)) { n++; k = prevDay(k); } return n; };
  return { total: active.length, done: active.length - left.length, left, streakTo, prev: prevDay(day) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const action = body.action;
    const c = await config();

    if (action === "key") return json({ publicKey: c.vapid_public });

    if (action === "test") {
      const token = (req.headers.get("authorization") || "").replace(/^Bearer /, "");
      const { data: { user } } = await admin.auth.getUser(token);
      if (!user) return json({ error: "non connecté" }, 401);
      const n = await send([user.id], { title: "Notifications activées 🔔", body: "C'est parfait. On se revoit à 21 h si tu as oublié quelque chose." });
      return json({ sent: n });
    }

    if (req.headers.get("x-push-token") !== c.token) return json({ error: "jeton invalide" }, 401);
    const { data: profiles } = await admin.from("profiles").select("id,name");
    const today = localDay();

    if (action === "check") {
      if (body.day !== today) return json({ skipped: "pas aujourd'hui" });
      const s = await dayState(body.user_id, today);
      if (!s.total || s.done < s.total) return json({ skipped: `${s.done}/${s.total}` });
      if (!(await once(body.user_id, today, "perfect"))) return json({ skipped: "déjà envoyé" });
      const name = profiles?.find((p) => p.id === body.user_id)?.name || "Quelqu'un";
      const others = (profiles || []).map((p) => p.id).filter((id) => id !== body.user_id);
      const n = await send(others, { title: `${name} a fini sa journée ✨`, body: `${s.total}/${s.total} habitudes cochées. À ton tour!`, tag: `perfect-${body.user_id}` });
      return json({ sent: n });
    }

    if (action === "cron") {
      if (localHour() !== REMINDER_HOUR && !body.force) return json({ skipped: `il est ${localHour()} h` });
      let sent = 0;
      for (const p of profiles || []) {
        const s = await dayState(p.id, today);
        if (!s.total || s.done === s.total) continue;
        if (!body.force && !(await once(p.id, today, "reminder"))) continue;
        const names = s.left.map((h) => h.name);
        const atRisk = s.left.map((h) => ({ h, n: s.streakTo(h.id, s.prev) })).filter((x) => x.n >= 3).sort((a, b) => b.n - a.n)[0];
        const title = atRisk ? `🔥 Ta série de ${atRisk.n} jours sur ${atRisk.h.name} tombe à minuit` : `Il te reste ${s.left.length} habitude${s.left.length > 1 ? "s" : ""} aujourd'hui`;
        const list = names.length <= 3 ? names.join(", ") : `${names.slice(0, 3).join(", ")} et ${names.length - 3} autre${names.length > 4 ? "s" : ""}`;
        sent += await send([p.id], { title, body: `${s.done}/${s.total} fait. Reste: ${list}.`, tag: "reminder" });
      }
      return json({ sent });
    }

    return json({ error: "action inconnue" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});

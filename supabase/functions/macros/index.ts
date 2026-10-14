// Estime les macros d'un repas décrit en mots (onglet Forme → « Autre chose »).
// Appelée par la page avec la session de la personne connectée; la clé Anthropic reste dans les secrets Supabase.
// Garde-fou: 40 estimations par personne par 24 h (table fit_ai_log).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
const LIMIT = 40;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

const SYSTEM = `Tu estimes les valeurs nutritives d'un repas décrit par un Québécois (français, anglais ou mélange).
Donne le TOTAL pour la quantité décrite. Sans quantité précise, prends une portion normale de resto ou de maison et dis-le dans la note.
Base-toi sur des valeurs de référence réalistes (Fichier canadien sur les éléments nutritifs, USDA, étiquettes des marques connues).
name: nom court du repas, 60 caractères max. note: une phrase courte qui dit la portion supposée.`;

const SCHEMA = {
  type: "object",
  properties: {
    name: { type: "string" },
    kcal: { type: "integer" },
    protein: { type: "number" },
    carbs: { type: "number" },
    fat: { type: "number" },
    note: { type: "string" },
  },
  required: ["name", "kcal", "protein", "carbs", "fat", "note"],
  additionalProperties: false,
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const token = (req.headers.get("authorization") || "").replace(/^Bearer /, "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ error: "non connecté" }, 401);

    const { text } = await req.json().catch(() => ({}));
    const repas = String(text || "").trim();
    if (!repas || repas.length > 300) return json({ error: "Décris ton repas en 300 caractères max." }, 400);

    const since = new Date(Date.now() - 864e5).toISOString();
    const { count } = await admin.from("fit_ai_log").select("id", { count: "exact", head: true }).eq("user_id", user.id).gte("created_at", since);
    if ((count ?? 0) >= LIMIT) return json({ error: `Limite de ${LIMIT} estimations par 24 h atteinte.` }, 429);
    await admin.from("fit_ai_log").insert({ user_id: user.id, prompt: repas });

    const response = await anthropic.messages.create({
      model: "claude-haiku-5-5",
      max_tokens: 1024,
      thinking: { type: "disabled" },
      system: SYSTEM,
      messages: [{ role: "user", content: repas }],
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
    });
    if (response.stop_reason === "refusal") return json({ error: "L'IA n'a pas voulu estimer ce repas." }, 422);
    const block = response.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") return json({ error: "Réponse vide de l'IA." }, 502);
    const m = JSON.parse(block.text);
    return json({
      name: String(m.name).slice(0, 80),
      kcal: Math.max(0, Math.round(m.kcal)),
      protein: Math.max(0, Math.round(m.protein * 10) / 10),
      carbs: Math.max(0, Math.round(m.carbs * 10) / 10),
      fat: Math.max(0, Math.round(m.fat * 10) / 10),
      note: String(m.note).slice(0, 200),
    });
  } catch (e) {
    if (e instanceof Anthropic.RateLimitError) return json({ error: "L'IA est occupée, réessaie dans une minute." }, 503);
    if (e instanceof Anthropic.APIError) { console.error("anthropic", e.status, e.message); return json({ error: "L'IA ne répond pas pour l'instant." }, 502); }
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});

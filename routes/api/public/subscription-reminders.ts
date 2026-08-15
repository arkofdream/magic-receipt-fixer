import { createFileRoute } from "@tanstack/react-router";

const THRESHOLDS = [30, 7, 3] as const;
const FROM = "e-Fatura Portalı <destek@mindcollabs.com>";

function addDays(days: number): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

function emailHtml(company: string, endDate: string, days: number): string {
  const title = company || "Sayın kullanıcımız";
  return `<div style="font-family:Arial,sans-serif;color:#111">
    <h2>Abonelik Hatırlatması</h2>
    <p>${title},</p>
    <p>e-Fatura Portalı aboneliğinizin bitmesine <strong>${days} gün</strong> kaldı.
    Abonelik bitiş tarihiniz: <strong>${new Date(endDate).toLocaleDateString("tr-TR")}</strong>.</p>
    <p>Hizmeti kesintisiz kullanmaya devam etmek için aboneliğinizi yenileyebilirsiniz.</p>
    <p style="color:#666;font-size:12px">Bu e-posta e-Fatura Portalı tarafından otomatik gönderilmiştir.</p>
  </div>`;
}

async function runReminders() {
  const resendKey = process.env["RESEND_API_KEY"];
  if (!resendKey) throw new Error("RESEND_API_KEY tanımlı değil.");
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");

  const targets = THRESHOLDS.map((d) => ({ days: d, date: addDays(d) }));
  const results: Array<{ email: string; days: number; ok: boolean; error?: string }> = [];

  for (const target of targets) {
    const { data: subs, error } = await supabaseAdmin
      .from("subscriptions")
      .select("user_id, end_date, status")
      .eq("end_date", target.date)
      .in("status", ["ACTIVE", "UPCOMING_EXPIRY"]);
    if (error) throw new Error(error.message);

    for (const sub of subs ?? []) {
      const { data: profile } = await supabaseAdmin
        .from("profiles")
        .select("email, company_title")
        .eq("id", sub.user_id)
        .maybeSingle();
      const to = profile?.email?.trim();
      if (!to) continue;

      const { error: markError } = await supabaseAdmin.from("subscription_reminders").insert({
        user_id: sub.user_id,
        email: to,
        end_date: sub.end_date,
        threshold_days: target.days,
      });
      if (markError) continue; // already sent for this user/date/threshold

      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${resendKey}`,
        },
        body: JSON.stringify({
          from: FROM,
          to: [to],
          subject: `Aboneliğinizin bitmesine ${target.days} gün kaldı`,
          html: emailHtml(profile?.company_title ?? "", sub.end_date, target.days),
        }),
      });

      if (!response.ok) {
        const body = await response.text();
        console.error(`Resend gönderimi başarısız [${response.status}]: ${body}`);
        await supabaseAdmin
          .from("subscription_reminders")
          .delete()
          .eq("user_id", sub.user_id)
          .eq("end_date", sub.end_date)
          .eq("threshold_days", target.days);
        results.push({
          email: to,
          days: target.days,
          ok: false,
          error: `${response.status}: ${body}`,
        });
        continue;
      }
      results.push({ email: to, days: target.days, ok: true });
    }
  }

  return results;
}

export const Route = createFileRoute("/api/public/subscription-reminders")({
  server: {
    handlers: {
      POST: async () => {
        try {
          const results = await runReminders();
          return Response.json({ ok: true, sent: results.filter((r) => r.ok).length, results });
        } catch (e) {
          const message = e instanceof Error ? e.message : "Bilinmeyen hata";
          console.error("Abonelik hatırlatma hatası:", message);
          return Response.json({ ok: false, error: message }, { status: 500 });
        }
      },
      GET: async () =>
        Response.json({ ok: true, info: "Abonelik hatırlatma görevi. POST ile tetiklenir." }),
    },
  },
});

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}

async function sha256Hex(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("");
}

function authorized(req, env) {
  if (!env.REGISTRATION_SHARED_TOKEN) return true;
  return req.headers.get("authorization") === `Bearer ${env.REGISTRATION_SHARED_TOKEN}`;
}

async function github(env, path, init = {}) {
  const headers = new Headers(init.headers || {});
  headers.set("authorization", `Bearer ${env.GITHUB_TOKEN}`);
  headers.set("accept", "application/vnd.github+json");
  headers.set("x-github-api-version", "2022-11-28");
  headers.set("user-agent", "pikmin-pilot-bootstrap");
  return fetch(`https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}${path}`, { ...init, headers });
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (!authorized(req, env)) return json({ status: "failed", message: "unauthorized" }, 401);

    if (req.method === "POST" && url.pathname === "/register") {
      const body = await req.json().catch(() => null);
      if (!body?.udid) return json({ status: "failed", message: "udid required" }, 400);
      const requestId = (await sha256Hex(body.udid)).slice(0, 20);
      const dispatch = await github(env, "/actions/workflows/register-device-and-build-pilot.yml/dispatches", {
        method: "POST",
        body: JSON.stringify({ ref: env.GITHUB_REF || "main", inputs: { device_udid: body.udid, device_name: body.name || `Pikmin-${requestId}` } })
      });
      if (!dispatch.ok) return json({ status: "failed", message: `GitHub dispatch failed ${dispatch.status}: ${await dispatch.text()}` }, 502);
      return json({ status: "pending", requestId });
    }

    if (req.method === "GET" && url.pathname === "/status") {
      const requestId = url.searchParams.get("requestId");
      if (!requestId) return json({ status: "failed", message: "requestId required" }, 400);
      const rel = await github(env, "/releases/tags/pikminpilot-latest");
      if (rel.status === 404) return json({ status: "pending", requestId });
      if (!rel.ok) return json({ status: "failed", message: `GitHub release lookup failed ${rel.status}` }, 502);
      const release = await rel.json();
      const metaAsset = (release.assets || []).find(a => a.name === "bootstrap.json");
      const ipaAsset = (release.assets || []).find(a => a.name.toLowerCase().endsWith(".ipa") && a.name.startsWith("PikminPilot-"));
      if (!metaAsset || !ipaAsset) return json({ status: "pending", requestId });
      const metaResp = await fetch(metaAsset.browser_download_url, { headers: { "user-agent": "pikmin-pilot-bootstrap" } });
      if (!metaResp.ok) return json({ status: "pending", requestId });
      const meta = await metaResp.json().catch(() => null);
      if (!meta || meta.requestId !== requestId) return json({ status: "pending", requestId });
      return json({ status: "ready", requestId, ipaUrl: ipaAsset.browser_download_url });
    }

    return json({ ok: true, service: "Pikmin Pilot Bootstrap Backend" });
  }
};

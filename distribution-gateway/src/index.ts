import { handleAdminUi } from "./admin-ui";

interface Env {
  DB: D1Database;
  RELEASES: R2Bucket;
  ADMIN_TOKEN: string;
}

type Channel = "beta" | "stable";

interface InviteRow {
  id: string;
  label: string;
  channel: Channel;
  max_activations: number;
  activation_count: number;
  access_days: number;
  expires_at: string | null;
  revoked_at: string | null;
}

interface DeviceRow {
  id: string;
  label: string;
  tester_name: string;
  channel: Channel;
  created_at: string;
  access_expires_at: string | null;
  revoked_at: string | null;
}

interface ReleaseRow {
  channel: Channel;
  version: string;
  update_object_key: string;
  installer_object_key: string;
  sha256: string;
  size: number;
  published_at: string;
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
    },
  });
}

function error(message: string, status: number): Response {
  return json({ error: message }, status);
}

function normalizeCode(value: string): string {
  return value.trim().toUpperCase();
}

function validChannel(value: unknown): value is Channel {
  return value === "beta" || value === "stable";
}

function validVersion(value: unknown): value is string {
  return typeof value === "string" && /^\d+(?:\.\d+)+(?:-[A-Za-z0-9.-]+)?$/.test(value);
}

function validObjectKey(value: unknown, channel: Channel, version: string): value is string {
  if (typeof value !== "string") return false;
  const prefix = "releases/" + channel + "/" + version + "/";
  return value.startsWith(prefix) && !value.includes("..") && !value.includes("\\");
}

function randomText(bytes = 24): string {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  return Array.from(data, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function secureEqual(a: string, b: string): Promise<boolean> {
  const [ah, bh] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let diff = ah.length ^ bh.length;
  for (let i = 0; i < Math.min(ah.length, bh.length); i++) diff |= ah.charCodeAt(i) ^ bh.charCodeAt(i);
  return diff === 0;
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return Array.from(new Uint8Array(signature), (b) => b.toString(16).padStart(2, "0")).join("");
}

function bearer(request: Request): string | null {
  const value = request.headers.get("authorization");
  if (!value || !value.startsWith("Bearer ")) return null;
  const token = value.slice(7).trim();
  return token || null;
}

async function requireAdmin(request: Request, env: Env): Promise<boolean> {
  const token = bearer(request);
  return !!token && !!env.ADMIN_TOKEN && (await secureEqual(token, env.ADMIN_TOKEN));
}

async function audit(env: Env, eventType: string, subjectId: string | null, detail: string | null): Promise<void> {
  try {
    await env.DB.prepare(
      "INSERT INTO audit_log(event_type, subject_id, detail, created_at) VALUES (?, ?, ?, ?)"
    ).bind(eventType, subjectId, detail, new Date().toISOString()).run();
  } catch {
  }
}

async function inviteForCode(env: Env, code: string): Promise<InviteRow | null> {
  const hash = await sha256Hex(normalizeCode(code));
  return env.DB.prepare(
    "SELECT id, label, channel, max_activations, activation_count, access_days, expires_at, revoked_at FROM invites WHERE code_hash = ?"
  ).bind(hash).first<InviteRow>();
}

function inviteIsUsable(invite: InviteRow | null): invite is InviteRow {
  if (!invite || invite.revoked_at) return false;
  if (invite.activation_count >= invite.max_activations) return false;
  if (invite.expires_at && Date.parse(invite.expires_at) <= Date.now()) return false;
  return true;
}

async function currentRelease(env: Env, channel: Channel): Promise<ReleaseRow | null> {
  return env.DB.prepare(
    "SELECT channel, version, update_object_key, installer_object_key, sha256, size, published_at FROM releases WHERE channel = ?"
  ).bind(channel).first<ReleaseRow>();
}

async function deviceFromRequest(request: Request, env: Env): Promise<DeviceRow | null> {
  const token = bearer(request);
  if (!token || token.length < 32) return null;
  const hash = await sha256Hex(token);
  const device = await env.DB.prepare(
    "SELECT d.id, d.label, i.label AS tester_name, d.channel, d.created_at, d.access_expires_at, d.revoked_at FROM devices d JOIN invites i ON i.id = d.invite_id WHERE d.token_hash = ?"
  ).bind(hash).first<DeviceRow>();
  if (!device || device.revoked_at) return null;
  if (device.access_expires_at && Date.parse(device.access_expires_at) <= Date.now()) return null;
  await env.DB.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?")
    .bind(new Date().toISOString(), device.id).run();
  return device;
}


async function programSetting(env: Env, key: string): Promise<string> {
  const row = await env.DB.prepare(
    "SELECT value FROM program_settings WHERE key = ?"
  ).bind(key).first<{ value: string }>();
  return row?.value || "";
}

function htmlEscape(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}


async function feedbackUrlForInvite(request: Request, env: Env, inviteId: string, returnPath?: string): Promise<string> {
  const signature = await hmacHex(env.ADMIN_TOKEN, "feedback:invite:" + inviteId);
  const url = new URL("/feedback/invite/" + encodeURIComponent(inviteId) + "/" + signature, new URL(request.url).origin);
  if (returnPath && returnPath.startsWith("/invite/") && !returnPath.startsWith("//")) {
    url.searchParams.set("return", returnPath);
  }
  return url.toString();
}

async function feedbackUrlForDevice(request: Request, env: Env, deviceId: string): Promise<string> {
  const signature = await hmacHex(env.ADMIN_TOKEN, "feedback:device:" + deviceId);
  return new URL(request.url).origin + "/feedback/device/" + encodeURIComponent(deviceId) + "/" + signature;
}

function feedbackPageHtml(name: string, action: string, submitted = false, returnPath = ""): string {
  const safeReturn = returnPath.startsWith("/invite/") && !returnPath.startsWith("//") ? returnPath : "";
  const returnLink = safeReturn
    ? '<p><a href="' + htmlEscape(safeReturn) + '">Back to FarRelay onboarding</a></p>'
    : '<p>You can close this tab or window to return to FarRelay.</p>';
  if (submitted) {
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FarRelay feedback received</title></head><body><main style="font-family:system-ui;max-width:48rem;margin:0 auto;padding:1.25rem;line-height:1.5"><h1>Thanks, ' +
      htmlEscape(name) +
      '.</h1><p>Your FarRelay beta feedback was received.</p>' +
      returnLink +
      '</main></body></html>';
  }
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FarRelay beta feedback</title></head><body><main style="font-family:system-ui;max-width:48rem;margin:0 auto;padding:1.25rem;line-height:1.5"><h1>FarRelay beta feedback</h1><p>This feedback form opened in a separate tab or window so you can return to your FarRelay onboarding page without losing your place.</p><p>Hello ' +
    htmlEscape(name) +
    '. Please report anything that broke, felt confusing, was inaccessible, or could make onboarding clearer.</p><form method="post" action="' +
    htmlEscape(action) +
    '"><label for="category">Feedback type</label><br><select id="category" name="category" required><option value="onboarding">Onboarding</option><option value="confusing">Confusing or unclear</option><option value="bug">Bug</option><option value="accessibility">Accessibility</option><option value="suggestion">Suggestion</option><option value="other">Other</option></select><br><br><label for="message">What happened?</label><br><textarea id="message" name="message" rows="10" maxlength="5000" required style="width:100%;box-sizing:border-box"></textarea><br><br><label for="contact">Email or contact information (optional)</label><br><input id="contact" name="contact" type="text" maxlength="200" style="width:100%;box-sizing:border-box"><p>Please include what you expected, what happened instead, and anything you found confusing.</p><button type="submit">Send beta feedback</button></form>' +
    returnLink +
    '</main></body></html>';
}

async function feedbackSubject(
  env: Env,
  kind: "invite" | "device",
  id: string,
  signature: string
): Promise<{ testerName: string; inviteId: string | null; deviceId: string | null } | null> {
  const expected = await hmacHex(env.ADMIN_TOKEN, "feedback:" + kind + ":" + id);
  if (!(await secureEqual(signature, expected))) return null;

  if (kind === "invite") {
    const row = await env.DB.prepare(
      "SELECT id, label, revoked_at FROM invites WHERE id = ?"
    ).bind(id).first<{ id: string; label: string; revoked_at: string | null }>();
    if (!row || row.revoked_at) return null;
    return { testerName: row.label, inviteId: row.id, deviceId: null };
  }

  const row = await env.DB.prepare(
    "SELECT d.id, d.invite_id, i.label AS tester_name, d.revoked_at FROM devices d JOIN invites i ON i.id = d.invite_id WHERE d.id = ?"
  ).bind(id).first<{ id: string; invite_id: string; tester_name: string; revoked_at: string | null }>();
  if (!row || row.revoked_at) return null;
  return { testerName: row.tester_name, inviteId: row.invite_id, deviceId: row.id };
}

async function handleFeedback(
  request: Request,
  env: Env,
  kind: "invite" | "device",
  id: string,
  signature: string
): Promise<Response> {
  const subject = await feedbackSubject(env, kind, id, signature);
  if (!subject) return error("feedback link is invalid or no longer active", 403);

  const feedbackRequestUrl = new URL(request.url);
  const rawReturnPath = feedbackRequestUrl.searchParams.get("return") || "";
  const returnPath = rawReturnPath.startsWith("/invite/") && !rawReturnPath.startsWith("//") ? rawReturnPath : "";
  const formAction = feedbackRequestUrl.pathname + (returnPath ? "?return=" + encodeURIComponent(returnPath) : "");

  if (request.method === "GET") {
    return new Response(feedbackPageHtml(subject.testerName, formAction, false, returnPath), {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "referrer-policy": "no-referrer",
        "x-content-type-options": "nosniff",
        "x-frame-options": "DENY",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
      },
    });
  }

  if (request.method !== "POST") return error("method not allowed", 405);
  const form = await request.formData().catch(() => null);
  const category = typeof form?.get("category") === "string" ? String(form?.get("category")).trim() : "";
  const message = typeof form?.get("message") === "string" ? String(form?.get("message")).trim() : "";
  const contact = typeof form?.get("contact") === "string" ? String(form?.get("contact")).trim() : "";
  const allowed = new Set(["onboarding", "confusing", "bug", "accessibility", "suggestion", "other"]);
  if (!allowed.has(category) || !message || message.length > 5000 || contact.length > 200) {
    return error("check the feedback type, message, and optional contact information", 400);
  }

  const recent = await env.DB.prepare(
    "SELECT created_at FROM beta_feedback WHERE ((device_id = ? AND ? IS NOT NULL) OR (invite_id = ? AND ? IS NOT NULL)) ORDER BY created_at DESC LIMIT 1"
  ).bind(subject.deviceId, subject.deviceId, subject.inviteId, subject.inviteId).first<{ created_at: string }>();
  if (recent && Date.now() - Date.parse(recent.created_at) < 15000) {
    return error("please wait a few seconds before sending more feedback", 429);
  }

  const feedbackId = crypto.randomUUID();
  const now = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO beta_feedback(id, invite_id, device_id, tester_name, category, message, contact, source, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).bind(
    feedbackId,
    subject.inviteId,
    subject.deviceId,
    subject.testerName,
    category,
    message,
    contact || null,
    kind,
    now
  ).run();
  await audit(env, "beta_feedback_submitted", feedbackId, category);
  return new Response(feedbackPageHtml(subject.testerName, formAction, true, returnPath), {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'",
    },
  });
}

function streamObject(object: R2ObjectBody, filename: string): Response {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("cache-control", "private, no-store");
  headers.set("content-disposition", 'attachment; filename="' + filename.replace(/"/g, "") + '"');
  headers.set("referrer-policy", "no-referrer");
  return new Response(object.body, { headers });
}

async function createInvite(request: Request, env: Env): Promise<Response> {
  const body = await request.json<Record<string, unknown>>().catch(() => null);
  if (!body || typeof body.label !== "string" || !body.label.trim() || !validChannel(body.channel)) {
    return error("label and channel are required", 400);
  }
  const maxActivations = Number(body.max_activations ?? 1);
  if (!Number.isInteger(maxActivations) || maxActivations < 1 || maxActivations > 10) {
    return error("max_activations must be between 1 and 10", 400);
  }
  const accessDays = Number(body.access_days ?? 30);
  if (!Number.isInteger(accessDays) || accessDays < 1 || accessDays > 365) {
    return error("access_days must be between 1 and 365", 400);
  }
  let expiresAt: string | null = null;
  if (body.expires_in_hours !== undefined) {
    const hours = Number(body.expires_in_hours);
    if (!Number.isFinite(hours) || hours <= 0 || hours > 720) {
      return error("expires_in_hours must be between 0 and 720", 400);
    }
    expiresAt = new Date(Date.now() + hours * 3600000).toISOString();
  }
  const code = "FR-" + body.channel.toUpperCase() + "-" + randomText(10).toUpperCase();
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO invites(id, code_hash, label, channel, max_activations, activation_count, access_days, expires_at, created_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)"
  ).bind(id, await sha256Hex(code), body.label.trim(), body.channel, maxActivations, accessDays, expiresAt, now).run();
  await audit(env, "invite_created", id, body.label.trim());
  const origin = new URL(request.url).origin;
  return json({
    id,
    label: body.label.trim(),
    channel: body.channel,
    activation_code: code,
    onboarding_url: origin + "/invite/" + encodeURIComponent(code),
    installer_url: origin + "/invite/" + encodeURIComponent(code) + "/installer",
    expires_at: expiresAt,
    access_days: accessDays,
    max_activations: maxActivations,
  }, 201);
}

async function activate(request: Request, env: Env): Promise<Response> {
  const body = await request.json<Record<string, unknown>>().catch(() => null);
  if (!body || typeof body.invite_code !== "string" || typeof body.device_name !== "string") {
    return error("invite_code and device_name are required", 400);
  }
  const invite = await inviteForCode(env, body.invite_code);
  if (!inviteIsUsable(invite)) return error("tester invitation is invalid, expired, used, or revoked", 403);

  const token = "frd_" + randomText(32);
  const tokenHash = await sha256Hex(token);
  const deviceId = crypto.randomUUID();
  const now = new Date().toISOString();
  const accessExpiresAt = new Date(Date.now() + invite.access_days * 86400000).toISOString();

  const results = await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO devices(id, invite_id, label, token_hash, channel, created_at, access_expires_at) SELECT ?, id, ?, ?, channel, ?, ? FROM invites WHERE id = ? AND revoked_at IS NULL AND activation_count < max_activations AND (expires_at IS NULL OR expires_at > ?)"
    ).bind(deviceId, body.device_name.trim().slice(0, 120) || "Windows device", tokenHash, now, accessExpiresAt, invite.id, now),
    env.DB.prepare(
      "UPDATE invites SET activation_count = activation_count + 1 WHERE id = ? AND EXISTS (SELECT 1 FROM devices WHERE id = ?)"
    ).bind(invite.id, deviceId),
  ]);
  if (!results[0].success || Number(results[0].meta.changes ?? 0) !== 1 || !results[1].success || Number(results[1].meta.changes ?? 0) !== 1) {
    return error("tester invitation could not be activated", 409);
  }
  await audit(env, "device_activated", deviceId, invite.id);
  const [testflightUrl, externalFeedbackUrl, nativeFeedbackUrl] = await Promise.all([
    programSetting(env, "testflight_url"),
    programSetting(env, "feedback_url"),
    feedbackUrlForDevice(request, env, deviceId),
  ]);
  return json({
    device_id: deviceId,
    device_token: token,
    channel: invite.channel,
    tester_name: invite.label,
    activated_at: now,
    access_expires_at: accessExpiresAt,
    testflight_url: testflightUrl,
    feedback_url: externalFeedbackUrl || nativeFeedbackUrl,
  }, 201);
}


async function deviceProfile(request: Request, env: Env): Promise<Response> {
  const device = await deviceFromRequest(request, env);
  if (!device) return error("device is not authorized or beta access has expired", 401);
  const [testflightUrl, externalFeedbackUrl, nativeFeedbackUrl, release] = await Promise.all([
    programSetting(env, "testflight_url"),
    programSetting(env, "feedback_url"),
    feedbackUrlForDevice(request, env, device.id),
    currentRelease(env, device.channel),
  ]);
  return json({
    tester_name: device.tester_name,
    computer_name: device.label,
    channel: device.channel,
    activated_at: device.created_at,
    access_expires_at: device.access_expires_at,
    testflight_url: testflightUrl,
    feedback_url: externalFeedbackUrl || nativeFeedbackUrl,
    current_release: release?.version || null,
  });
}

async function inviteLanding(request: Request, env: Env, code: string): Promise<Response> {
  const invite = await inviteForCode(env, code);
  if (!inviteIsUsable(invite)) {
    return new Response("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>FarRelay invitation unavailable</title></head><body><main><h1>FarRelay invitation unavailable</h1><p>This tester invitation is expired, used, revoked, or invalid.</p></main></body></html>", {
      status: 403,
      headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
    });
  }
  const [testflightUrl, externalFeedbackUrl, nativeFeedbackUrl] = await Promise.all([
    programSetting(env, "testflight_url"),
    programSetting(env, "feedback_url"),
    feedbackUrlForInvite(request, env, invite.id, "/invite/" + encodeURIComponent(code)),
  ]);
  const feedbackUrl = externalFeedbackUrl || nativeFeedbackUrl;
  const origin = new URL(request.url).origin;
  const installer = origin + "/invite/" + encodeURIComponent(code) + "/installer";
  const testflight = testflightUrl
    ? '<p><a href="' + htmlEscape(testflightUrl) + '">Join the FarRelay iPhone beta in TestFlight</a></p>'
    : '<p>The TestFlight join link has not been published yet. Ask the FarRelay developer for access before testing from iPhone.</p>';
  const feedback = feedbackUrl
    ? '<p><a href="' + htmlEscape(feedbackUrl) + '" target="_blank" rel="noopener">Send beta feedback (opens in a new tab)</a></p><p>Your onboarding page will stay open. After submitting feedback, use the Back to FarRelay onboarding link or close the feedback tab.</p>'
    : '<p>Please send the FarRelay developer anything that failed, felt unclear, or required help during onboarding.</p>';
  const body = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FarRelay beta onboarding</title></head><body><main style="font-family:system-ui;max-width:50rem;margin:0 auto;padding:1.25rem;line-height:1.5"><h1>Hello ' +
    htmlEscape(invite.label) + '! Welcome to the FarRelay beta.</h1><p>Please complete this onboarding on your own as much as possible. I specifically want feedback on anything that does not work, feels confusing, or makes you unsure what to do next.</p><h2>1. Join the iPhone beta</h2><p>You need the FarRelay app on your iPhone to test remote control. Install Apple TestFlight first if you do not already have it, then use the beta link below.</p>' +
    testflight + '<h2>2. Install FarRelay on this Windows PC</h2><p>The Windows installer will ask for your FarRelay activation code. Keep this onboarding page open until activation succeeds.</p><label for="activation-code"><strong>Activation code</strong></label><br><input id="activation-code" type="text" readonly value="' + htmlEscape(normalizeCode(code)) + '" style="width:100%;box-sizing:border-box;font:inherit;padding:.55rem"><p><a href="' + htmlEscape(installer) + '">Download the FarRelay Windows installer</a></p><p>Your installer invitation expires ' +
    htmlEscape(invite.expires_at || "when revoked") + '. After activation, this device receives ' + invite.access_days +
    ' day(s) of beta access.</p><h2>3. Open FarRelay Control Center</h2><p>After setup, use the FarRelay Control Center shortcut. It will guide you through OpenSSH, Tailscale, travel readiness, connection instructions, updates, and beta status.</p><h2>4. Give onboarding feedback</h2>' +
    feedback + '</main></body></html>';
  return new Response(body, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'",
    },
  });
}

async function manifest(request: Request, env: Env): Promise<Response> {
  const device = await deviceFromRequest(request, env);
  if (!device) return error("device is not authorized", 401);
  const release = await currentRelease(env, device.channel);
  if (!release) return error("no release is published for this channel", 404);
  return json({
    schema_version: 1,
    channel: release.channel,
    version: release.version,
    published_at: release.published_at,
    assets: {
      windows_x86_64: {
        archive_url: "/v1/download/" + release.version + "/windows_x86_64",
        sha256: release.sha256,
        size: release.size,
      },
    },
  });
}

async function downloadUpdate(request: Request, env: Env, version: string): Promise<Response> {
  const device = await deviceFromRequest(request, env);
  if (!device) return error("device is not authorized", 401);
  const release = await currentRelease(env, device.channel);
  if (!release || release.version !== version) return error("release is unavailable for this device", 404);
  const object = await env.RELEASES.get(release.update_object_key);
  if (!object) return error("release object is unavailable", 503);
  await audit(env, "update_downloaded", device.id, release.version);
  return streamObject(object, release.update_object_key.split("/").pop() || "FarRelay-Windows-Update.zip");
}

async function downloadInstaller(env: Env, code: string): Promise<Response> {
  const invite = await inviteForCode(env, code);
  if (!inviteIsUsable(invite)) return error("tester invitation is invalid, expired, used, or revoked", 403);
  const release = await currentRelease(env, invite.channel);
  if (!release) return error("no installer is currently published for this channel", 404);
  const object = await env.RELEASES.get(release.installer_object_key);
  if (!object) return error("installer object is unavailable", 503);
  await audit(env, "installer_downloaded", invite.id, release.version);
  return streamObject(object, release.installer_object_key.split("/").pop() || "FarRelay-Setup.exe");
}

async function publishRelease(request: Request, env: Env): Promise<Response> {
  const body = await request.json<Record<string, unknown>>().catch(() => null);
  if (!body || !validChannel(body.channel) || !validVersion(body.version)) {
    return error("channel and a valid version are required", 400);
  }
  const channel = body.channel;
  const version = body.version;
  if (!validObjectKey(body.update_object_key, channel, version) || !validObjectKey(body.installer_object_key, channel, version)) {
    return error("release object keys must stay inside the channel/version prefix", 400);
  }
  if (typeof body.sha256 !== "string" || !/^[a-fA-F0-9]{64}$/.test(body.sha256)) {
    return error("sha256 must be a 64-character hex digest", 400);
  }
  const size = Number(body.size);
  if (!Number.isSafeInteger(size) || size <= 0) return error("size must be a positive integer", 400);

  const updateKey = body.update_object_key as string;
  const installerKey = body.installer_object_key as string;
  const [updateHead, installerHead] = await Promise.all([
    env.RELEASES.head(updateKey),
    env.RELEASES.head(installerKey),
  ]);
  if (!updateHead || !installerHead) return error("release objects must be uploaded before registration", 409);
  if (updateHead.size !== size) return error("registered update size does not match R2 object", 409);

  const publishedAt = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO releases(channel, version, update_object_key, installer_object_key, sha256, size, published_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(channel) DO UPDATE SET version=excluded.version, update_object_key=excluded.update_object_key, installer_object_key=excluded.installer_object_key, sha256=excluded.sha256, size=excluded.size, published_at=excluded.published_at"
  ).bind(channel, version, updateKey, installerKey, body.sha256.toLowerCase(), size, publishedAt).run();
  await audit(env, "release_published", channel, version);
  return json({ channel, version, published_at: publishedAt }, 201);
}

async function listDevices(env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    "SELECT id, label, channel, created_at, last_seen_at, access_expires_at, revoked_at FROM devices ORDER BY created_at DESC"
  ).all();
  return json({ devices: result.results });
}

async function revokeDevice(env: Env, id: string): Promise<Response> {
  const result = await env.DB.prepare(
    "UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL"
  ).bind(new Date().toISOString(), id).run();
  if (Number(result.meta.changes ?? 0) !== 1) return error("active device not found", 404);
  await audit(env, "device_revoked", id, null);
  return json({ id, revoked: true });
}

async function listInvites(env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    "SELECT id, label, channel, max_activations, activation_count, access_days, expires_at, revoked_at, created_at FROM invites ORDER BY created_at DESC"
  ).all();
  return json({ invites: result.results });
}

async function revokeInvite(env: Env, id: string): Promise<Response> {
  const result = await env.DB.prepare(
    "UPDATE invites SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL"
  ).bind(new Date().toISOString(), id).run();
  if (Number(result.meta.changes ?? 0) !== 1) return error("active invitation not found", 404);
  await audit(env, "invite_revoked", id, null);
  return json({ id, revoked: true });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    const adminUi = await handleAdminUi(request, env);
    if (adminUi) return adminUi;

    if (request.method === "GET" && path === "/health") return json({ ok: true });


    const feedbackMatch = path.match(/^\/feedback\/(invite|device)\/([^/]+)\/([a-f0-9]{64})$/);
    if (feedbackMatch && (request.method === "GET" || request.method === "POST")) {
      return handleFeedback(
        request,
        env,
        feedbackMatch[1] as "invite" | "device",
        decodeURIComponent(feedbackMatch[2]),
        feedbackMatch[3]
      );
    }

    const installerMatch = path.match(/^\/invite\/([^/]+)\/installer$/);
    if (request.method === "GET" && installerMatch) return downloadInstaller(env, decodeURIComponent(installerMatch[1]));

    const invitePageMatch = path.match(/^\/invite\/([^/]+)$/);
    if (request.method === "GET" && invitePageMatch) return inviteLanding(request, env, decodeURIComponent(invitePageMatch[1]));

    if (request.method === "GET" && path === "/v1/invite/validate") {
      const invite = await inviteForCode(env, url.searchParams.get("code") || "");
      return inviteIsUsable(invite) ? new Response(null, { status: 204 }) : error("tester invitation is invalid", 403);
    }

    if (request.method === "POST" && path === "/v1/activate") return activate(request, env);
    if (request.method === "GET" && path === "/v1/manifest") return manifest(request, env);
    if (request.method === "GET" && path === "/v1/profile") return deviceProfile(request, env);

    const updateMatch = path.match(/^\/v1\/download\/([^/]+)\/windows_x86_64$/);
    if (request.method === "GET" && updateMatch) return downloadUpdate(request, env, decodeURIComponent(updateMatch[1]));

    if (path.startsWith("/admin/")) {
      if (!(await requireAdmin(request, env))) return error("admin authorization required", 401);
      if (request.method === "POST" && path === "/admin/invites") return createInvite(request, env);
      if (request.method === "GET" && path === "/admin/invites") return listInvites(env);
      if (request.method === "GET" && path === "/admin/devices") return listDevices(env);
      if (request.method === "POST" && path === "/admin/releases") return publishRelease(request, env);

      const deviceRevoke = path.match(/^\/admin\/devices\/([^/]+)\/revoke$/);
      if (request.method === "POST" && deviceRevoke) return revokeDevice(env, decodeURIComponent(deviceRevoke[1]));

      const inviteRevoke = path.match(/^\/admin\/invites\/([^/]+)\/revoke$/);
      if (request.method === "POST" && inviteRevoke) return revokeInvite(env, decodeURIComponent(inviteRevoke[1]));
    }

    return error("not found", 404);
  },
};

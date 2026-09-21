interface AdminEnv {
  DB: D1Database;
  ADMIN_TOKEN: string;
}

type Channel = "beta" | "stable";

interface DashboardInvite {
  id: string;
  label: string;
  channel: Channel;
  max_activations: number;
  activation_count: number;
  access_days: number;
  requested_device: string | null;
  expires_at: string | null;
  revoked_at: string | null;
  created_at: string;
}

interface DashboardDevice {
  id: string;
  label: string;
  channel: Channel;
  created_at: string;
  last_seen_at: string | null;
  access_expires_at: string | null;
  revoked_at: string | null;
}

interface DashboardRelease {
  channel: Channel;
  version: string;
  published_at: string;
}

interface DashboardFeedback {
  id: string;
  tester_name: string;
  category: string;
  message: string;
  contact: string | null;
  source: string;
  created_at: string;
}

interface AdminSession {
  payload: string;
  csrf: string;
}

interface CreatedInvite {
  label: string;
  channel: Channel;
  activationCode: string;
  installerUrl: string;
  expiresAt: string;
  accessDays: number;
}

const SESSION_COOKIE = "fr_admin";
const SESSION_SECONDS = 8 * 60 * 60;

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function securityHeaders(): Headers {
  const headers = new Headers();
  headers.set("cache-control", "no-store");
  headers.set("referrer-policy", "no-referrer");
  headers.set("x-content-type-options", "nosniff");
  headers.set("x-frame-options", "DENY");
  headers.set(
    "content-security-policy",
    "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
  );
  return headers;
}

function htmlResponse(body: string, status = 200, extraHeaders?: HeadersInit): Response {
  const headers = securityHeaders();
  headers.set("content-type", "text/html; charset=utf-8");
  if (extraHeaders) {
    new Headers(extraHeaders).forEach((value, key) => headers.set(key, value));
  }
  return new Response("<!doctype html>" + body, { status, headers });
}

function redirect(location: string, status = 303, extraHeaders?: HeadersInit): Response {
  const headers = securityHeaders();
  headers.set("location", location);
  if (extraHeaders) {
    new Headers(extraHeaders).forEach((value, key) => headers.set(key, value));
  }
  return new Response(null, { status, headers });
}

function randomText(bytes = 16): string {
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
  for (let i = 0; i < Math.min(ah.length, bh.length); i++) {
    diff |= ah.charCodeAt(i) ^ bh.charCodeAt(i);
  }
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

function cookieValue(request: Request, name: string): string | null {
  const cookies = request.headers.get("cookie");
  if (!cookies) return null;
  for (const item of cookies.split(";")) {
    const [key, ...rest] = item.trim().split("=");
    if (key === name) return rest.join("=") || null;
  }
  return null;
}

async function createSession(env: AdminEnv): Promise<{ cookie: string; session: AdminSession }> {
  const expires = Math.floor(Date.now() / 1000) + SESSION_SECONDS;
  const payload = `${expires}.${randomText(16)}`;
  const signature = await hmacHex(env.ADMIN_TOKEN, payload);
  const csrf = await hmacHex(env.ADMIN_TOKEN, "csrf:" + payload);
  return {
    cookie: `${SESSION_COOKIE}=${payload}.${signature}; Path=/admin; Max-Age=${SESSION_SECONDS}; HttpOnly; Secure; SameSite=Strict`,
    session: { payload, csrf },
  };
}

async function readSession(request: Request, env: AdminEnv): Promise<AdminSession | null> {
  if (!env.ADMIN_TOKEN) return null;
  const value = cookieValue(request, SESSION_COOKIE);
  if (!value) return null;
  const parts = value.split(".");
  if (parts.length !== 3) return null;
  const [expiresText, nonce, signature] = parts;
  if (!/^\d+$/.test(expiresText) || !/^[a-f0-9]{32}$/.test(nonce) || !/^[a-f0-9]{64}$/.test(signature)) {
    return null;
  }
  const expires = Number(expiresText);
  if (!Number.isSafeInteger(expires) || expires <= Math.floor(Date.now() / 1000)) return null;
  const payload = `${expiresText}.${nonce}`;
  const expected = await hmacHex(env.ADMIN_TOKEN, payload);
  if (!(await secureEqual(signature, expected))) return null;
  return { payload, csrf: await hmacHex(env.ADMIN_TOKEN, "csrf:" + payload) };
}

async function validCsrf(form: FormData, session: AdminSession): Promise<boolean> {
  const value = form.get("csrf");
  return typeof value === "string" && (await secureEqual(value, session.csrf));
}

async function audit(env: AdminEnv, eventType: string, subjectId: string | null, detail: string | null): Promise<void> {
  try {
    await env.DB.prepare(
      "INSERT INTO audit_log(event_type, subject_id, detail, created_at) VALUES (?, ?, ?, ?)"
    ).bind(eventType, subjectId, detail, new Date().toISOString()).run();
  } catch {
  }
}

function shell(title: string, main: string): string {
  return `<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:72rem;margin:0 auto;padding:1.25rem;line-height:1.5}
header,main,section{margin-bottom:2rem}
nav{display:flex;gap:1rem;align-items:center;flex-wrap:wrap}
form.inline{display:inline}
label{display:block;font-weight:600;margin-top:.8rem}
input,select,button{font:inherit;padding:.55rem;max-width:100%;box-sizing:border-box}
input[type="text"],input[type="password"],input[type="number"],select{width:28rem}
button{cursor:pointer}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid currentColor;padding:.5rem;text-align:left;vertical-align:top}
th{font-weight:700}
.notice{border:2px solid currentColor;padding:1rem}
.actions{white-space:nowrap}
code{font-family:ui-monospace,Consolas,monospace}
.sr-note{font-size:.95rem}
</style>
</head>
<body>
${main}
</body>
</html>`;
}

function loginPage(message?: string): Response {
  const notice = message ? `<p class="notice" role="alert">${escapeHtml(message)}</p>` : "";
  return htmlResponse(shell("FarRelay Tester Manager", `
<main>
<h1>FarRelay Tester Manager</h1>
<p>Sign in with the FarRelay administrator token. The dashboard does not store the token in JavaScript or local storage.</p>
${notice}
<form method="post" action="/admin/login">
<label for="admin-token">Administrator token</label>
<input id="admin-token" name="admin_token" type="password" required autocomplete="current-password">
<p><button type="submit">Sign in</button></p>
</form>
</main>`));
}

function timeValue(value: string | null): string {
  return value ? `<time datetime="${escapeHtml(value)}">${escapeHtml(value)}</time>` : "Never";
}

function inviteStatus(invite: DashboardInvite): string {
  if (invite.revoked_at) return "Revoked";
  if (invite.expires_at && Date.parse(invite.expires_at) <= Date.now()) return "Expired";
  if (invite.activation_count >= invite.max_activations) return "Used";
  return "Active";
}

function noticeFromUrl(url: URL): string | null {
  switch (url.searchParams.get("notice")) {
    case "invite-revoked": return "Invitation revoked.";
    case "device-revoked": return "Device revoked.";
    case "settings-saved": return "Beta program settings saved.";
    default: return null;
  }
}

async function renderDashboard(
  request: Request,
  env: AdminEnv,
  session: AdminSession,
  created?: CreatedInvite,
  errorMessage?: string
): Promise<Response> {
  const [inviteResult, deviceResult, releaseResult, settingsResult, feedbackResult] = await Promise.all([
    env.DB.prepare(
      "SELECT id, label, channel, max_activations, activation_count, access_days, requested_device, expires_at, revoked_at, created_at FROM invites ORDER BY created_at DESC"
    ).all<DashboardInvite>(),
    env.DB.prepare(
      "SELECT id, label, channel, created_at, last_seen_at, access_expires_at, revoked_at FROM devices ORDER BY created_at DESC"
    ).all<DashboardDevice>(),
    env.DB.prepare(
      "SELECT channel, version, published_at FROM releases ORDER BY channel"
    ).all<DashboardRelease>(),
    env.DB.prepare(
      "SELECT key, value FROM program_settings WHERE key IN ('testflight_url','feedback_url','feedback_notification_email','feedback_from_email','public_enrollment_enabled','public_enrollment_access_days','public_enrollment_invite_hours','public_enrollment_max_signups')"
    ).all<{ key: string; value: string }>(),
    env.DB.prepare(
      "SELECT id, tester_name, category, message, contact, source, created_at FROM beta_feedback ORDER BY created_at DESC LIMIT 100"
    ).all<DashboardFeedback>(),
  ]);

  const programSettings = new Map(settingsResult.results.map((row) => [row.key, row.value]));
  const testflightUrl = programSettings.get("testflight_url") || "";
  const feedbackUrl = programSettings.get("feedback_url") || "";
  const feedbackNotificationEmail = programSettings.get("feedback_notification_email") || "";
  const feedbackFromEmail = programSettings.get("feedback_from_email") || "";
  const publicEnrollmentEnabled = programSettings.get("public_enrollment_enabled") === "true";
  const publicEnrollmentAccessDays = Number(programSettings.get("public_enrollment_access_days") || "30");
  const publicEnrollmentInviteHours = Number(programSettings.get("public_enrollment_invite_hours") || "168");
  const publicEnrollmentMaxSignups = Number(programSettings.get("public_enrollment_max_signups") || "100");
  const publicEnrollmentUrl = new URL("/join", request.url).origin + "/join";

  const url = new URL(request.url);
  const notice = errorMessage || noticeFromUrl(url);
  const noticeHtml = notice
    ? `<p class="notice" role="${errorMessage ? "alert" : "status"}">${escapeHtml(notice)}</p>`
    : "";

  const createdHtml = created ? `
<section class="notice" aria-labelledby="created-heading">
<h2 id="created-heading">Invitation created</h2>
<p><strong>This activation code is shown only once.</strong></p>
<p>Tester: ${escapeHtml(created.label)}; channel: ${escapeHtml(created.channel)}; installer invitation expires: ${timeValue(created.expiresAt)}; beta access after activation: ${created.accessDays} day(s).</p>
<label for="created-code">Activation code</label>
<input id="created-code" type="text" readonly value="${escapeHtml(created.activationCode)}">
<label for="created-link">Tester onboarding link</label>
<input id="created-link" type="text" readonly value="${escapeHtml(created.installerUrl)}">
<p><a href="${escapeHtml(created.installerUrl)}">Open tester onboarding page</a></p>
</section>` : "";

  const inviteRows = inviteResult.results.map((invite) => {
    const revoke = invite.revoked_at ? "" : `
<form class="inline" method="post" action="/admin/ui/invites/${encodeURIComponent(invite.id)}/revoke">
<input type="hidden" name="csrf" value="${escapeHtml(session.csrf)}">
<button type="submit">Revoke</button>
</form>`;
    return `<tr>
<td>${escapeHtml(invite.label)}</td>
<td>${escapeHtml(invite.channel)}</td>
<td>${escapeHtml(invite.requested_device || "")}</td>
<td>${escapeHtml(inviteStatus(invite))}</td>
<td>${invite.activation_count}/${invite.max_activations}</td>
<td>${timeValue(invite.expires_at)}</td>
<td>${invite.access_days} day(s)</td>
<td class="actions">${revoke}</td>
</tr>`;
  }).join("");

  const deviceRows = deviceResult.results.map((device) => {
    const revoke = device.revoked_at ? "" : `
<form class="inline" method="post" action="/admin/ui/devices/${encodeURIComponent(device.id)}/revoke">
<input type="hidden" name="csrf" value="${escapeHtml(session.csrf)}">
<button type="submit">Revoke</button>
</form>`;
    return `<tr>
<td>${escapeHtml(device.label)}</td>
<td>${escapeHtml(device.channel)}</td>
<td>${device.revoked_at ? "Revoked" : "Active"}</td>
<td>${timeValue(device.last_seen_at)}</td>
<td>${timeValue(device.created_at)}</td>
<td>${timeValue(device.access_expires_at)}</td>
<td class="actions">${revoke}</td>
</tr>`;
  }).join("");

  const releaseRows = releaseResult.results.map((release) => `<tr>
<td>${escapeHtml(release.channel)}</td>
<td>${escapeHtml(release.version)}</td>
<td>${timeValue(release.published_at)}</td>
</tr>`).join("");

  const feedbackRows = feedbackResult.results.map((item) => `<tr>
<td>${escapeHtml(item.tester_name)}</td>
<td>${escapeHtml(item.category)}</td>
<td>${escapeHtml(item.message)}</td>
<td>${escapeHtml(item.contact || "")}</td>
<td>${escapeHtml(item.source)}</td>
<td>${timeValue(item.created_at)}</td>
</tr>`).join("");

  return htmlResponse(shell("FarRelay Tester Manager", `
<header>
<nav aria-label="Dashboard">
<strong>FarRelay Tester Manager</strong>
<a href="#create-invite">Create invitation</a>
<a href="#invitations">Invitations</a>
<a href="#devices">Devices</a>
<a href="#program-settings">Program settings</a>
<a href="#feedback">Feedback</a>
<form class="inline" method="post" action="/admin/logout">
<input type="hidden" name="csrf" value="${escapeHtml(session.csrf)}">
<button type="submit">Sign out</button>
</form>
</nav>
</header>
<main>
<h1>Beta distribution dashboard</h1>
${noticeHtml}
${createdHtml}
<section id="create-invite" aria-labelledby="create-heading">
<h2 id="create-heading">Create invitation</h2>
<form method="post" action="/admin/ui/invites">
<input type="hidden" name="csrf" value="${escapeHtml(session.csrf)}">
<label for="label">Tester name</label>
<input id="label" name="label" type="text" maxlength="120" required>
<label for="channel">Release channel</label>
<select id="channel" name="channel">
<option value="beta" selected>Beta</option>
<option value="stable">Stable</option>
</select>
<label for="max-activations">Maximum activations</label>
<input id="max-activations" name="max_activations" type="number" min="1" max="10" value="1" required>
<label for="expires-hours">Installer invitation expires after hours</label>
<input id="expires-hours" name="expires_in_hours" type="number" min="1" max="720" value="168" required>
<p class="sr-note">168 hours is 7 days. This controls how long the installer invitation can be redeemed.</p>
<label for="access-days">Beta access after activation, days</label>
<input id="access-days" name="access_days" type="number" min="1" max="365" value="30" required>
<p class="sr-note">The beta access clock starts when the tester activates FarRelay on a computer.</p>
<p><button type="submit">Create invitation</button></p>
</form>
</section>
<section aria-labelledby="releases-heading">
<h2 id="releases-heading">Published releases</h2>
${releaseRows ? `<table><thead><tr><th scope="col">Channel</th><th scope="col">Version</th><th scope="col">Published</th></tr></thead><tbody>${releaseRows}</tbody></table>` : "<p>No releases published.</p>"}
</section>
<section id="program-settings" aria-labelledby="program-settings-heading">
<h2 id="program-settings-heading">Beta program settings</h2>
<form method="post" action="/admin/ui/settings">
<input type="hidden" name="csrf" value="${escapeHtml(session.csrf)}">
<label for="testflight-url">TestFlight join link</label>
<input id="testflight-url" name="testflight_url" type="text" inputmode="url" value="${escapeHtml(testflightUrl)}" placeholder="https://testflight.apple.com/join/...">
<label for="feedback-url">External feedback link (optional)</label>
<input id="feedback-url" name="feedback_url" type="text" inputmode="url" value="${escapeHtml(feedbackUrl)}" placeholder="https://...">
<p class="sr-note">Leave this blank to use FarRelay's built-in feedback form. If supplied, this HTTPS link overrides the built-in form for testers.</p>
<h3>Feedback email notifications</h3>
<p>Optional. Feedback is always saved to the dashboard first. Email notifications require a Cloudflare Email Service binding named EMAIL.</p>
<label for="feedback-notification-email">Send new feedback notifications to</label>
<input id="feedback-notification-email" name="feedback_notification_email" type="text" inputmode="email" value="${escapeHtml(feedbackNotificationEmail)}" placeholder="you@example.com">
<label for="feedback-from-email">Notification sender address</label>
<input id="feedback-from-email" name="feedback_from_email" type="text" inputmode="email" value="${escapeHtml(feedbackFromEmail)}" placeholder="feedback@yourdomain.com">
<p class="sr-note">The destination must be verified in Cloudflare Email Service. The sender must belong to a domain onboarded to Cloudflare Email Service.</p>
<h3>Public tester enrollment</h3>
<p>This creates one shareable forum link. Each person enters their own name and Windows PC/laptop type, then receives a personal one-use invitation and personalized onboarding page.</p>
<label for="public-enrollment-enabled">Public enrollment</label>
<select id="public-enrollment-enabled" name="public_enrollment_enabled">
<option value="false"${publicEnrollmentEnabled ? "" : " selected"}>Disabled</option>
<option value="true"${publicEnrollmentEnabled ? " selected" : ""}>Enabled</option>
</select>
<label for="public-enrollment-access-days">Beta access after activation, days</label>
<input id="public-enrollment-access-days" name="public_enrollment_access_days" type="number" min="1" max="365" value="${escapeHtml(publicEnrollmentAccessDays)}" required>
<label for="public-enrollment-invite-hours">Generated invitation expires after hours</label>
<input id="public-enrollment-invite-hours" name="public_enrollment_invite_hours" type="number" min="1" max="720" value="${escapeHtml(publicEnrollmentInviteHours)}" required>
<label for="public-enrollment-max-signups">Maximum public signups</label>
<input id="public-enrollment-max-signups" name="public_enrollment_max_signups" type="number" min="1" max="10000" value="${escapeHtml(publicEnrollmentMaxSignups)}" required>
<label for="public-enrollment-link">Public tester signup link</label>
<input id="public-enrollment-link" type="text" readonly value="${escapeHtml(publicEnrollmentUrl)}">
<p><a href="${escapeHtml(publicEnrollmentUrl)}">Open public tester signup page</a></p>
<p class="sr-note">FarRelay also limits the same browser/network to three generated invitations per 24 hours. Disable public enrollment at any time to close the signup page immediately.</p>
<p><button type="submit">Save beta program settings</button></p>
</form>
</section>
<section id="invitations" aria-labelledby="invites-heading">
<h2 id="invites-heading">Invitations</h2>
${inviteRows ? `<table><thead><tr><th scope="col">Tester</th><th scope="col">Channel</th><th scope="col">Requested PC</th><th scope="col">Status</th><th scope="col">Activations</th><th scope="col">Invitation expires</th><th scope="col">Beta access</th><th scope="col">Action</th></tr></thead><tbody>${inviteRows}</tbody></table>` : "<p>No invitations yet.</p>"}
</section>
<section id="devices" aria-labelledby="devices-heading">
<h2 id="devices-heading">Devices</h2>
${deviceRows ? `<table><thead><tr><th scope="col">Device</th><th scope="col">Channel</th><th scope="col">Status</th><th scope="col">Last seen</th><th scope="col">Activated</th><th scope="col">Beta access expires</th><th scope="col">Action</th></tr></thead><tbody>${deviceRows}</tbody></table>` : "<p>No devices yet.</p>"}
</section>
<section id="feedback" aria-labelledby="feedback-heading">
<h2 id="feedback-heading">Beta feedback</h2>
${feedbackRows ? `<table><thead><tr><th scope="col">Tester</th><th scope="col">Type</th><th scope="col">Message</th><th scope="col">Contact</th><th scope="col">Source</th><th scope="col">Received</th></tr></thead><tbody>${feedbackRows}</tbody></table>` : "<p>No beta feedback yet.</p>"}
</section>
</main>`));
}

async function handleLogin(request: Request, env: AdminEnv): Promise<Response> {
  if (!env.ADMIN_TOKEN) return loginPage("The dashboard administrator secret is not configured.");
  const form = await request.formData().catch(() => null);
  const token = form?.get("admin_token");
  if (typeof token !== "string" || !(await secureEqual(token, env.ADMIN_TOKEN))) {
    return loginPage("Invalid administrator token.");
  }
  const { cookie } = await createSession(env);
  await audit(env, "admin_login", null, null);
  return redirect("/admin", 303, { "set-cookie": cookie });
}

async function createInvite(
  request: Request,
  env: AdminEnv,
  session: AdminSession
): Promise<Response> {
  const form = await request.formData().catch(() => null);
  if (!form || !(await validCsrf(form, session))) {
    return htmlResponse(shell("Forbidden", "<main><h1>Forbidden</h1><p>The form session is invalid or expired.</p></main>"), 403);
  }
  const labelValue = form.get("label");
  const channelValue = form.get("channel");
  const maxValue = Number(form.get("max_activations"));
  const hoursValue = Number(form.get("expires_in_hours"));
  const accessDaysValue = Number(form.get("access_days"));
  const label = typeof labelValue === "string" ? labelValue.trim() : "";
  const channel = channelValue === "beta" || channelValue === "stable" ? channelValue : null;
  if (!label || !channel || !Number.isInteger(maxValue) || maxValue < 1 || maxValue > 10 ||
      !Number.isFinite(hoursValue) || hoursValue <= 0 || hoursValue > 720 ||
      !Number.isInteger(accessDaysValue) || accessDaysValue < 1 || accessDaysValue > 365) {
    return renderDashboard(request, env, session, undefined, "Check the tester name, channel, activation limit, invitation expiration, and beta access duration.");
  }

  const code = "FR-" + channel.toUpperCase() + "-" + randomText(10).toUpperCase();
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const expiresAt = new Date(Date.now() + hoursValue * 3600000).toISOString();
  await env.DB.prepare(
    "INSERT INTO invites(id, code_hash, label, channel, max_activations, activation_count, access_days, expires_at, created_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)"
  ).bind(id, await sha256Hex(code.trim().toUpperCase()), label.slice(0, 120), channel, maxValue, accessDaysValue, expiresAt, now).run();
  await audit(env, "invite_created", id, label.slice(0, 120));
  const origin = new URL(request.url).origin;
  return renderDashboard(request, env, session, {
    label: label.slice(0, 120),
    channel,
    activationCode: code,
    installerUrl: origin + "/invite/" + encodeURIComponent(code),
    expiresAt,
    accessDays: accessDaysValue,
  });
}


async function saveProgramSettings(
  request: Request,
  env: AdminEnv,
  session: AdminSession
): Promise<Response> {
  const form = await request.formData().catch(() => null);
  if (!form || !(await validCsrf(form, session))) {
    return htmlResponse(shell("Forbidden", "<main><h1>Forbidden</h1><p>The form session is invalid or expired.</p></main>"), 403);
  }
  const testflight = typeof form.get("testflight_url") === "string" ? String(form.get("testflight_url")).trim() : "";
  const feedback = typeof form.get("feedback_url") === "string" ? String(form.get("feedback_url")).trim() : "";
  const feedbackNotificationEmail = typeof form.get("feedback_notification_email") === "string" ? String(form.get("feedback_notification_email")).trim() : "";
  const feedbackFromEmail = typeof form.get("feedback_from_email") === "string" ? String(form.get("feedback_from_email")).trim() : "";
  const publicEnrollmentEnabled = form.get("public_enrollment_enabled") === "true";
  const publicEnrollmentAccessDays = Number(form.get("public_enrollment_access_days"));
  const publicEnrollmentInviteHours = Number(form.get("public_enrollment_invite_hours"));
  const publicEnrollmentMaxSignups = Number(form.get("public_enrollment_max_signups"));
  for (const pair of [["TestFlight", testflight], ["feedback", feedback]] as const) {
    const name = pair[0];
    const value = pair[1];
    if (value && !/^https:\/\//i.test(value)) {
      return renderDashboard(request, env, session, undefined, name + " link must use HTTPS.");
    }
  }
  const emailPattern = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
  if (feedbackNotificationEmail && !emailPattern.test(feedbackNotificationEmail)) {
    return renderDashboard(request, env, session, undefined, "Feedback notification email is not valid.");
  }
  if (feedbackFromEmail && !emailPattern.test(feedbackFromEmail)) {
    return renderDashboard(request, env, session, undefined, "Feedback sender email is not valid.");
  }
  if (!Number.isInteger(publicEnrollmentAccessDays) || publicEnrollmentAccessDays < 1 || publicEnrollmentAccessDays > 365 ||
      !Number.isInteger(publicEnrollmentInviteHours) || publicEnrollmentInviteHours < 1 || publicEnrollmentInviteHours > 720 ||
      !Number.isInteger(publicEnrollmentMaxSignups) || publicEnrollmentMaxSignups < 1 || publicEnrollmentMaxSignups > 10000) {
    return renderDashboard(request, env, session, undefined, "Check the public enrollment access days, invitation hours, and signup limit.");
  }
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('testflight_url', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(testflight, now),
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('feedback_url', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(feedback, now),
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('feedback_notification_email', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(feedbackNotificationEmail, now),
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('feedback_from_email', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(feedbackFromEmail, now),
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('public_enrollment_enabled', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(publicEnrollmentEnabled ? "true" : "false", now),
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('public_enrollment_access_days', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(String(publicEnrollmentAccessDays), now),
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('public_enrollment_invite_hours', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(String(publicEnrollmentInviteHours), now),
    env.DB.prepare(
      "INSERT INTO program_settings(key, value, updated_at) VALUES ('public_enrollment_max_signups', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    ).bind(String(publicEnrollmentMaxSignups), now),
  ]);
  await audit(env, "program_settings_updated", null, null);
  return redirect("/admin?notice=settings-saved");
}

async function revoke(
  request: Request,
  env: AdminEnv,
  session: AdminSession,
  kind: "invite" | "device",
  id: string
): Promise<Response> {
  const form = await request.formData().catch(() => null);
  if (!form || !(await validCsrf(form, session))) {
    return htmlResponse(shell("Forbidden", "<main><h1>Forbidden</h1><p>The form session is invalid or expired.</p></main>"), 403);
  }
  const now = new Date().toISOString();
  const table = kind === "invite" ? "invites" : "devices";
  const result = await env.DB.prepare(
    `UPDATE ${table} SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`
  ).bind(now, id).run();
  if (Number(result.meta.changes ?? 0) !== 1) {
    return renderDashboard(request, env, session, undefined, `Active ${kind} not found.`);
  }
  await audit(env, kind === "invite" ? "invite_revoked" : "device_revoked", id, "dashboard");
  return redirect(`/admin?notice=${kind}-revoked`);
}

export async function handleAdminUi(request: Request, env: AdminEnv): Promise<Response | null> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (request.method === "GET" && path === "/") return redirect("/admin");
  if (request.method === "GET" && path === "/admin/login") return loginPage();
  if (request.method === "POST" && path === "/admin/login") return handleLogin(request, env);

  const isUiPath =
    path === "/admin" ||
    path === "/admin/logout" ||
    path === "/admin/ui/invites" ||
    path === "/admin/ui/settings" ||
    /^\/admin\/ui\/invites\/[^/]+\/revoke$/.test(path) ||
    /^\/admin\/ui\/devices\/[^/]+\/revoke$/.test(path);

  if (!isUiPath) return null;

  const session = await readSession(request, env);
  if (!session) return loginPage("Sign in to continue.");

  if (request.method === "GET" && path === "/admin") return renderDashboard(request, env, session);

  if (request.method === "POST" && path === "/admin/logout") {
    const form = await request.formData().catch(() => null);
    if (!form || !(await validCsrf(form, session))) {
      return htmlResponse(shell("Forbidden", "<main><h1>Forbidden</h1><p>The form session is invalid or expired.</p></main>"), 403);
    }
    await audit(env, "admin_logout", null, null);
    return redirect("/admin", 303, {
      "set-cookie": `${SESSION_COOKIE}=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Strict`,
    });
  }

  if (request.method === "POST" && path === "/admin/ui/invites") {
    return createInvite(request, env, session);
  }

  if (request.method === "POST" && path === "/admin/ui/settings") {
    return saveProgramSettings(request, env, session);
  }

  const inviteMatch = path.match(/^\/admin\/ui\/invites\/([^/]+)\/revoke$/);
  if (request.method === "POST" && inviteMatch) {
    return revoke(request, env, session, "invite", decodeURIComponent(inviteMatch[1]));
  }

  const deviceMatch = path.match(/^\/admin\/ui\/devices\/([^/]+)\/revoke$/);
  if (request.method === "POST" && deviceMatch) {
    return revoke(request, env, session, "device", decodeURIComponent(deviceMatch[1]));
  }

  return htmlResponse(shell("Method not allowed", "<main><h1>Method not allowed</h1></main>"), 405);
}

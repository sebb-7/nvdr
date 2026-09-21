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
  expires_at: string | null;
  revoked_at: string | null;
}

interface DeviceRow {
  id: string;
  label: string;
  channel: Channel;
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
    "SELECT id, label, channel, max_activations, activation_count, expires_at, revoked_at FROM invites WHERE code_hash = ?"
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
    "SELECT id, label, channel, revoked_at FROM devices WHERE token_hash = ?"
  ).bind(hash).first<DeviceRow>();
  if (!device || device.revoked_at) return null;
  await env.DB.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?")
    .bind(new Date().toISOString(), device.id).run();
  return device;
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
    "INSERT INTO invites(id, code_hash, label, channel, max_activations, activation_count, expires_at, created_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?)"
  ).bind(id, await sha256Hex(code), body.label.trim(), body.channel, maxActivations, expiresAt, now).run();
  await audit(env, "invite_created", id, body.label.trim());
  const origin = new URL(request.url).origin;
  return json({
    id,
    label: body.label.trim(),
    channel: body.channel,
    activation_code: code,
    installer_url: origin + "/invite/" + encodeURIComponent(code) + "/installer",
    expires_at: expiresAt,
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

  const results = await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO devices(id, invite_id, label, token_hash, channel, created_at) SELECT ?, id, ?, ?, channel, ? FROM invites WHERE id = ? AND revoked_at IS NULL AND activation_count < max_activations AND (expires_at IS NULL OR expires_at > ?)"
    ).bind(deviceId, body.device_name.trim().slice(0, 120) || "Windows device", tokenHash, now, invite.id, now),
    env.DB.prepare(
      "UPDATE invites SET activation_count = activation_count + 1 WHERE id = ? AND EXISTS (SELECT 1 FROM devices WHERE id = ?)"
    ).bind(invite.id, deviceId),
  ]);
  if (!results[0].success || Number(results[0].meta.changes ?? 0) !== 1 || !results[1].success || Number(results[1].meta.changes ?? 0) !== 1) {
    return error("tester invitation could not be activated", 409);
  }
  await audit(env, "device_activated", deviceId, invite.id);
  return json({ device_id: deviceId, device_token: token, channel: invite.channel }, 201);
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
    "SELECT id, label, channel, created_at, last_seen_at, revoked_at FROM devices ORDER BY created_at DESC"
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
    "SELECT id, label, channel, max_activations, activation_count, expires_at, revoked_at, created_at FROM invites ORDER BY created_at DESC"
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

    const installerMatch = path.match(/^\/invite\/([^/]+)\/installer$/);
    if (request.method === "GET" && installerMatch) return downloadInstaller(env, decodeURIComponent(installerMatch[1]));

    if (request.method === "GET" && path === "/v1/invite/validate") {
      const invite = await inviteForCode(env, url.searchParams.get("code") || "");
      return inviteIsUsable(invite) ? new Response(null, { status: 204 }) : error("tester invitation is invalid", 403);
    }

    if (request.method === "POST" && path === "/v1/activate") return activate(request, env);
    if (request.method === "GET" && path === "/v1/manifest") return manifest(request, env);

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

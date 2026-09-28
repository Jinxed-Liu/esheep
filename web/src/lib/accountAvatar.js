const bucket = "account-avatars";
const maximumBytes = 60 * 1024;

function avatarPath(userID) {
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(userID ?? "")) {
    throw new Error("当前登录账号无效。");
  }
  return `${userID.toLowerCase()}/avatar.jpg`;
}

async function profileFor(client, userID) {
  const { data, error } = await client.from("profiles")
    .select("avatar_digest,avatar_revision")
    .eq("user_id", userID).single();
  if (error) throw error;
  return data;
}

async function digestFor(blob) {
  const bytes = await blob.arrayBuffer();
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(hash)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function readAccountAvatar(client, userID, previous = {}) {
  const profile = await profileFor(client, userID);
  const revision = Number(profile.avatar_revision);
  const digest = profile.avatar_digest;
  if (previous.revision === revision && previous.digest === digest) {
    return { revision, digest, unchanged: true };
  }
  if (!digest) return { revision, digest: null, blob: null };
  const { data: blob, error } = await client.storage.from(bucket).download(avatarPath(userID),
    { cacheNonce: String(revision) });
  if (error) throw error;
  if (await digestFor(blob) !== digest) throw new Error("云端头像内容校验失败，请稍后重试。");
  return { revision, digest, blob };
}

export async function uploadAccountAvatar(client, userID, blob) {
  if (blob.type !== "image/jpeg" || blob.size > maximumBytes || blob.size === 0) {
    throw new Error("头像必须是小于 60 KB 的 JPEG 图片。");
  }
  const profile = await profileFor(client, userID);
  const digest = await digestFor(blob);
  const { error: uploadError } = await client.storage.from(bucket).upload(avatarPath(userID), blob,
    { contentType: "image/jpeg", upsert: true, cacheControl: "3600" });
  if (uploadError) throw uploadError;
  const { data, error } = await client.from("profiles")
    .update({ avatar_digest: digest, avatar_revision: Number(profile.avatar_revision) + 1,
      updated_at: new Date().toISOString() })
    .eq("user_id", userID).select("avatar_digest,avatar_revision").single();
  if (error) throw error;
  if (data.avatar_digest !== digest) throw new Error("头像云端校验失败，请重试。");
  return data;
}

export async function prepareAccountAvatar(file) {
  if (!file?.type?.startsWith("image/")) throw new Error("请选择图片文件。");
  const bitmap = await createImageBitmap(file);
  try {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 384;
    const context = canvas.getContext("2d");
    const side = Math.min(bitmap.width, bitmap.height);
    context.drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2,
      side, side, 0, 0, 384, 384);
    for (let quality = 0.82; quality >= 0.3; quality -= 0.1) {
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
      if (blob && blob.size <= maximumBytes) return blob;
    }
    throw new Error("图片压缩后仍超过头像大小限制，请选择另一张照片。");
  } finally {
    bitmap.close();
  }
}

import { useEffect, useState } from "react";
import { readAccountAvatar } from "../lib/accountAvatar.js";

export const accountAvatarChangedEvent = "esheep-account-avatar-changed";

export function AccountAvatar({ userID, name, className = "" }) {
  const [image, setImage] = useState(null);

  useEffect(() => {
    if (!userID) return undefined;
    let active = true;
    let busy = false;
    let pending = false;
    let objectURL = null;
    let previous = {};

    async function refresh() {
      if (!active || document.visibilityState === "hidden") return;
      if (busy) { pending = true; return; }
      busy = true;
      try {
        const { supabase } = await import("../lib/supabase.js");
        const result = await readAccountAvatar(supabase, userID, previous);
        if (!active || result.unchanged) return;
        previous = { revision: result.revision, digest: result.digest };
        const nextURL = result.blob ? URL.createObjectURL(result.blob) : null;
        const oldURL = objectURL;
        objectURL = nextURL;
        setImage({ userID, url: nextURL });
        if (oldURL) URL.revokeObjectURL(oldURL);
      } catch (error) {
        if (active) console.warn("账号头像同步失败", error);
      } finally {
        busy = false;
        if (pending && active) {
          pending = false;
          void refresh();
        }
      }
    }

    void refresh();
    const interval = window.setInterval(refresh, 60_000);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    window.addEventListener(accountAvatarChangedEvent, refresh);
    return () => {
      active = false;
      window.clearInterval(interval);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
      window.removeEventListener(accountAvatarChangedEvent, refresh);
      if (objectURL) URL.revokeObjectURL(objectURL);
    };
  }, [userID]);

  return image?.userID === userID && image.url
    ? <img className={className} src={image.url} alt="" />
    : <div className={`account-avatar-fallback ${className}`} aria-hidden="true">{name?.trim()?.[0] || "羊"}</div>;
}

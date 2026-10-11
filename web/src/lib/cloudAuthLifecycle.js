function contextChangedError() {
  const error = new Error("登录账号已变化，原请求已取消。");
  error.name = "AbortError";
  return error;
}

// Auth notifications are synchronous. Defer SDK calls until its notification
// callback has returned, and bind every private read to an identity generation.
export function createCloudAuthLifecycle({
  verifyUser, loadWorkspace, invalidate, clearPrivateState,
  onSignedOut, onWorkspace, onError, schedule = (run) => setTimeout(run, 0),
}) {
  let generation = 0;
  let userID;
  let verifiedUser = null;
  let active = true;
  let pending;

  const current = (token) => active && token === generation;
  const assertCurrent = (token) => {
    if (!current(token)) throw contextChangedError();
  };
  const beginChecking = () => {
    generation += 1;
    pending = null;
    invalidate();
    clearPrivateState();
    return generation;
  };

  function restore(options = {}) {
    if (!active) return Promise.resolve(null);
    if (pending?.generation === generation) return pending.promise;
    const token = generation;
    const expectedUserID = userID;
    const promise = (async () => {
      let user = null;
      try {
        user = await verifyUser();
        assertCurrent(token);
        if (expectedUserID !== undefined && (user?.id ?? null) !== expectedUserID) {
          throw contextChangedError();
        }
        userID = user?.id ?? null;
        verifiedUser = user;
        if (!user) {
          onSignedOut();
          return null;
        }
        const workspace = await loadWorkspace(options.farmID);
        assertCurrent(token);
        if (workspace?.profile?.userID !== user.id) throw contextChangedError();
        onWorkspace(workspace, user);
        return workspace;
      } catch (error) {
        if (!current(token)) return null;
        onError(error, user ?? (verifiedUser?.id === userID ? verifiedUser : null));
        throw error;
      } finally {
        if (pending?.generation === token) pending = null;
      }
    })();
    pending = { generation: token, promise };
    return promise;
  }

  function observe({ event, session }) {
    if (!active) return;
    if (event === "SIGNED_OUT" || (event === "INITIAL_SESSION" && !session)) {
      userID = null;
      verifiedUser = null;
      beginChecking();
      onSignedOut();
      return;
    }
    const nextUserID = session?.user?.id;
    if (!nextUserID || nextUserID === userID) return;
    userID = nextUserID;
    verifiedUser = null;
    const token = beginChecking();
    schedule(() => {
      if (current(token)) void restore().catch(() => {});
    });
  }

  return {
    observe, restore, beginChecking, current, assertCurrent,
    owns: (identity) => active && identity === userID,
    token: () => generation,
    refresh(options) { beginChecking(); return restore(options); },
    dispose() { active = false; generation += 1; invalidate(); },
  };
}

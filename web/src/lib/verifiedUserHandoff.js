// Hand a fresh Auth-server result to the immediately following workspace read.
// A copied/session-storage user is not a receipt, and each receipt is single-use.
export function createVerifiedUserHandoff(verify) {
  let epoch = 0;
  let receipts = new WeakMap();
  let identity;
  const invalidate = () => { epoch += 1; receipts = new WeakMap(); };
  return {
    async verify() {
      const started = epoch;
      const user = await verify();
      if (user && started === epoch && (identity === undefined || identity === user.id)) {
        identity = user.id;
        receipts.set(user, user.id);
      } else if (!user && started === epoch) invalidate();
      return user;
    },
    async consume(user) {
      if (user && receipts.has(user) && receipts.get(user) === user.id) {
        receipts.delete(user);
        return user;
      }
      return verify();
    },
    observeIdentity(userID) {
      // SDK initialization announces the existing session while getUser is
      // pending. That announcement is not an account change or authorization.
      if (userID == null || (identity !== undefined && identity !== userID)) invalidate();
      identity = userID;
    },
    invalidate,
  };
}

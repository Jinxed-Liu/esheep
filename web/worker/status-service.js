import { backendStatusResponse } from "./backend-status.js";

export default {
  fetch(request, environment) {
    if (new URL(request.url).pathname !== "/api/backend-status") {
      return new Response(null, { status: 404 });
    }
    return backendStatusResponse(request, { ESHEEP_BACKEND_STATE: environment.ESHEEP_BACKEND_STATE || "unconfigured" });
  },
};

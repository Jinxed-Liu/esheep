// Stable, recoverable states shared by the Node runtime and edge gateway.
// Never return provider bodies, credentials or infrastructure exception text.
export function agentFailure(code, status, message, recovery = 'retry') {
  return Object.assign(new Error(message), { code, status, recovery });
}

export function modelFailure(status, providerCode = '') {
  if (status === 401) return agentFailure('AGENT_KEY_INVALID', 401, 'API Key 无效或已失效，请在助手设置中重新填写。', 'credentials');
  if (status === 403 || providerCode === 'model_not_found') return agentFailure('AGENT_MODEL_FORBIDDEN', 403, '当前 Key 无权使用所选模型，请在助手设置中更换模型或检查服务账号权限。', 'credentials');
  if (status === 402 || ['insufficient_quota', 'billing_hard_limit_reached', 'balance_not_enough'].includes(providerCode)) return agentFailure('AGENT_QUOTA_EXHAUSTED', 429, '模型 API 额度不足，请检查个人账号的用量与余额后手动重试。', 'quota');
  if (status === 429) return agentFailure('AGENT_RATE_LIMITED', 429, '模型请求暂时受限，请稍后手动重试。');
  return agentFailure('AGENT_MODEL_UNAVAILABLE', 503, `模型服务未完成请求（${status}），请稍后手动重试。`);
}

export function containerFailure(error) {
  if (error?.status === 401) return agentFailure('AGENT_AUTH_EXPIRED', 401, '登录状态已失效，请重新登录。', 'login');
  if (error?.status === 403) return agentFailure('AGENT_FARM_FORBIDDEN', 403, '你没有此牧场的访问权限。', 'farm');
  if (error?.status === 429 || /capacity|max[_ ]?instances|instance.*limit|limit.*instance|resource.*exhaust/i.test(String(error?.message ?? ''))) return agentFailure('AGENT_BUSY', 503, '助手当前繁忙，已达到现有服务容量。请稍后手动重试。');
  return agentFailure('AGENT_UNAVAILABLE', 503, '云端 Agent 暂时无法连接，请稍后手动重试。');
}

export const errorBody = error => ({ error: error.message, code: error.code, recovery: error.recovery, retryable: error.recovery === 'retry' });

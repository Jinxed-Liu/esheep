# eSheepNext Identity Worker

该 Worker 只负责账号、会话、设备公钥、牧场目录的不透明标识、成员角色、邀请、能力证书与删除审计。它不保存牧场名称或任何养殖业务数据。

## 本地准备

1. 复制 `.dev.vars.example` 为 `.dev.vars`，填入 Development 环境密钥。
2. 创建 D1 数据库并把数据库 ID 写入 `wrangler.jsonc`。
3. 依次运行 `npm install`、`npm run db:migrate:local`、`npm test`、`npm run dev`。
4. 部署前用 `wrangler secret put` 写入全部密钥，不要提交 `.dev.vars`。
5. 运行 `npm run deploy`。部署前置脚本会拒绝占位 D1 ID或缺少任何必需 Secret 的环境。

Development 使用 Cloudflare 免费套餐的系统默认 CPU 限制，不在 `wrangler.jsonc` 中设置仅付费套餐支持的自定义 `limits.cpu_ms`。当前 Development 地址为 `https://esheep-next-identity.esheep-next-dev.workers.dev`。

能力证书使用 P-256 私钥签发。App 中配置对应公钥后才会信任证书。Apple refresh token 使用 AES-256-GCM 加密，Session Refresh Token 仅以 SHA-256 哈希存储。

身份入口支持跨端账号和 Sign in with Apple：

- `POST /v1/auth/register`：注册账号名、密码和显示名称。
- `POST /v1/auth/password`：账号名与密码登录。
- `POST /v1/auth/apple`：使用 Apple identity token 与 authorization code 登录或创建账号。
- `POST /v1/auth/refresh`：轮换 Session Refresh Token。
- `POST /v1/auth/logout`：撤销当前服务器 Session；App 随后清除本机 Access/Refresh Token，但不删除账号、牧场或设备身份。

账号名执行 Unicode NFKC、去首尾空格和大小写归一化。密码不保存明文，使用每账号独立随机盐和 PBKDF2-SHA256 派生；连续五次错误后锁定十五分钟。当前 Development Worker 受免费 CPU 配额限制，使用 1,000 次迭代，仅用于 iOS/Android 联调；生产环境必须迁移到具备更高 CPU 配额的身份服务并提高迭代次数。iOS 和 Android 使用相同的 `/v1/auth/register` 与 `/v1/auth/password` 协议。

`GET /v1/health` 仅返回 Development 环境、服务版本和 D1 连通性。设备撤销使用 `DELETE /v1/devices/{deviceID}`，撤销设备证书并为该账号所在的有效牧场递增安全 generation。

## 安全边界

CKShare 的 read-write 参与者仍拥有 CloudKit 记录级写权限。能力证书、设备签名、隔离、审计和 checkpoint 恢复用于识别并缓解越权写入，不构成 CloudKit 服务端字段级权限。

# eSheep+ AI and International Transfer Notice

Version: 2026.09.01  
Updated: August 27, 2026

This notice prominently identifies overseas recipients, purposes, methods, categories, risks, and rights in addition to the Privacy Policy. **Necessary cloud processing and optional AI require separate, unchecked-by-default consents.**

## 1. Core cloud accounts, sync, and collaboration

- Recipient: Supabase, Inc./Supabase Pte. Ltd. and infrastructure subprocessors listed in the applicable DPA.
- Country or region: `{{SUPABASE_REGION_COUNTRY}}` (planned: Singapore; verify against the production console, contract, and subprocessor list before release).
- Contact and rights: contact `{{PRIVACY_EMAIL}}` first or use Supabase's official privacy channel for processing it controls.
- Purpose: authentication, database sync, private attachments, role collaboration, recovery, backups, and security audit.
- Method: encrypted direct connection from the app to the production Supabase project with account-, farm-, and role-scoped RLS/RPC controls.
- Categories: display name, email, user/device IDs, session security, farm location, memberships, farm content and attachments, and necessary IP, timestamp, request-status, and security logs.
- Retention: active service period and the deletion rules in the Privacy Policy; backup/security-log target maximum 30 days, subject to final production verification.
- Necessity: the current account, cloud sync, and collaboration functions depend on this infrastructure. Refusal or withdrawal stops new transfers and disables those cloud functions, without removing legally available export, closure, or local-data options.

## 2. Authentication email

- Recipient: `{{SMTP_PROVIDER}}`
- Country or region: `{{SMTP_REGION_COUNTRY}}`
- Purpose and categories: registration, recovery, and security email using the address, message content, delivery status, and necessary IP/time logs.
- Rights and retention: `{{SMTP_PRIVACY_URL}}`; `{{SMTP_RETENTION}}`.

Email registration must not launch until these fields are completed.

## 3. Optional MiMo AI

- External or overseas recipient: Xiaomi MiMo. Its July 7, 2026 Service Agreement says the platform is operated by Xiaomi Technologies Singapore Pte. Ltd. and also identifies Xiaomi Technology Netherlands B.V. and applicable affiliates. The actual API storage/processing region is `{{MIMO_API_REGION_COUNTRY}}` and must be confirmed in writing before release.
- Contact: MiMo's official Contact Us, `support-mimo@xiaomi.com`, and Xiaomi privacy-support channels, or `{{PRIVACY_EMAIL}}`.
- Purpose: answer intentional prompts, understand selected images/audio, and create a locally reviewable farm-action draft.
- Method: the user supplies a MiMo API key and the iPhone calls MiMo over encrypted transport; the eSheep server does not receive the readable key.
- Categories: intentional text, re-encoded images without original EXIF, recordings, conversation context, and limited authorized farm results for the current question. Broader sensitive detail receives a per-action prompt.
- Retention and training: governed by the current MiMo API policy. Privacy Policy version `v20260421` (stated update date: March 17, 2026) says API content is not used for model training or other purposes; we will update this notice if that rule changes.
- Optional: refusal does not affect non-AI records, sync, or export. Withdrawal stops new AI requests; the user can remove the local key and conversations.

## 4. Risks and safeguards

Other jurisdictions may have different privacy and government-access rules. Providers may suffer outages or unauthorized access and change subprocessors. Free text, images, or audio may unintentionally include unrelated personal data. AI can be wrong.

Safeguards include DPA/contract and subprocessor review, TLS, Keychain, RLS, private storage, role access, minimized queries, image re-encoding, voice retention off by default, human confirmation before writes, account deletion, and an incident plan. No measure eliminates all risk. Do not upload passwords, identity numbers, bank details, or human medical records.

## 5. Consent and withdrawal

Checking “Consent to necessary international processing” confirms separate consent for the core cloud scope above. AI requires another consent in AI settings and is not covered by the core-cloud checkbox.

Withdraw in settings or through `{{PRIVACY_EMAIL}}`. Withdrawal does not invalidate earlier lawful processing; we stop future transfers and explain feature impact, export, and deletion options.

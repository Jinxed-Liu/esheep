# eSheep+ Privacy Policy

Version: 2026.09.01  
Updated: August 27, 2026  
Effective: September 1, 2026

## Introduction and controller

eSheep+ is an iPhone and iPad application for sheep-farm operations, production records, analysis, and member collaboration. This policy explains how we process information relating to identifiable people. Animal health, breeding, and weight records are generally farm production data, but any names, phone numbers, voices, images, or other identifiers embedded in those records are treated as personal information.

Controller: `{{LEGAL_ENTITY}}`  
Registered address: `{{REGISTERED_ADDRESS}}`  
Privacy contact: `{{PRIVACY_OWNER}}`  
Email: `{{PRIVACY_EMAIL}}`  
Website: `https://{{DOMAIN}}/en/privacy`

These placeholders must be replaced with accurate, reachable details before release. Until then, this is a pre-release draft.

## 1. Information we process

1. **Account and identity data:** display name, email, the stable identifier returned by Sign in with Apple, any name a user allows Apple to provide, and eSheep account IDs. We use these for registration, sign-in, verification, recovery, security notices, and member identity. Passwords are verified by the authentication provider; the app does not store readable passwords.
2. **Device and security data:** an app-generated device UUID, device display name, public key, supported data-protocol version, session state, and security status. We use these to register and revoke devices, protect sessions, maintain sync compatibility, and recover data. Apple processes Face ID or Touch ID templates on the device; eSheep+ does not receive those templates.
3. **Farm and collaboration data:** farm name, address text, location explicitly saved by a user, time zone, memberships, roles, invitations, sheep, pens, weights, breeding, animal health, medication, feed, formulas, TMR batches, stock, costs, reminders, notes, attachments, and operation history. We use these for records, calculations, exports, sync, recovery, and role-based collaboration.
4. **Photos, files, and scans:** photos or selected media of sheep, symptoms, ear tags, receipts, QR codes, and files chosen for import. We do not scan the entire photo library. Images sent to AI are resized and re-encoded to remove original EXIF and location metadata.
5. **Location and weather data:** requested only while the app is in use when a user saves a farm location or uses a related weather feature. We use it for farm coordinates, time zone, and relevant weather, not continuous background tracking, advertising, or workforce movement profiles.
6. **Optional AI content:** a user's prompt, selected images, recorded audio, conversation history, and limited farm results returned by on-device tools for the current question. This is sent to MiMo only after a separate consent and an intentional send action. A user's MiMo API key remains in the local Keychain and is used by the device to authenticate directly to MiMo.
7. **Service and security records:** authentication, sync, database, object storage, email delivery, and deletion jobs may generate timestamps, request status, error codes, IP addresses, user/device identifiers, and limited security logs. We use these to prevent abuse, diagnose failures, audit access, restore service, and comply with law. Ordinary logs must not contain passwords, full tokens, or API keys.
8. **Support and rights requests:** contact details, communications, minimum identity-verification material, and request records, used to provide support and handle privacy rights and incidents.

System permissions—including camera, microphone, location, selected photos, calendars, reminders, notifications, nearby devices, and local network—are explained in the app. Refusing an optional permission does not disable unrelated features.

## 2. Purposes, methods, and legal bases

We receive information directly from users, generate limited identifiers locally, receive permitted data from Apple, receive actions from invited farm members, and generate necessary service records. We process it to:

- perform the Terms by providing accounts, offline records, sync, collaboration, imports/exports, recovery, and support;
- provide permission-based features such as location, media, microphone, calendars, reminders, notifications, AI, and legally required overseas transfers;
- comply with legal obligations and secure accounts and data;
- protect life, health, or property in a legally permitted emergency; and
- pursue other purposes permitted by applicable law.

If a purpose, method, or category changes materially, we update this policy and obtain renewed or separate consent when required.

## 3. On-device processing

Offline farm records, AI conversations, local import files, Keychain credentials and MiMo keys, and an optional copy of sent voice audio can remain solely on the device. Data that never leaves the device is not “collected” for Apple's App Privacy label, but it remains protected by this policy and device security.

Long-term retention of sent voice audio is off by default. A user may enable it in AI settings. Turning it off affects future recordings; existing copies can be removed with the relevant conversation or account data.

## 4. Processors, sharing, and disclosures

We do not sell personal information, serve third-party ads, use an advertising identifier, or track users across apps or websites.

We may use the following processors to provide the service:

- **Supabase, Inc./Supabase Pte. Ltd. and infrastructure subprocessors:** authentication, Postgres database, object storage, realtime delivery hints, backups, and security logs. The production region is `{{SUPABASE_REGION_COUNTRY}}` (planned: Singapore; verify against the production console before release).
- **`{{SMTP_PROVIDER}}`:** registration, recovery, and security email. The legal entity, location, and retention period must be completed before release.
- **Apple Inc. and applicable affiliates:** Sign in with Apple, legacy CloudKit migration, system notifications, maps/weather, and operating-system permissions, also governed by Apple's applicable terms.

We require processors to follow documented purposes, retention, confidentiality, and security obligations, and we review contracts, permissions, logs, and subprocessors. The published recipient list contains the current categories, links, locations, and status.

When an owner or administrator invites a farm member, that member can access only the current farm data allowed by their role. Inviters must have authority to share the data and revoke access when no longer needed.

We disclose personal information to another controller only when a user initiates it, it is necessary to perform the service, the law requires it, or an emergency lawful basis applies. Where required, we complete an impact assessment and obtain separate consent first.

## 5. AI assistant

The AI assistant is optional. A user supplies their own MiMo API key and separately accepts the AI data notice before first use.

- Recipient: Xiaomi MiMo. Its July 7, 2026 Service Agreement says the platform is operated by Xiaomi Technologies Singapore Pte. Ltd. and also identifies Xiaomi Technology Netherlands B.V. and applicable affiliates. The current API-content processing/storage region is `{{MIMO_API_REGION_COUNTRY}}` and requires written confirmation before release.
- Content sent: intentional prompts, processed images, audio, relevant conversation context, and limited farm results retrieved for that question. Broader or sensitive detail requires a per-action disclosure in the app.
- Never intentionally sent: passwords, Apple tokens, Supabase session secrets, the MiMo key itself, unselected photo-library content, or original import files.
- Human control: models can be wrong. AI does not directly execute a farm write; it creates a reviewable draft that an authorized user must verify and confirm. It is not veterinary, legal, or financial advice.
- Retention: eSheep+ stores conversations locally. Production does not sync AI history through the eSheep service unless the user explicitly enables a feature that visibly reports encrypted sync. MiMo retention follows its current API rules.
- Training: MiMo Privacy Policy version `v20260421` (stated update date: March 17, 2026) says API-submitted content is not used for model training or other purposes. We will recheck this commitment and update the notice if it changes.

Do not submit identity numbers, bank details, human medical records, passwords, API keys, or unrelated personal information to AI.

## 6. International transfers

Accounts, cloud sync, and AI may provide personal information outside Mainland China. The recipient, country or region, purpose, method, data categories, and rights channel are described in the separate International Transfer and AI Notice. The sign-in screen separates acceptance of the Terms/Privacy Policy from separate consent to necessary overseas processing; optional AI has its own consent.

We assess whether a security assessment, certification, standard contract filing, or other legal mechanism applies. This draft is not evidence that transfer formalities are complete until recipients, regions, contracts, volumes, and safeguards are verified. We will not provide personal information stored in China to a foreign judicial or law-enforcement authority without approval from the competent Chinese authority where required.

A user may withdraw transfer consent. Withdrawal does not invalidate earlier lawful processing. Because accounts and cloud collaboration depend on overseas infrastructure, we will stop new transfers after withdrawal and those functions may no longer work; we will provide available export, deletion, or local handling options required by law.

## 7. Retention and deletion

| Data | Retention method | End-of-life action |
|---|---|---|
| Local farm data, attachments, AI conversations | While the user keeps the relevant farm, conversation, or account | Remove local records and files; remove Keychain items through sign-out/deletion flows |
| Active accounts, members, and devices | While the account and service remain active | Revoke sessions, devices, and memberships, then run deletion |
| Cloud farm production records | While the farm exists and as needed for accounting, audit, and collaboration | Delete identifiable content when the farm is deleted; de-identify immutable operation history only when needed for ledger integrity |
| Account deletion job | Target completion within 24 hours after ownership blockers are resolved | Delete or de-identify and retain limited job status as compliance evidence |
| Backups, security and service logs | Shortest production-configured period; target maximum 30 days unless law or an active investigation requires longer | Rolling deletion or irreversible anonymization; storage and security only while deletion is deferred |
| Support and privacy-right records | Normally no longer than three years as needed to prove resolution | Delete or anonymize |
| Impact assessments and statutory records | Period required by law; impact-assessment records at least three years | Secure deletion or legal archive |

We delete or anonymize data when the purpose is achieved or impossible, it is no longer necessary, retention expires, consent is withdrawn, an account closes, or processing violates law or agreement. Where a statutory period has not expired or immediate deletion is technically infeasible, we stop all processing except storage and necessary protection.

## 8. Security

Measures include encrypted transport, iOS Keychain, device keys, Supabase row-level security and controlled RPCs, private storage buckets, role-based access, session revocation, image metadata removal, log minimization, backups, and recovery checks. No connected service can guarantee absolute security. If personal information is or may be leaked, altered, or lost, we will mitigate promptly and notify competent authorities and affected people when required, describing the data, cause, likely harm, actions, and contact channel.

## 9. Individual rights

Subject to applicable law, users may access, copy, explain, correct, supplement, delete, restrict, or transfer personal information; withdraw consent; leave a shared farm; request a role change; close an account; and complain about processing.

Use in-app settings or email `{{PRIVACY_EMAIL}}`. We conduct the minimum identity and authorization check and use 15 business days as an internal response target unless law requires otherwise. A refusal will include reasons and an escalation route. Owners must first export and transfer or delete owned farms so account closure does not harm other members or ledger integrity.

## 10. Children

The service is for farm operators and workers with full legal capacity and is not directed to children under 14. If we learn that information about a child under 14 was processed without valid guardian consent, we will suspend the processing, contact the guardian when appropriate, and delete it as required. A dedicated children's notice and guardian consent will precede any future child-directed service.

## 11. Changes

We publish each version, update date, and material changes in the app and on the website. Material changes to purposes, methods, categories, recipients, or individual rights may be communicated by prominent in-app notice or email, with renewed or separate consent where required. We retain prior versions and consent evidence as needed for compliance.

## 12. Contact and complaints

For privacy questions, rights requests, or incidents, contact `{{PRIVACY_EMAIL}}`. Users may also complain to the competent cybersecurity, data-protection, consumer, or other regulatory authority.

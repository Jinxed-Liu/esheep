# eSheep+ App Store Connect Privacy Questionnaire

Questionnaire version: 2026.09.01  
App version: 3.1.0  
Status: **Audited draft. Recheck the production Supabase project, SMTP service, current MiMo behavior, and Xcode archive privacy report before submission.**

## Apple interpretation

“Collected” means transmitted off the device and retained by the developer or a third party beyond the time needed to service the request in real time. On-device-only SwiftData, Keychain items, Face ID/Touch ID templates, Nearby Interaction distance, unsent imports, and calendar/reminder entries are not declared as collected. Third-party collection through Supabase, Apple, SMTP, or MiMo is included.

Every “Yes” row uses: **App Functionality; linked to the user; not used for tracking.** There are no ads, developer marketing, or cross-app/web tracking purposes.

| App Store category | Collected | Linked | Tracking | Purpose | Actual use |
|---|---:|---:|---:|---|---|
| Contact Info → Name | Yes | Yes | No | App Functionality | Display name and Apple-provided name |
| Contact Info → Email Address | Yes | Yes | No | App Functionality | Registration, verification, recovery, security, privacy requests |
| Contact Info → Physical Address | Yes | Yes | No | App Functionality | User-entered farm address, which may also be a personal business address |
| Contact Info → Phone Number | No | — | — | — | No required phone field |
| Health & Fitness | No | — | — | — | Animal records are not human HealthKit/medical data |
| Financial Info | No | — | — | — | No payment, card, credit, or financial-account collection |
| Location → Precise Location | Yes | Yes | No | App Functionality | Intentional farm coordinate and related weather |
| Location → Coarse Location | No separately | — | — | — | IP-derived service location is covered conservatively by identifiers/diagnostics |
| Sensitive Info | No | — | — | — | No designed fields for protected human characteristics |
| Contacts | No | — | — | — | No address-book access |
| User Content → Emails or Text Messages | No | — | — | — | Does not read device email or SMS |
| User Content → Photos or Videos | Yes | Yes | No | App Functionality | Intentional farm attachments and processed AI images |
| User Content → Audio Data | Yes | Yes | No | App Functionality | Intentional AI voice; long-term local retention off by default |
| User Content → Gameplay Content | No | — | — | — | Not a game |
| User Content → Customer Support | Yes | Yes | No | App Functionality | Support/privacy communications and minimum verification |
| User Content → Other User Content | Yes | Yes | No | App Functionality | Farm records, notes, imports, AI prompts/results, operation history |
| Browsing History | No | — | — | — | No browsing profile |
| Search History | No | — | — | — | Farm search is local; no remote search profile |
| Identifiers → User ID | Yes | Yes | No | App Functionality | Supabase Auth, eSheep account and membership/audit IDs |
| Identifiers → Device ID | Yes | Yes | No | App Functionality | App-generated device UUID, registered public key, service IP/security association; no IDFA |
| Purchases | No | — | — | — | No IAP/subscription; MiMo purchases are direct with MiMo |
| Usage Data → Product Interaction | No | — | — | — | No behavioral analytics SDK |
| Usage Data → Advertising Data | No | — | — | — | No ads |
| Usage Data → Other Usage Data | Yes | Yes | No | App Functionality | MiMo usage status and sync/deletion/security use state |
| Diagnostics → Crash Data | No | — | — | — | No third-party crash collection; recheck packaged dependencies |
| Diagnostics → Performance Data | No | — | — | — | Development/local tracing must not upload in production |
| Diagnostics → Other Diagnostic Data | Yes (conservative) | Yes | No | App Functionality | Auth/sync/database/storage/email errors, request time, IP/IDs, security logs |
| Surroundings | No | — | — | — | Intentional photos are user content, not ambient scanning |
| Body | No | — | — | — | No body/hand/head tracking |
| Other Data | No | — | — | — | Covered by specific categories above |

## Purpose and tracking answers

- App Functionality: **Yes** for every collected category.
- Third-Party Advertising: **No**.
- Developer Advertising or Marketing: **No**.
- Analytics: **No** for behavior analytics; operational security/diagnostics remain App Functionality.
- Product Personalization: **No** for App Store labeling; AI responds to the immediate request and is not an advertising/recommendation profile.
- Other Purposes: **No**.
- Tracking, data broker sharing, IDFA, ATT: **No**.

## Pre-submission gates

- [ ] Replace all controller, domain, mailbox, region, and SMTP placeholders.
- [ ] Verify production Supabase region, DPA, subprocessors, log and backup retention.
- [ ] Verify SMTP provider, region, DPA, and log retention.
- [ ] Archive current MiMo privacy, region, training, and retention evidence.
- [ ] Match the Xcode Release Archive aggregate privacy report to this document.
- [ ] Confirm the manifest declares Name, Email, Physical Address, Precise Location, Photos/Videos, Audio, Other User Content, User ID, Device ID, Other Usage Data, and Other Diagnostic Data.
- [ ] Save App Store Connect answers and bind them to commit, build, and legal-policy version.


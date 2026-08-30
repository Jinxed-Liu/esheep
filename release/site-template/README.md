# Public site template

This directory contains the ten required bilingual routes (support, privacy,
terms, AI/international-transfer notice, and account deletion). The six legal
policy pages are generated from `release/legal` by
`node tools/render_legal_site.mjs`; edit the Markdown source, not the generated
HTML. It is not
publishable until the account holder acquires `esheep.app` or
`esheepplus.app`, configures a durable privacy mailbox, replaces every
`{{...}}` placeholder, confirms the legal entity, production Supabase region,
SMTP provider and their contracts.

Before release, deploy through HTTPS static hosting and probe every route from
Beijing, Shanghai, Guangzhou, East Asia, Europe and North America. Publishing
is blocked if a placeholder remains or the required China networks cannot
reliably reach the site.

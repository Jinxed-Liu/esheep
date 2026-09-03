# eSheep+ Cloud V2 write verifier

This server-only boundary authenticates the caller, verifies each registered
device's P-256 signature and content digest, then calls the private transactional
database entry points with the service credential. Client applications must not
receive the service credential or execute those database functions directly.

The same boundary verifies uploaded photo bytes itself before it marks any
thumbnail, avatar rendition, or original as ready. Object metadata supplied by
the phone is never accepted as proof of the file hash.

Required function secrets:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

The function deliberately returns only stable error categories. Detailed traces
belong in server logs and the developer diagnostic appendix.

# Local RFC reference texts (gitignored)

Plain-text RFCs downloaded from rfc-editor.org for QUIC/HTTP3 conformance
review, so review sessions can grep exact section text instead of relying on
WebFetch (which truncates before reaching later sections of large RFCs like
9000/8446).

- `rfc9000.txt` -- QUIC transport (also see rfc9000-errata.json)
- `rfc9001.txt` -- QUIC-TLS
- `rfc9002.txt` -- QUIC loss detection and congestion control
- `rfc8446.txt` -- TLS 1.3
- `rfc7301.txt` -- ALPN

Refresh with:
```
curl -sL "https://www.rfc-editor.org/rfc/rfc<N>.txt" -o rfc<N>.txt
```

## Errata

`rfc<N>-errata.json` files are NOT usable as-is -- `errata_search.php?format=json`
redirects to a JS-rendered page (`errata.rfc-editor.org/search/?rfc_number=<N>`)
that curl can't scrape; the .json files here are just the HTML search-form shell.
Use WebFetch on `https://errata.rfc-editor.org/search/?rfc_number=<N>` instead to
get a rendered summary.

Checked 2026-08-02 for RFC 9000: no errata (Verified or Held-for-Update) touch
§6.2, §12.2, §14.1, §17.2.5, §19.3, or §19.6 -- the plain-text sections above
are authoritative for those. Re-check errata before trusting other sections.

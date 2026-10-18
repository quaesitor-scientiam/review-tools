# QUIC/TLS 1.3 conformance matrix (vlang/v net.quic client)

A requirements-driven map of RFC 9000 (QUIC transport), RFC 9001 (QUIC-TLS), RFC
8446 (TLS 1.3), and RFC 7301 (ALPN) normative requirements to the V
implementation. Mirrors `h2_conformance_matrix.md`'s purpose: a diff-driven
review reacts to what changed; a missing MUST produces no diff. Audit by
enumerating rows, not by waiting for a reviewer.

**Why this file exists.** vlang/v#27680 went through a full-file holistic
`/vreview` pass (Angle D) and still missed the Fixed Bit check (RFC 9000
§17.2/§17.3.1 — a literal, one-sentence MUST) — caught only by a third Codex
round. The review that missed it had no standing checklist to walk; it relied
on recalling every RFC 9000 §17 MUST from memory while reading the diff, the
same recall-dependent gap Angle E's H2 matrix was built to close for HTTP/2.
This file is that fix, generalized from G8's ad-hoc "write a checklist before
reading the diff" advice (`vreview/SKILL.md`, no longer sufficient on its own)
to a maintained, standing artifact. First built 2026-07-26 by auditing every
production file below line-by-line against RFC text — found and closed one new
gap (client-side `initial_source_connection_id`, see below) that no prior
review round had reported.

Files: `vlib/net/quic/varint.v`, `packet_number.v`, `header.v`,
`transport_parameters.v`, `initial_secrets.v`, `tls13_client_hello.v`,
`tls13_server_hello.v`, `tls13_handshake.v`, `tls13_messages.v`,
`tls13_certificate.v`, `tls13_certificate_chain.v`, `tls13_keyschedule.v`
(Phases 0-2, TLS/handshake-message layer) plus `conn.v` (Phase 9,
connection-level state machine — see its own dedicated section below,
added 2026-08-14; the earlier version of this line said packet protection/
streams/loss-detection/lifecycle/conn.v were "not yet on this branch" —
they have been merged for some time, that note was simply never updated,
see the corrected "Known design notes" entry below for the standing rule
this gap prompted).

Status: ✅ CONFORMS · ⚠️ GAP · 🔸 ADVISORY/optional · ⏳ DEFERRED (later phase,
tracked so it isn't forgotten) · N/A.
Last audited 2026-07-27 (commit `66808d3002`). A FOURTH Codex round
(pullrequestreview-4783410111, commit `2ad027dbd0`) found 8 gaps after this
matrix's first audit; a FIFTH round (pullrequestreview-4791164664, commit
`66808d3002`) found 6 more on TOP of that — see rows marked with each review
ID. The fifth round's gaps were concentrated in TWO areas the matrix's own
prior audits had checked less thoroughly: (a) ClientHello/ServerHello/HRR
extension ALLOWLISTS (an allowlist fixed for EncryptedExtensions was never
extended to the sibling ServerHello/HRR messages, and ClientHello was missing
an entire extension — signature_algorithms_cert — the matrix's own audit
never asked about because it isn't in this client's currently-offered set);
(b) TLS-alert-to-QUIC-error-code MAPPING PRECISION (missing_extension vs.
handshake_failure) — a class of finding this matrix's rows track as "which
alert" but hadn't cross-checked against RFC 9001 §8.2's own explicit mapping
for every mandatory-extension-absent case, only some of them.
Two lessons from THIS round, on top of the matrix's own founding lesson: (1)
a bound found for ONE connection-ID-carrying field (`preferred_address`) does
not imply the sibling sweep across every OTHER connection-ID-carrying field
was done — it wasn't, until this round: `initial_source_connection_id`/
`original_destination_connection_id`/`retry_source_connection_id` needed the
identical 20-byte check and none of them had it. (2) a security property
beyond "chain trust + hostname" (leaf KeyUsage/ExtendedKeyUsage) was entirely
missing from this matrix's own Certificate section — added below.

A SIXTH Codex round (pullrequestreview-4806500473, reviewed commit
`d263f9195f`, fixed in `393b1dcd8c`) found 9 more (1 P3 + 8 P2) — see rows
marked with that review ID. Two are notable for NOT being accepted at face
value: the CertificateVerify-algorithm alert-code finding cites RFC 8446
§4.4.3, but that section's own text (fetched directly) does not itself name
`illegal_parameter` — the classification is derived from §6.2's general
definition plus this file's own established precedent, not a literal quote,
and the reply/matrix say so explicitly rather than implying otherwise. The
ServerNameList-bound finding's stated CONSEQUENCE ("producing a malformed
ClientHello instead of returning an error") was traced through the
arithmetic and found not to occur — `encode_extension`'s own generic size
guard already catches every value the too-loose bound let through, just
with a misattributed error message — so this is logged as partially
confirmed (the bound was genuinely wrong; the specific claimed consequence
wasn't real) rather than a full accept. Lesson for next time: a reviewer's
citation and a reviewer's claimed consequence are two SEPARATE things to
verify independently — a real defect (wrong bound) does not make every
claim about its effects automatically true, and the reverse (a correct-
sounding effect) doesn't validate an unverifiable citation either.

A SEVENTH Codex round, on the downstream Phase 4 branch (vlang/v#27880,
pullrequestreview-4836332922, reviewed commit `ac33b2653c`, fixed in
`3acae7ff16`) found 9 more across `coalesce.v`/`crypto_stream.v`/`frame.v`/
`retry.v`/`version_negotiation.v` -- files this matrix does NOT yet carry
formal rows for (see the file-list note above; a Phase 3/4 row audit is
still TODO, this is a log entry, not row coverage). Every citation was
verified against the primary RFC 9000 text fetched fresh (WebFetch kept
truncating before reaching late sections like §17/§19 on one large fetch --
worked around by downloading the plain-text RFCs locally to
`.claude/skills/code-review/rfc-texts/`, gitignored, and grepping/reading
them directly; see that directory's own README for the errata-check
methodology). One finding (Retry SCID-must-not-equal-Initial-DCID, RFC 9000
§17.2.5.1) was found independently while verifying an ADJACENT Codex
finding's citation against the same section -- reading the primary text for
one claim surfaced a second, unreported requirement in the same paragraph.
Lesson: when fetching primary text to verify one finding, read the WHOLE
relevant section, not just the sentence the citation points at -- adjacent
requirements in the same section are exactly the kind of thing a
diff-driven review (this matrix's own founding problem) will miss.

## Varint encoding (RFC 9000 §16)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| 2-bit length-class prefix, 4 length classes (1/2/4/8 bytes) | 16 | ✅ | varint.v encode_varint L34-67, decode_varint L84-104 |
| Encoder MUST use minimal length class | 16 | ✅ | varint_len L20-30 always picks smallest |
| Decoder MUST accept non-minimal (longer-than-needed) encodings from peers | 16 | ✅ | decode_varint L84-104; previously wrongly rejected these — Codex finding, vlang/v#27680 pullrequestreview-4781706846, fixed and doc'd L69-83 |
| Max representable value 2^62-1 | 16 | ✅ | encode: varint_len rejects `> max_varint` L21-23; decode: bounded by construction (62 bits max ever combined, L99-103) |
| Truncated input rejected, not silently under-read | 16 | ✅ | decode_varint L96-98 |

## Packet number encode/decode (RFC 9000 §17.1, Appendix A)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Encoder picks smallest length s.t. reconstruction is unambiguous given largest_acked | 17.1 | ✅ | packet_number.v encode_packet_number L24-46 (doubling-range formulation, matches quiche/ngtcp2 convention) |
| Decoder reconstruction algorithm (Appendix A.3 DecodePacketNumber) | A.3 | ✅ | decode_packet_number L54-91; matches the RFC pseudocode's candidate-window logic with added explicit under/overflow guards (u64 arithmetic has no native negative-window wraparound protection, RFC pseudocode assumes arbitrary precision) |
| First packet in a space (no largest_pn yet) decodes as the raw truncated value | A.3 | ✅ | L62-68; proven equivalent to running the same formula with a conceptual largest_pn=-1 (verified algebraically during this audit, not just asserted) |
| Packet number spaces (Initial/Handshake/1-RTT) are independent — never a connection-global counter | 12.3 | ⏳ | doc comment L9-13 flags this explicitly for the caller; enforcement needs `packet_number_space.v` (Phase 5, not yet on this branch) |
| **Packet numbers MUST NOT exceed 2^62-1; an endpoint reaching this limit MUST stop sending in that space** | 12.3 | ⚠️→✅ | `encode_packet_number` was infallible and silently truncated any value, including ≥2^62 (e.g. 2^62 truncates to a 4-byte all-zero field) — Codex P2, pullrequestreview-4791164664. Fixed: new `max_packet_number` const, signature changed to fallible, rejects before the length-selection arithmetic (which itself could overflow for extreme inputs); test: packet_number_test.v test_packet_number_encode_rejects_exhausted_number |
| **The 4-byte length-selection arm MUST itself have an upper bound — a gap too large even for 4 bytes cannot be encoded unambiguously** | 17.1 | ⚠️→✅ | Distinct from the row above (that caps `full_pn` itself; this caps the GAP relative to `largest_acked`, independently reachable even for a small `full_pn` given a stale/absent `largest_acked`). The `else { 4 }` arm had no bound, so `(num_unacked+1)*2 > 2^32` still picked 4 bytes — Codex P2, pullrequestreview-4806500473. Reproduced before fixing: `encode_packet_number(max_packet_number, Some(0))` produced 4 bytes that `decode_packet_number` reconstructed as 2^32-1, not the 2^62-1 actually sent. Fixed: explicit bound check before the length-selection match; tests: packet_number_test.v test_packet_number_encode_rejects_gap_too_large_for_four_bytes, test_packet_number_encode_accepts_boundary_four_byte_gap |
| **When `largest_acked` is `none` (first packet in a space), `decode_packet_number` reconstructs the wire value LITERALLY, with no window arithmetic — so the encoder's chosen width MUST represent `full_pn` exactly, not merely "unambiguously" (the twice-the-gap guarantee the acked branch relies on doesn't apply at all here)** | 17.1 / A.3 | ⚠️→✅ | The round-6 fix above only closed the gap for the ACKED branch — the no-ack branch's `num_unacked` was a fixed sentinel (`0x7FFF_FFFF`), never derived from `full_pn`, so `(num_unacked+1)*2 > 2^32` was permanently `false` in this branch regardless of `full_pn`'s actual magnitude (Codex P2, pullrequestreview-4822597219). Reproduced before fixing: `encode_packet_number(0x1_0000_0000, none)` returned 4 zero bytes; `decode_packet_number` reconstructed 0, not 2^32. Fixed: explicit `full_pn > 0xFFFF_FFFF` check in the no-ack branch, preserving this branch's deliberate always-4-byte design (per its own doc comment) for every value that DOES fit; tests: packet_number_test.v test_packet_number_encode_rejects_oversized_first_packet_in_space, test_packet_number_encode_accepts_boundary_first_packet_in_space |

## Long header packets (RFC 9000 §17.2)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Header Form bit (0x80) distinguishes long/short | 17.2 | ✅ | header.v peek_header_form L42-47, parse_long_header L98-100 |
| Version == 0 is Version Negotiation, handled by a separate parser | 17.2.1 | ✅ | parse_long_header L103-105 routes to parse_version_negotiation |
| **Fixed Bit (0x40) MUST be 1 for every non-VN long-header packet; MUST discard if 0** | 17.2 | ✅ | parse_long_header L112-114 — regression for the Codex finding this matrix exists to prevent a recurrence of (pullrequestreview-4782360314); test: header_test.v test_long_header_rejects_clear_fixed_bit |
| Long Packet Type bits are v1-specific; a non-v1 version MUST NOT be decoded under v1's bit mapping | 17.2 (9369 §3.2) | ✅ | parse_long_header L116-126 rejects any non-v1 nonzero version before `peek_long_header_type` runs |
| QUIC v1 connection IDs MUST NOT exceed 20 bytes (distinct from the wire format's own 255-byte length-byte limit) | 17.2 | ✅ | parse: L133-135/L147-149; encode: L216-227 (both the 255-byte wire limit and the 20-byte v1 limit checked). This 20-byte limit applies to EVERY v1 connection ID, not just header dcid/scid — see the sibling sweep in the Transport Parameters section below, added after Codex found ONE instance (`preferred_address`) and this matrix's own re-audit found three more un-swept siblings (pullrequestreview-4783410111) |
| `token_len`/`length` varints bounds-checked in u64 space before narrowing to `int` (2^62-1 truncates silently if cast first) | 17.2.2 | ✅ | L160-169 (`u64(offset) + token_len > u64(buf.len)` before any `int()` cast) |
| Retry has no Length field or packet number | 17.2.5 | ✅ | L172-183 returns early for `.retry`, no length/pn parsing attempted |
| Encoder MUST NOT silently mis-encode a packet type for an unsupported (non-v1) version — parse already rejects non-v1 outright, encode didn't | 17.2 (9369 §3.2) | ✅ | encode_long_header now rejects `h.version != quic_v1` before computing `type_bits` (Codex P2, pullrequestreview-4783410111) — v1's type-bit mapping is meaningless for a version that assigns those bits differently; test: header_test.v test_encode_long_header_rejects_unsupported_version (added, verified passing) |
| **`Length` covers (packet number + payload), so it can never be smaller than the packet number field's own encoded width — `encode_long_header` never checked `h.length` against `pn_length_bits`** | 17.2 | ⚠️→✅ | `h.length` is caller-supplied and independent of `pn_length_bits` in this function; a 4-byte packet number (`pn_length_bits=3`) with `length=1` encoded successfully, directing a peer using Length to skip this packet (coalesced-packet splitting, a later phase) to a byte offset landing INSIDE the packet number field instead of past it (Codex P2, pullrequestreview-4822597219). Reproduced before fixing: `encode_long_header(h, 0, 3)` with `length=1` returned 9 bytes with no error. Fixed: `h.length < u64(pn_length_bits) + 1` rejected for non-Retry types (Retry has no Length/packet-number field at all); tests: header_test.v test_encode_long_header_rejects_length_shorter_than_packet_number, test_encode_long_header_accepts_length_equal_to_packet_number |
| Reserved bits (type-specific, low nibble) are header-protected; must not be read pre-removal, and non-zero after removal is PROTOCOL_VIOLATION | 17.2 | ✅ | correctly NOT read pre-removal here (doc comment L91-93); enforcement is `header_protection.v` `reserved_bits_mask`/`remove_header_protection` L117-118 — Phase 3 landed on this branch since this row was written ⏳; flipped during the same stale-row sweep that found the §14.1 gap below (2026-08-02) |
| Sender MUST pad its own outbound Initial-carrying datagrams to ≥1200 bytes | 14.1 | ✅ | `coalesce.v` `pad_initial_payload` (Phase 4) |
| Server MUST discard an Initial packet carried in a UDP datagram <1200 bytes | 14.1 | N/A (server-only, out of scope) | This MUST binds SERVERS receiving an undersized CLIENT Initial (anti-amplification) — this codebase implements CLIENT ONLY (Phase 13, server, explicitly deferred), so this requirement has no code path to apply to yet. **Two-round history worth keeping as a cautionary example**: round 6 (pullrequestreview-4839675790) misread the original ⏳ row here as applying unconditionally and added a receive-side discard in `split_coalesced_datagram` for ANY undersized Initial regardless of role — round 8 (pullrequestreview-4843018164) then found this broke a legitimate case: a server's OWN Initial is only required to be padded when it's ack-eliciting (RFC 9000 Table 3 marks ACK/PADDING/CONNECTION_CLOSE "N", not ack-eliciting), so a real server response containing only e.g. an ACK or an early CONNECTION_CLOSE can legitimately be under 1200 bytes, and this client was discarding it. Reverted in round 8 (commit pending). **Lesson: a requirement's literal subject ("a server MUST...") is part of its scope, not just its citation** — splitting a conflated ⏳ row into distinct normative clauses (the round-6 fix) is necessary but not sufficient; each resulting clause still needs its APPLICABILITY (which role, under what precondition) checked against what this codebase actually implements before writing code for it, not just its wording read literally out of context. |

## Address validation & PTO-probe anti-amplification (RFC 9000 §8.1, §8.1.2-§8.1.4)

Audited 2026-08-27 after a maintainer-relayed "Local AI check" comment
(github.com/vlang/v/pull/28164#issuecomment-5440010074) and a formal Codex
review (pullrequestreview-5044139767) on the same PR each found a real,
independent gap in this area, on the SAME underlying root cause: net.http's
`h3_now_ms()` fed a millisecond-scale value into every `quic.QuicConn`/
`QuicListener` `now u64` parameter, which this module's OWN convention
(idle_timeout.v, loss_detection.v, conn.v -- all explicitly documented) is a
raw, unscaled `time.sys_mono_now()` NANOSECOND instant. Renamed to
`h3_now_ns()`, body fixed to stop dividing by 1_000_000. This single ~1e6x
scale bug had been silently absorbing (masking) TWO further, independent
bugs below -- fixing it alone made both immediately observable via a
previously-passing real end-to-end test
(`test_h3_server_real_udp_request_response_round_trip`) hanging for the
first time.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Retry tokens SHOULD be accepted only for a short time after issuance | 8.1.4 | ⚠️→✅ | `retry_token.v`'s `validate_retry_token_for_attempt`/`RetryTokenClaims.issued_at_ms`/`listener.v`'s `retry_token_max_age_ms` (default 30000) are ALL genuinely millisecond-scale by name and by that sensible default value (30000ms = 30s) -- but `listener.v`'s two call sites (`send_retry`, `handle_new_attempt`) previously passed their own raw `now` straight through with NO conversion, silently relying on whatever scale the ultimate caller happened to use. While `h3_now_ms()`'s bug fed milliseconds, this coincidentally matched and every token validated correctly; once `h3_now_ns()` began feeding real nanoseconds, the SAME 30000 threshold, now compared against nanosecond deltas, made every retry token appear expired within 30 MICROseconds of issuance -- a server with `always_retry: true` (the default) became permanently unable to complete ANY handshake. Fixed: both call sites now compute `now / 1_000_000` right at the boundary into the retry-token subsystem (listener.v L~499/L~556); this subsystem's own doc comments, which previously and incorrectly claimed nanosecond-consistency with the rest of the module ("matching idle_timeout.v's convention"), corrected to state the deliberate millisecond scale and why (retry_token.v, retry.v). The TRUE convention was confirmed via Angle G9's own technique -- grepping this subsystem's OWN pre-existing, unchanged, already-passing test assertions (`retry_token_test.v`'s `issued_at_ms: 10_000`/`validate_retry_token_for_attempt(..., 15_000, 30_000)` style values) -- rather than trusting the doc comment, which was itself the wrong artifact of the original mistake. |
| An endpoint MUST NOT send more than three times the data it has received before its address is validated (anti-amplification) -- applies to EVERY server send, not only `drain_outgoing`'s | 8.1 | ⚠️→✅ | `send_pto_probe` (conn.v) appended a PING-only Initial/Handshake/1-RTT datagram completely unguarded by `has_amplification_budget()`/`record_amplification_sent()` -- unlike every one of `drain_outgoing`'s own sends, which ARE gated (a sibling-parity miss: this function and `drain_outgoing` are both "build and send a datagram for a server-role connection" and should share the identical budget discipline, per Phase 0 step 7's sibling-caller-guard check). For a server accepted without Retry (`always_retry: false`) whose peer address is still unvalidated, `on_loss_detection_timeout`'s own PTO backoff (2^pto_count, unbounded as long as anything stays unacked) could keep invoking this function past the 3x-received cap forever -- a spoofed Initial with no further peer traffic turning into a sustained amplification source, the exact attack §8.1 exists to prevent. Fixed: every arm gated identically to `drain_outgoing`'s pattern; a probe is simply skipped (not deferred/queued) when the budget is exhausted, which is safe since `on_loss_detection_timeout` has already advanced the backoff state before this function is ever called, independent of whether a datagram actually goes out. Test: `listener_test.v` `test_pto_probe_respects_anti_amplification_limit` -- deterministically drains an accepted connection's own remaining budget to exactly zero (module-private field, reachable from an in-package test) rather than relying on a specific certificate size coincidentally leaving zero headroom, which the coarse has_amplification_budget() check ("is there ANY budget at all", the SAME imprecision `drain_outgoing`'s own doc comment already accepts elsewhere) would otherwise still legitimately let a small enough PING through. |

**Also found and fixed in the same investigation, net.http layer (not a
`net.quic` RFC clause, noted here for the evidence trail since it was
discovered via the identical hung end-to-end test once the ns/ms bug above
stopped masking it):** `QuicListenerPollResult` gained a `touched_conns
[]&QuicConn` field, populated unconditionally inside `merge_conn_result`
for every connection `poll()`/`process_timeouts()` actually drove --
INCLUDING one whose underlying `QuicConn.poll()` produced zero new
`QuicEvent`s (e.g. a second UDP datagram carrying more STREAM bytes for an
already-open request stream, after that stream's one-time
`peer_stream_opened` event already fired). `h3_server.v`'s
`absorb_and_dispatch` previously derived its entire per-connection dispatch
set purely from `result.events`, so a connection touched with zero new
events was never handed to `H3Conn.drive_events` AT ALL for that poll --
not even with an empty slice -- silently stalling any request whose HEADERS
and body arrived in separate UDP datagrams, forever. (Codex review, PR
#28164 pullrequestreview-5044139767, P1.) A third Codex P2 finding in the
same review, `h3_server.v`'s pseudo-header validator unconditionally
requiring `:path`/`:scheme` even for a conforming CONNECT request (RFC 9114
§4.4, which mandates OMITTING both), was fixed the same round -- tracked in
the HTTP/3 framing section below, not repeated here.

## Version Negotiation (RFC 9000 §17.2.1)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Distinguished by version field == 0, no packet number/Length/payload | 17.2.1 | ✅ | header.v parse_version_negotiation L330-377 |
| Fixed Bit does NOT apply to VN packets (byte 0 after Header Form is "Unused") | 17.2.1 | ✅ (N/A by design) | parse_version_negotiation never checks it — correct, not an oversight (VN is exempted by parse_long_header's ordering: version==0 check L103 fires before the Fixed Bit check L112) |
| Supported Versions list is a whole number of 4-byte entries | 17.2.1 | ✅ | L362-365 |
| **Client MUST discard a VN packet that lists v1 (the client's own version) — the signature of a spoofed/off-path-injected packet; a genuine VN packet (v1 absent) is the hard-error case, since this client has nothing to fall back to** | 6.2/6.3 | ✅ | `version_negotiation.v` `handle_version_negotiation` L58-63 (Phase 4, landed since this row was written). **This row's own original wording had the requirement BACKWARDS** ("discard when unsupported, error when v1 present") — the exact inverse of RFC 9000 §6.2's actual second sentence and of the correct, tested, Codex-confirmed implementation (finding F1, pullrequestreview-4783410111, task history "discard-not-error on v1 in VN list"). Corrected during the same stale-row sweep that found the §14.1 gap below (2026-08-02) — a wrong row is worse than a missing one, since it can lead a future reviewer to "fix" correct code to match it |
| A VN packet MUST list at least one version — an empty list is not a meaningful negotiation offer | 17.2.1 | ✅ | parse_version_negotiation rejects `remaining == 0` (Codex P2, pullrequestreview-4783410111 — trivially passed the pre-existing multiple-of-4 check, returning an empty `versions` list instead of an error); test: header_test.v test_version_negotiation_rejects_empty_versions_list |

## Short header packets (RFC 9000 §17.3, §17.3.1)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Header Form bit (0x80) clear for short header | 17.3.1 | ✅ | parse_short_header L286-288 |
| **Fixed Bit (0x40) MUST be 1; MUST discard if 0 — never protected, always readable in cleartext** | 17.3.1 | ✅ | parse_short_header L295-297 — regression for the same Codex finding as the long-header row above; test: header_test.v test_short_header_rejects_clear_fixed_bit |
| Spin Bit / Key Phase decoded from the correct bit positions | 17.3.1 | ✅ | L309-310 (0x20/0x04); previously always returned false regardless of wire bits — Codex finding, vlang/v#27680 pullrequestreview-4781706846, fixed; test: header_test.v test_short_header_decodes_spin_bit_and_key_phase |
| DCID length is NOT on the wire; caller must supply it from connection-ID bookkeeping | 17.3.1 | ✅ (caller contract) | struct doc comment L261-267 explicit about this; enforcement that the RIGHT length is threaded through is `QuicConn`'s job (Phase 9, not yet on this branch) |
| **A negative caller-supplied `dcid_len` MUST be rejected with this function's own declared error, not crash the process** | — (implementation robustness, not a wire requirement) | ⚠️→✅ | `buf.len < 1 + dcid_len` doesn't reject when `dcid_len` is negative (both sides go negative together), so the code fell through to a slice with `start > end`, which panics rather than returning the `!`-declared error (Codex P2, pullrequestreview-4806500473). Reproduced before fixing: `parse_short_header([]u8{len: 10, init: 0x40}, -1)` crashed with `V panic: array.slice: invalid slice index`. Fixed: explicit `dcid_len < 0` guard; test: header_test.v test_short_header_rejects_negative_dcid_len |
| Reserved bits (2) MUST be 0 after header-protection removal → PROTOCOL_VIOLATION if not | 17.3.1 | ✅ | same `header_protection.v` enforcement as the long-header row above (`reserved_bits_mask(.short)`) — flipped in the same stale-row sweep (2026-08-02) |

## Transport parameters (RFC 9000 §18, §18.2, §7.3, §7.4.2)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Unrecognized parameter IDs ignored, not rejected (also how grease IDs work, no special-casing needed) | 7.4.2/18.1 | ✅ | transport_parameters.v decode_transport_parameters L406-409 |
| `ack_delay_exponent` ≤ 20 | 18.2 | ✅ | encode L241-246, decode L370-376 |
| `max_udp_payload_size` ≥ 1200 | 18.2 | ✅ | encode L208-216, decode L337-343 |
| `max_ack_delay` < 2^14 | 18.2 | ✅ | encode L247-252, decode L377-383 |
| `active_connection_id_limit` ≥ 2 | 18.2 | ✅ | encode L260-265, decode L393-399 |
| `initial_max_streams_bidi`/`uni` ≤ 2^60 (else an unrepresentable stream ID could result) | 4.6 | ✅ | encode L229-240, decode L356-369 |
| `stateless_reset_token` exactly 16 bytes | 18.2 | ✅ | encode L202-207, decode L331-336 |
| `disable_active_migration` value MUST be zero-length | 18.2 | ✅ | encode always emits zero-length (L253-255, by construction); decode L384-389 |
| **`preferred_address` connection ID MUST NOT be zero-length; MUST NOT exceed 255 bytes (wire length-byte limit) AND MUST NOT exceed 20 bytes (QUIC v1 limit)** | 18.2 / 17.2 | ✅ | encode_preferred_address: zero-length + 255-byte wire limit (pullrequestreview-4782360314), PLUS the 20-byte v1 limit on BOTH encode and decode (pullrequestreview-4783410111 — Codex found the DECODE side missing it; encode got the symmetric fix the same round); tests: transport_parameters_test.v test_encode_preferred_address_rejects_v1_cid_over_20_bytes, test_decode_preferred_address_rejects_v1_cid_over_20_bytes |
| **Every OTHER v1 connection-ID-carrying transport parameter (`initial_source_connection_id`, `original_destination_connection_id`, `retry_source_connection_id`) is ALSO bound by the 20-byte v1 limit — not directly stated in §18.2's own text for these three, but each is DEFINED as an echo of a wire DCID/SCID field already bound by §17.2's limit when it first appeared on the wire (verified via live RFC fetch, not assumed)** | 17.2 (via 7.3) | ⚠️→✅ | **Sibling-sweep GAP found by THIS matrix's own re-audit, not Codex** — Codex's pullrequestreview-4783410111 found only the `preferred_address` instance; re-auditing the sibling connection-ID fields in the SAME file found none of the other three had ever gotten the identical check, on either encode or decode. Fixed: all three now capped at `quic_v1_max_cid_len` (20) on both encode_transport_parameters and decode_transport_parameters; 6 new tests (one per field per direction), all passing |
| A client MUST NOT send any server-only parameter (`original_destination_connection_id`, `stateless_reset_token`, `preferred_address`, `retry_source_connection_id`) | 18.2 | ✅ | tls13_client_hello.v build_client_hello L232-243 (all four checked absent before encoding) |
| **`preferred_address`'s IPv4/IPv6 address+port pairs MUST be internally consistent — §18.2 defines all-zero address+port TOGETHER as "this family not provided", implying a MISMATCHED pair (zero address, nonzero port, or vice versa) is not a valid encoding of either "provided" or "not provided"** | 18.2 | 🔸→✅ | Not an explicit RFC MUST for the mismatched case specifically (the RFC text doesn't appear to define it) — a defensive rejection, marked 🔸 like the duplicate-parameter-ID row below, not a hard spec violation (Codex P2, pullrequestreview-4806500473). Fixed symmetrically on both `encode_preferred_address` and `decode_preferred_address`; tests: transport_parameters_test.v test_encode_preferred_address_rejects_mismatched_address_port, test_encode_preferred_address_rejects_mismatched_ipv6_address_port, test_decode_preferred_address_rejects_mismatched_address_port |
| **A client (like a server) MUST send `initial_source_connection_id`; its absence from either endpoint is a connection error** | 7.3/18.2 | ⚠️→✅ | **GAP found by this audit, closed same session** — build_client_hello validated the four server-only-MUST-BE-ABSENT fields but never validated this client-MUST-BE-PRESENT field; confirmed via grep that no call site (test or production) ever populated it on the client-send path, meaning every ClientHello this code could produce would omit a mandatory parameter a conforming server MUST treat as TRANSPORT_PARAMETER_ERROR. Fixed: build_client_hello now rejects a `none` `initial_source_connection_id` the same way it rejects a present server-only field. See quic_conformance_matrix / code-review-misses.md for the fix commit once landed. |
| Duplicate parameter ID rejected (not explicitly a spec MUST, but matches established QUIC implementation practice) | 18.2 | 🔸 | decode_transport_parameters L319-322, doc comment L297-303 acknowledges this goes beyond the letter of the spec |
| A malformed/duplicate/oversized-declared-length TLV is rejected, not silently truncated | 18 | ✅ | L313-315 (length exceeds buffer), L282-284 (trailing bytes after a singleton varint value) |

## Initial secrets (RFC 9001 §5.2)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Fixed public salt + HKDF-Extract keyed off the client's DCID | 5.2 | ✅ | initial_secrets.v derive_initial_secrets L97-105, initial_salt L12-13 |
| Secrets MUST be re-derived from the NEW DCID after a Retry (not the original) | 5.2 | ✅ (doc contract) | doc comment L70-96 — previously stated the OPPOSITE (Codex finding, pullrequestreview-4781706846), corrected and verified against RFC text directly, not re-derived from memory; actual re-derivation on Retry is the caller's (`QuicConn`, Phase 9, not yet on this branch) responsibility since this function is DCID-agnostic by design |
| `client in`/`server in` HKDF-Expand-Label derivation | 5.2 | ✅ | L99-100 |

## ClientHello / TLS extensions (RFC 8446 §4.1.2, RFC 9001 §8.1/8.2/8.4, RFC 7301)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| `legacy_version` fixed 0x0303 | 8446 §4.1.2 | ✅ | tls13_client_hello.v build_client_hello L248-249 |
| `legacy_session_id` MUST be empty — TLS 1.3 middlebox compat mode over QUIC is PROHIBITED | 9001 §8.4 | ✅ | L257 (hardcoded zero-length, no caller-settable path exists at all) |
| ALPN extension MANDATORY for QUIC — no fallback negotiation mechanism | 9001 §8.1 | ✅ | L223-225 (empty list rejected before building anything) |
| ALPN protocol list MUST NOT be empty; each name is a 1-255 byte `<1..255>` vector | 7301 §3.1 | ✅ | tls13_client_hello.v encode_alpn_extension L143-157 |
| ALPN protocol names need NOT be unique per RFC 7301 §3.1 (Codex P2, pullrequestreview-4822597219, correctly refuted as an RFC requirement), but ARE rejected anyway as a hygiene choice, not conformance | 7301 §3.1 | ✅ (hygiene, not RFC-mandated) | Fetched §3.1 directly: "Empty strings MUST NOT be included and byte strings MUST NOT be truncated" — no uniqueness requirement anywhere in the section; `protocols` is caller-supplied so a duplicate was possible, and created no wire-format or protocol ambiguity. Kept off the baseline in round 7 for exactly that reason. A maintainer (JalonSolov) then requested it anyway, agreeing the RFC has no such requirement but noting a duplicate wastes wire bytes for no negotiation benefit (discussion_r3690498809) — implemented in vlang/v#28001, `encode_alpn_extension` now tracks seen names and rejects a repeat; test: tls13_client_hello_test.v test_build_client_hello_rejects_duplicate_alpn_protocols, test_build_client_hello_accepts_distinct_alpn_protocols. |
| `quic_transport_parameters` extension (0x39) sent unconditionally | 9001 §8.2 | ✅ | build_client_hello L275 |
| Client MUST NOT populate server-only transport parameters in its own ClientHello | 9000 §18.2 | ✅ | see transport-parameters section above |
| CertificateVerify signature_algorithms list matches what parse_certificate_verify later restricts to | 8446 §4.2.3 | ✅ | tls13_client_hello.v L28-31 constants == tls13_certificate.v L127-128 allow-list (same four values, checked for consistency during this audit) |
| Only secp256r1 offered in key_share/supported_groups (v1 scope decision, not a MUST-violation) | 8446 §4.2.7/4.2.8 | ✅ (scope) | L22, L61-70, L92-108 |
| **`signature_algorithms_cert` SHOULD be sent when the client's certificate-signature-acceptance set differs from its CertificateVerify-acceptance set (RFC 8446 §4.2.3) — this client accepts RSA-PKCS1v1.5-signed certificates (via mbedTLS's generic X.509 verifier) but never CertificateVerify signed that way** | 8446 §4.2.3 | ⚠️→✅ | Never sent at all — a server whose chain uses RSA-PKCS1v1.5 (still common among real CAs) had no matching entry to select against and could refuse the chain, even though this client could validate it (Codex P1, pullrequestreview-4791164664, the highest-severity finding on this PR). Fixed: new `encode_signature_algorithms_cert_extension` listing the existing 4 schemes plus rsa_pkcs1_sha256/384/512; `signature_algorithms` itself unchanged (CertificateVerify stays strict); test: tls13_client_hello_test.v test_encode_signature_algorithms_cert_extension_wire_format |
| **`signature_algorithms_cert` SHOULD also list every OTHER curve the chain verifier supports beyond CertificateVerify's own set — mbedTLS's generic X.509 verifier supports P-384/P-521 (confirmed: `MBEDTLS_ECP_DP_SECP384R1_ENABLED`/`SECP521R1_ENABLED` + `MBEDTLS_SHA512_C` all enabled in mbedtls_config.h) but CertificateVerify's own curve check is P-256-only** | 8446 §4.2.3 | ⚠️→✅ | Sibling gap to the row above, same class, different curves this time instead of a different signing scheme (Codex P2, pullrequestreview-4806500473). Fixed: `sig_scheme_ecdsa_secp384r1_sha384`/`sig_scheme_ecdsa_secp521r1_sha512` (0x0503/0x0603) added to `encode_signature_algorithms_cert_extension` only; test: tls13_client_hello_test.v test_encode_signature_algorithms_cert_extension_wire_format (updated) |
| **Every extension's length bound must account for its OWN wrapping overhead, not just its innermost payload — `encode_server_name_extension`/`encode_key_share_extension` checked only the innermost field's length against the outer u16 ceiling, ignoring the intermediate structure's own length-prefix bytes** | 6066 §3 / 8446 §4.2.8 (wire-format correctness) | ⚠️→✅ (partial) | `name_bytes.len > 0xffff` ignored that a hostname entry (NameType+length+bytes) is ITSELF wrapped in ServerNameList's own length prefix (5 bytes combined overhead); same shape in `encode_key_share_extension` (6 bytes overhead) (Codex P2, pullrequestreview-4806500473). **Empirically refuted as an active bug, not just accepted**: traced the arithmetic and confirmed `encode_extension`'s own generic `data.len > 0xffff` guard already rejects every value the loose bound let through (for name_bytes.len 65531-65535, `data.len` already exceeds 65535) — no malformed ClientHello was ever actually producible, just a misattributed error message from the wrong layer. Fixed at the correct layer anyway: bounds tightened to `0xffff - 5`/`0xffff - 6` respectively; tests: tls13_client_hello_test.v test_encode_server_name_extension_rejects_hostname_near_65535_bound, test_encode_server_name_extension_accepts_boundary_hostname_length |

## ServerHello / HelloRetryRequest (RFC 8446 §4.1.3/4.1.4)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| `legacy_version` fixed 0x0303 regardless of negotiated version | 4.1.3 | ✅ | tls13_server_hello.v parse_server_hello L172-173 |
| `legacy_session_id_echo` MUST be empty (this client never sends one) | 4.1.3 | ✅ | L179-181 |
| `legacy_compression_method` MUST be 0 | 4.1.3 | ✅ | L187-189 |
| `supported_versions` MANDATORY, selected_version MUST be TLS 1.3 (0x0304) | 4.1.3 | ✅ | L198-204 |
| HelloRetryRequest distinguished from ServerHello by the magic SHA-256("HelloRetryRequest") Random value | 4.1.3 | ✅ | L12-45 (independently re-derived via live SHA-256 during review, not transcribed), L206 |
| A second HelloRetryRequest on one connection MUST abort with unexpected_message | 4.1.4 | ✅ | tls13_handshake.v process_server_hello L280-286 |
| HRR cipher_suite/selected_group MUST have been offered | 4.1.4 | ✅ | L287-297 |
| **`key_share` is NOT mandatory in a HelloRetryRequest — only `supported_versions` is; a cookie-only HRR (client's already-offered share is acceptable, server wants an anti-DoS round-trip) MUST still parse** | 4.1.4 | ⚠️→✅ | `parse_server_hello`'s HRR branch previously required `key_share` unconditionally, rejecting a valid cookie-only HRR before it could ever be represented (Codex P2, pullrequestreview-4806500473). Fixed: `ParsedHelloRetryRequest.selected_group` is now `?u16`; `process_server_hello` only validates the group when one is actually present. Verified via RFC 8446 §4.1.4 direct text: "The server's extensions MUST contain 'supported_versions'" plus "a HelloRetryRequest MUST NOT contain any extensions that were not first offered ... with the exception of optionally the 'cookie'" — key_share is not named as mandatory. Test: tls13_server_hello_test.v test_parse_server_hello_hello_retry_request_cookie_only |
| **Client responds to a first HelloRetryRequest with a regenerated ClientHello2 (fresh key share, echoed cookie, synthetic transcript substitution)** | 4.1.4 | ⚠️ GAP (deliberate, tracked) | L298-308 explicitly returns "not yet implemented" rather than mishandling silently; `synthetic_client_hello1_hash` (tls13_keyschedule.v L106-134) exists in anticipation but is not wired to any caller yet. Real-world interop testing (Phase 12+) will hit this the first time a test server sends an HRR (e.g. on a key-share mismatch) — flagging here so it's not forgotten between now and then, not asking for it to be built in this pass |
| ServerHello key_share MUST be a group actually offered | 4.1.4/8446 §4.2.8 | ✅ | tls13_handshake.v L315-318 |
| KeyShareServerHello `key_exchange` MUST NOT be empty | 8446 §4.2.8 | ✅ | tls13_server_hello.v L243-245 |
| **ServerHello/HelloRetryRequest MUST NOT carry an extension outside RFC 8446 §4.2's per-message table for that variant, or one this client didn't offer (alpn, key_share-in-EE-only-extensions, etc. are illegal here even if this client offered them elsewhere)** | 8446 §4.2 | ⚠️→✅ | No allowlist existed at all — the SAME class of gap the EncryptedExtensions allowlist fix (rev 23/24) closed, never extended here (Codex P2, pullrequestreview-4791164664). Fixed: `server_hello_allowed` (supported_versions, key_share) and `hello_retry_request_allowed` (+ cookie) via a shared `reject_unsolicited_extensions` helper, same `unsupported_extension` error-code-preservation fix applied to `process_server_hello`'s caller as `process_encrypted_extensions` already had; tests: tls13_server_hello_test.v test_parse_server_hello_rejects_unsolicited_alpn, test_parse_server_hello_hello_retry_request_rejects_unsolicited_extension |

## EncryptedExtensions + connection-ID authentication (RFC 8446 §4.3.1, RFC 9000 §7.3, RFC 9001 §8.1/8.2)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| `early_data` extension MUST NOT appear (v1 never offers 0-RTT) | 8446 §4.3.1 | ✅ | tls13_server_hello.v parse_encrypted_extensions |
| **Server MUST NOT send an extension in EncryptedExtensions the client didn't offer, or that RFC 8446 §4.2's own per-message table never permits there at all (key_share/supported_versions/signature_algorithms are ClientHello/ServerHello/HRR-only, illegal in EE regardless of what was offered)** | 8446 §4.2 | ⚠️→✅ | Previously only `early_data` was checked; anything else (e.g. `key_share`) passed through unrejected (Codex P2, pullrequestreview-4783410111). Fixed: `encrypted_extensions_allowed` allowlist (server_name, supported_groups, alpn, quic_transport_parameters — the intersection of RFC 8446's EE-table and what this client actually offers, plus quic_transport_parameters which RFC 9001 §8.2 adds), checked for every extension; violations now carry the correct `unsupported_extension` (110) QUIC CONNECTION_CLOSE code via `error_with_code`, not a generic decode_error the caller would otherwise substitute (the caller now preserves a nonzero `.code()` instead of always remapping to decode_error); test: tls13_server_hello_test.v test_parse_encrypted_extensions_rejects_key_share |
| **A `server_name` extension in EncryptedExtensions, if present, MUST have empty `extension_data`** | 6066 §3 | ⚠️→✅ | RFC 6066 §3 (direct text): "the server SHALL include an extension of type 'server_name' in the (extended) server hello. The 'extension_data' field of this extension SHALL be empty." Not validated — a non-empty payload passed through silently (Codex P2, pullrequestreview-4806500473). Fixed: `parse_encrypted_extensions` checks `sn_ext.data.len != 0`; tests: tls13_server_hello_test.v test_parse_encrypted_extensions_accepts_empty_server_name, test_parse_encrypted_extensions_rejects_nonempty_server_name |
| **A `supported_groups` extension's inner NamedGroupList (RFC 8446 §4.2.7 / RFC 7919: a 2-byte length prefix + that many bytes of 2-byte NamedGroup entries) MUST be internally consistent — only the OUTER extension TLV framing was ever checked** | 4.2.7 (7919) | ⚠️→✅ | A malformed inner length (e.g. declaring 2 group-bytes while only 1 byte is present) parsed successfully into an opaque, never-consumed `TlsExtension` — this client never reads this field's value (key exchange is negotiated via `key_share`), but accepting a structurally malformed TLS field is wrong independent of whether anything consumes it (Codex P2, pullrequestreview-4822597219). Fixed: validates the inner length prefix matches remaining bytes exactly and is non-empty/even; kept as a plain `error()` (falls through to `decode_error`), matching the `server_name` row above's precedent — `decode_error` is the semantically correct alert (§6.2: "a field ... was out of the specified range"), not a bespoke code; tests: tls13_server_hello_test.v test_parse_encrypted_extensions_accepts_wellformed_supported_groups, test_parse_encrypted_extensions_rejects_malformed_supported_groups |
| ALPN extension MANDATORY in EncryptedExtensions; missing == mismatch (both mean no protocol agreed) | 9001 §8.1, 7301 §3.2 | ✅ | tls13_handshake.v process_encrypted_extensions L380-390 |
| Server's ALPN selection MUST be one this client actually offered | 7301 §3.2 | ✅ | L387-390 |
| `quic_transport_parameters` extension MANDATORY in EncryptedExtensions | 9001 §8.2 | ✅ | L392-395 |
| Peer's `initial_source_connection_id` MUST match the packet-header SCID this client actually observed | 7.3 | ✅ | L404-410 — this and the two rows below closed a prior Codex-found gap (pullrequestreview-4781706846) where connection-ID authentication was entirely absent; verified all three checks are present as of this audit, not just the one originally reported |
| Peer's `original_destination_connection_id` MUST match this client's own first Initial DCID | 7.3 | ✅ | L412-418 |
| Peer's `retry_source_connection_id` MUST be present iff a Retry occurred, and MUST match the Retry packet's SCID | 7.3 | ✅ | L420-430 (both directions checked: present-but-no-Retry rejected too, not just absent-when-expected) |
| Unknown/invalid transport parameters → TRANSPORT_PARAMETER_ERROR (0x08), not a generic TLS decode alert | 9000 §20.1 | ✅ | transport_parameter_error L59-61, used uniformly for every check in this section |
| **A missing `quic_transport_parameters` extension MUST close with error 0x016d (TLS `missing_extension` alert), not a generic `handshake_failure`** | 9001 §8.2 | ⚠️→✅ | Mapped through `.handshake_failure` (0x128) instead — Codex P2, pullrequestreview-4791164664, verified against RFC 9001 §8.2's own exact text before fixing. Fixed: new `TlsAlert.missing_extension = 109` (IANA-confirmed), used here; test: tls13_handshake_test.v test_process_encrypted_extensions_rejects_missing_quic_transport_parameters |
| **A server using a zero-length connection ID MUST NOT supply `stateless_reset_token` or `preferred_address` (both presuppose a real, routable server connection ID)** | 9000 §18.2 (cross-field, via §5.1's CID-issuance restriction) | ⚠️→✅ | Neither `decode_transport_parameters` nor `decode_preferred_address` can see this cross-field inconsistency in isolation; only the caller holding `peer_initial_scid` can (Codex P2, pullrequestreview-4791164664 — the exact RFC 9000 §18.2 defining paragraphs for these two parameters could not be independently re-fetched during this audit due to a tool truncation limit on this very long RFC; fixed based on Codex's precise citation plus the confirmed adjacent §5.1 CID-issuance text, not blind trust). Fixed: checked in `process_encrypted_extensions` right after the scid match check; tests: tls13_handshake_test.v test_process_encrypted_extensions_rejects_stateless_reset_token_with_zero_length_scid, test_process_encrypted_extensions_rejects_preferred_address_with_zero_length_scid |

## Certificate / CertificateVerify / Finished (RFC 8446 §4.4.x)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Server's `certificate_list` MUST always be non-empty | 4.4.2.4 | ✅ | tls13_certificate.v parse_certificate L85-87 |
| `certificate_request_context` MUST be zero-length for server authentication | 4.4.2 | ✅ | tls13_handshake.v process_certificate_or_request L468-471 |
| `CertificateEntry.cert_data` MUST NOT be empty (`<1..2^24-1>`) | 4.4.2 | ✅ | tls13_certificate.v L59-61 |
| Client rejects CertificateRequest outright (v1 has no client cert to offer) | 4.4.2 (scope) | ✅ (deliberate scope) | tls13_handshake.v L452-455 |
| Certificate chain validated against a trust anchor AND the leaf's SAN/CN matched against the real SNI hostname | — (implicit auth requirement) | ✅ | tls13_certificate_chain.v verify_server_certificate_chain L43-56; hostname threaded from the handshake's own `server_name` (was previously `nil` — Codex G8 finding, pullrequestreview-4781706846, fixed) |
| **Leaf certificate MUST actually be authorized for TLS server signing use: keyUsage (if present) permits digitalSignature, extendedKeyUsage (if present) permits serverAuth — a real TLS handshake enforces this via `mbedtls_ssl_check_cert_usage`, which this standalone (never-constructs-an-SSL-context) path has no equivalent for** | — (implicit auth requirement, mirrors mbedTLS's own internal `mbedtls_ssl_check_cert_usage`) | ⚠️→✅ | **P1 — the highest-severity finding either Codex round has produced on this PR** (pullrequestreview-4783410111). `verify_certificate_chain`/`verify_server_certificate_chain` checked chain-of-trust and hostname only; a certificate restricted to e.g. clientAuth-only EKU, or missing digitalSignature KeyUsage, could still authenticate a QUIC server. Fixed: new `net.mbedtls.check_server_cert_usage` (backed by `mbedtls_x509_crt_check_key_usage`/`check_extended_key_usage`, both real mbedTLS library functions — this codebase adds no new crypto logic, only wires up an existing check standalone callers never got), called from `verify_server_certificate_chain` right after chain+hostname verification succeeds. Both mbedTLS functions already implement X.509's own "absent extension means unrestricted" rule, so this doesn't over-reject certs with no KeyUsage/EKU at all. **Test-coverage caveat, stated plainly: this repo has no certificate fixture with a RESTRICTIVE KeyUsage/EKU (e.g. clientAuth-only), so the actual REJECTION path isn't proven with a real certificate** — tests cover the positive path (existing test certs, which have no restrictive extensions, are correctly accepted) and the underlying mbedTLS functions are unmodified, well-established library code; test: tls13_certificate_chain_test.v test_check_server_cert_usage_accepts_existing_test_certs |
| **A CertificateEntry's own extensions MUST be limited to what RFC 8446 §4.2's applicability table permits in a Certificate message ("CT" column: only `status_request`/`signed_certificate_timestamp`) — `parse_certificate` parsed and stored each entry's extensions unconditionally, with no legality check at all** | 4.2 | ⚠️→✅ | Fetched §4.2's table directly: `supported_versions` (Codex's cited example) is CH/SH/HRR-only, not CT. Checked further: this client's own ClientHello never offers EITHER of the two extensions §4.2 permits in a CertificateEntry, so per this file's own EncryptedExtensions precedent ("Implementations MUST NOT send extension responses if the remote endpoint did not send the corresponding extension requests... MUST abort... with 'unsupported_extension'") the correct legal set here is empty — ANY extension present is a violation (Codex P2, pullrequestreview-4822597219). Reproduced before fixing: a CertificateEntry with a `supported_versions` extension parsed successfully with no error. Fixed: `parse_certificate` rejects any non-empty `CertificateEntry.extensions` with `unsupported_extension`, mirroring the alert this codebase already uses for the identical class of violation in EncryptedExtensions rather than `illegal_parameter` as suggested. **Self-caught during this round's own /vreview, not a Codex finding**: `process_certificate_or_request` unconditionally remapped ANY `parse_certificate` failure to `decode_error`, discarding this new classification — fixed with the same `err.code() != 0` preservation pattern already used by 3 sibling call sites in the same file; tests: tls13_certificate_test.v test_parse_certificate_rejects_entry_with_illegal_extension, tls13_handshake_test.v test_process_certificate_or_request_preserves_illegal_extension_code |
| CertificateVerify `algorithm` MUST be one offered in `signature_algorithms` | 4.4.3 | ✅ | tls13_certificate.v parse_certificate_verify L127-129 |
| **A violation of the row above MUST map to a specific, correctly-classified alert, not a generic decode_error** | 4.4.3 (alert per §6.2) | ⚠️→✅ | The requirement itself is in §4.4.3 ("MUST be one offered"), but §4.4.3's own text does NOT itself name the alert for a violation (confirmed via direct fetch — no literal quote pairs this requirement with a specific alert). Classified as `illegal_parameter` per §6.2's general definition ("a field ... was incorrect or inconsistent with other fields") plus this file's own established convention (ServerHello/HRR cipher_suite-not-offered already use `illegal_parameter` for the identical violation class) and majority real-world implementation practice (Codex P2, pullrequestreview-4806500473). Previously mapped through the generic `decode_error` unconditionally. Fixed: `parse_certificate_verify` now uses `error_with_code(..., illegal_parameter)`; `process_certificate_verify` preserves it instead of remapping, matching `process_server_hello`/`process_encrypted_extensions`'s established error-code-preservation pattern; test: tls13_certificate_test.v test_parse_certificate_verify_rejects_unoffered_algorithm (asserts the code, not just the message), tls13_handshake_test.v test_process_certificate_verify_rejects_unoffered_algorithm (handshake-level propagation) |
| **CertificateVerify's claimed algorithm MUST match the certificate's ACTUAL key properties — `ecdsa_secp256r1_sha256` names ONE specific curve (P-256); `mbedtls_pk_verify_ext` only confirms the key is SOME EC key, never which curve** | 4.2.3 | ⚠️→✅ | A certificate whose EC key is P-384/P-521/any other curve could be accepted under the `ecdsa_secp256r1_sha256` scheme name even though the signature verifies correctly on its OWN curve — a protocol-identity mismatch, not broken crypto (Codex P2, pullrequestreview-4783410111). Fixed: new `net.mbedtls.public_key_curve_is_secp256r1` (backed by `mbedtls_pk_ec`+`mbedtls_ecp_keypair_get_group_id`, via a C shim resolving the by-value `mbedtls_pk_ec` call), checked before verification in the ecdsa branch. **Same test-fixture caveat as the row above**: no P-384/P-521 certificate fixture exists to prove the wrong-curve case directly; proven instead via the adjacent case actually available (an RSA key, which the curve-id function must also report as non-secp256r1, and which the CertificateVerify path must therefore also reject under this scheme) — tests: tls13_certificate_chain_test.v test_public_key_curve_is_secp256r1_true, test_verify_certificate_verify_signature_rejects_wrong_key_type_for_ecdsa |
| CertificateVerify signed content: 64×0x20 + context string + 0x00 + Transcript-Hash(...Certificate) | 4.4.3 | ✅ | certificate_verify_signed_content L159-171 |
| CertificateVerify verified against the transcript checkpoint BEFORE CertificateVerify itself is accumulated | 4.4.3 | ✅ | tls13_handshake.v process_certificate_or_request L477-478 (snapshot taken right after Certificate) / process_certificate_verify L497 (verify uses the snapshot, not a fresh hash) — checkpoint ordering confirmed correct during this audit |
| Finished `verify_data` = HMAC(finished_key, Transcript-Hash) using the CORRECT side's traffic secret | 4.4.4 | ✅ | tls13_handshake.v process_finished L520 (server_secret for server's own Finished), L531 (client_secret for this client's own Finished) — both sides confirmed correct during this audit |
| Finished transcript checkpoint excludes the Finished message itself | 4.4.4 | ✅ | L520 computed before L527's accumulate |
| Finished comparison MUST be constant-time (it's a peer-supplied authenticator) | — (implicit) | ✅ | tls13_messages.v verify_finished L126-129 uses `hmac.equal`, not `==` |

## Key schedule (RFC 8446 §7.1)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Early Secret computed via the real no-PSK HKDF-Extract path (zero-IKM, zero-salt), not hardcoded | 7.1 | ✅ | tls13_keyschedule.v derive_early_secret L48-51, doc comment L44-47 explains why shortcutting would be unverified |
| Full chain: Early → (derived) → Handshake → (derived) → Master, each `Derive-Secret` call using the right transcript checkpoint | 7.1 | ✅ | derive_handshake_secrets L63-73, derive_application_secrets L93-104 |
| HelloRetryRequest synthetic `message_hash` transcript substitution | 4.4.1 | ⏳ | function exists (`synthetic_client_hello1_hash` L125-134) but not wired to any caller — tracked under the same HRR-not-implemented GAP row above, not a separate defect |
| Pinned to `TLS_AES_128_GCM_SHA256` only (v1 scope decision, matches RFC 9001 §5.1's Initial-packet mandate) | 9001 §5.1 | ✅ (scope) | tls13_client_hello.v L38, checked on both ServerHello and HRR paths |

## Connection-level state machine (QuicConn, conn.v — RFC 9000 §5/§7/§10, RFC 9001 §4.9)

**Why this section is dated 2026-08-14, long after the matrix's other sections:**
this file's own "Known design notes" (below) said, for over a month, "Every
`⏳ DEFERRED` row above will need re-auditing once those [downstream] branches
land here; do not assume a deferred row is someone else's problem forever" —
but when Phase 9 (`conn.v`, the file every one of those deferred rows pointed
at) actually landed on this branch, no one ever came back and added a section
for it. Every `/vreview` pass run on `conn.v` after that point fell back to
ad-hoc Angle D manual reasoning instead of a systematic requirements walk,
which is exactly the failure mode this whole file exists to close. Two
external "Local AI Review" findings on PR #28083 (discarded-key rejection,
destination-CID validation) plus one self-found while building this section
from the actual RFC text (source-CID consistency) is the direct, avoidable
cost of that gap — none of the three needed anything beyond reading RFC 9000
§5.2.1/§7.2/§17.2.2.1 and RFC 9001 §4.9 top to bottom, which no one had done
for this file until now.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| **A client stops both sending and PROCESSING Initial packets once it sends its first Handshake packet — receiving one after MUST be discarded, not decrypted-and-dispatched** | 9000 §17.2.2.1, 9001 §4.9.1 | ⚠️→✅ | Initial/Handshake key material is NOT cleared by `discard_initial_keys`/`discard_handshake_keys` (only per-space bookkeeping is reset), and `process_initial_or_handshake` decrypted+dispatched regardless of the discard flags (maintainer "Local AI Review" finding on PR #28083). Fixed: explicit `c.initial_keys_discarded`/`c.handshake_keys_discarded` check at the top of the function, before any key material is touched — conn.v L629-632; tests: `test_discarded_initial_keys_reject_further_packets`, `test_discarded_handshake_keys_reject_further_packets` |
| **An endpoint MUST discard its Handshake keys when the handshake is confirmed** | 9001 §4.9.2 | ✅ | `on_handshake_confirmed` calls `discard_handshake_keys()` unconditionally — conn.v, `on_handshake_confirmed` |
| **A packet's Destination Connection ID MUST match a value the receiver itself selected; packets that don't are discarded** | 9000 §5.2.1, §7.2 | ⚠️→✅ | Never checked at all — any authenticated (i.e. successfully-decrypted) server packet was accepted regardless of `header.dcid`, and `c.peer_scid`/`c.dcid` were updated from ITS source CID (maintainer "Local AI Review" finding on PR #28083). Concretely exploitable for Initial packets: their protection keys are derivable from the DCID alone (RFC 9001 §5.2), so an off-path attacker observing the client's chosen DCID can forge a well-encrypted packet with an arbitrary destination CID. Fixed: `header.dcid != c.scid` check (long header, conn.v L640) and, as of Phase 14b, `!c.local_cid_set.contains(short_header.dcid)` (short header, conn.v L1184 — broadened from a bare `c.scid` comparison once this endpoint could hold more than one valid local CID; a peer legitimately addressing a packet to any NON-seed CID this endpoint issued would otherwise have been silently dropped as unrecognized, found during 14b's own `/vreview`, see the §5.1 section below), routed through `note_one_rtt_processing_failed` rather than a bare drop — see next row); tests: `test_wrong_destination_cid_rejected_on_long_header`, `test_wrong_destination_cid_rejected_on_short_header`, `test_process_one_rtt_packet_accepts_non_seed_local_cid` |
| **A genuine stateless reset (RFC 9000 §10.3) is deliberately shaped like an ordinary short-header packet with unpredictable bytes where a real DCID would be — a DCID-mismatch check on the 1-RTT path must not short-circuit BEFORE the stateless-reset comparison gets a chance to run** | 9000 §10.3.1 (interaction with §7.2's DCID check) | ✅ | Self-identified while designing the short-header DCID fix (not a separately reported finding) — a naive bare `return` on DCID mismatch would have broken stateless-reset detection entirely, since real resets almost always fail a literal DCID-content check. Fixed by routing DCID mismatches through `note_one_rtt_processing_failed` (conn.v L749-750) instead of a bare `return`, same as every other 1-RTT processing-failure path |
| **Once a client has received a valid Initial packet from the server, it MUST discard any subsequent packet it receives on that connection with a DIFFERENT Source Connection ID** | 9000 §7.2 | ⚠️→✅ | **Self-found while building this section**, not reported externally — `process_initial_or_handshake` only ever WRITES `c.peer_scid` on the first packet (`if c.peer_scid.len == 0 {...}`); it never checked a later packet's `header.scid` against the already-established value. Concretely exploitable for Initial packets for the same reason as the DCID row above (publicly-derivable keys) — an attacker can forge a SECOND Initial packet with the correct (now-passing) destination CID but an arbitrary source CID and have its frames (e.g. injected CRYPTO data) processed as genuinely from the peer. Handshake-space forgery isn't practically exploitable the same way (those keys derive from the real ECDHE secret), but the fix covers both spaces uniformly, matching the RFC's own unscoped wording. Fixed: `c.peer_scid.len != 0 && header.scid != c.peer_scid` check, conn.v L658-659; test: `test_wrong_source_cid_rejected_after_peer_scid_established` |
| **If a client receives a packet using a different version than it initially selected, it MUST discard that packet** | 9000 §5.2.1 | ✅ | Initially suspected as a FOURTH gap while building this section (`process_one_packet` only compares the raw version field against 0, the VN sentinel, before dispatching) — REFUTED on inspection of the actual decode path: `parse_long_header` (header.v L124) independently re-parses the version field and rejects any non-`quic_v1` value outright, with its own documented rationale about v2's incompatible long-header type-bit mapping. `process_one_packet`'s own raw peek exists only to distinguish the VN sentinel (version==0, which has no normal long-header layout) before handing off to the real parser — not a duplicate or dead check. Verified empirically (a same-encryption-self-consistent forged packet with a non-v1 version in a hand-built `conn_test.v` test) before accepting the refutation, not by re-reading the code alone |
| **RFC 9000 §10.1 idle timeout: an endpoint restarts its idle timer when a packet from its peer is received and processed successfully (RECEIVE side: unconditional, any packet); it also restarts when sending an ack-eliciting packet if no other ack-eliciting packet has been sent since last receiving one (SEND side: ack-eliciting only)** | 9000 §10.1 | ⚠️→✅ | `conn.v` never called `IdleTimeoutState.note_packet_received` at all (maintainer "Local AI Review" finding, a different LLM than the CID round) — an otherwise-active connection that only received data would incorrectly idle-timeout. Wiring the call in surfaced a SECOND, deeper bug: `note_packet_received` itself had the RFC's asymmetry backwards, gating the RECEIVE side on ack-eliciting when the RFC's ack-eliciting condition is SEND-only. Fixed: wired the call into `process_initial_or_handshake`/`process_one_rtt_packet`; `note_packet_received` dropped its now-unnecessary `is_ack_eliciting` parameter (idle_timeout.v); tests: `test_process_one_rtt_packet_resets_idle_timer_on_receive`, `test_idle_timeout_mechanism_fires_after_configured_window` |
| **RFC 9000 §10.2.2: the closing/draining period MUST be bounded (recommended 3x PTO), for both `.closing` and `.draining`** | 9000 §10.2.2 | ⚠️→✅ | `closing_or_draining_deadline` combined `pto_period()` (already a real, nanosecond-scale `time.Duration`) with `now` (a `time.sys_mono_now()`-sourced nanosecond instant throughout this module) through an ERRONEOUS `.milliseconds()` conversion, shrinking the bound to a tiny millisecond count and landing the deadline almost immediately instead of ~3xPTO out — self-found while re-verifying an unrelated idle-timeout fix, after a first attempt at that fix "corrected" a DIFFERENT, actually-already-correct function (`idle_timeout_deadline`) into the identical wrong shape by copying this function's (wrong) pattern as if it were established precedent. See Angle G9 in `vreview/SKILL.md` for the full process lesson (verify a module's unit convention via an existing test assertion, not a sibling's own conversion call). Fixed: removed the `.milliseconds()` call, conn.v `closing_or_draining_deadline`; tests: `test_peer_connection_close_enters_draining`, `test_close_sends_connection_close_and_transitions_to_closing` (both recalibrated to nanosecond-realistic `now` deltas) |
| **A `compute_next_timeout()`-style aggregator that merges several optional deadline sources into one scheduling value must include EVERY such source on the struct, not just the ones present when the aggregator was first written** | — (implementation-level correctness, not a literal RFC citation) | ⚠️→✅ | `compute_next_timeout()` merged `idle_timeout_deadline()`/`loss_detection.next_timeout()` but never `closing_deadline`, even though both were written in the SAME commit — a connection reaching `.closing`/`.draining` with nothing else armed returned `next_timeout = none`, so a real caller-driven event loop never learned to poll again despite RFC 9000 §10.2.2's bound being correctly recorded. See Angle D's "Central-scheduler aggregator completeness" bullet in `vreview/SKILL.md`. Fixed: `closing_deadline` merged in via the same min-merge pattern as `idle_deadline`; test: `test_compute_next_timeout_includes_closing_deadline` |
| **RFC 9000 §19.20: "A HANDSHAKE_DONE frame can only be sent by the server... A server MUST treat receipt of a HANDSHAKE_DONE frame as a connection error of type PROTOCOL_VIOLATION"** | 9000 §19.20 | ⚠️→✅ (v1-unreachable) | Never checked — `dispatch_one_rtt_frame`'s `HandshakeDoneFrame` arm advanced handshake state unconditionally regardless of role (maintainer "Local AI Review" finding). Currently unreachable through any real call path in v1 (only clients are ever constructed, `role` is always `.client`, no server constructor exists) but added anyway, matching `stream.v`'s own `QuicRole` doc comment and `PROGRESS.md`'s stated design intent that Phases 1-9's dispatch code needs no rework once server support (Phase 13) lands. Fixed: `if c.role == .server { return error(...) }` guard, conn.v L855; test: `test_handshake_done_rejected_when_role_is_server` (white-box, force-sets `c.role = .server` since no real call path reaches it) |

## Connection ID lifecycle (RFC 9000 §5.1, active_connection_id_set.v — Phase 14b)

Audited 2026-08-27 against the primary text (`rfc-texts/rfc9000.txt` §5.1,
§5.1.1, §5.1.2, §19.15, §19.16). Supersedes the "N/A for v1, no active-CID-set
type exists" note this section previously carried — Phase 14b built exactly
that type. See PROGRESS.md's own Phase 14b entry for the full sub-phase
writeup; this section is the requirements-driven audit, not a duplicate of it.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| An endpoint issues additional connection IDs (beyond its handshake-established one) via NEW_CONNECTION_ID, up to the peer's advertised `active_connection_id_limit` | 5.1.1 | ✅ | `drain_pending_new_connection_ids` (conn.v) replenishes `LocalConnectionIdSet` up to `c.peer_active_connection_id_limit`; each CID is crypto-random (§9.5's unlinkability requirement — `crypto.rand`, not the plain `rand` module conn.v's OTHER, pre-14b generation still uses); test: `test_drain_pending_new_connection_ids_replenishes_up_to_peer_limit` |
| A peer MAY address a packet using ANY connection ID this endpoint has issued and not yet retired — not only the original one | 5.1, 5.1.1 (implied: issuance is pointless if unused CIDs are rejected) | ⚠️→✅ | **Self-found during this same phase's own `/vreview` pass, not reported externally.** The first version of `process_one_rtt_packet`'s DCID check compared only against `c.scid` — every packet addressed to a newly-issued local CID was silently dropped as unrecognized, making CID issuance functionally inert even for a single connection with no listener/routing concern involved at all (a broader, more severe consequence than the ALREADY-known Phase 14d listener-registration gap noted below). Reproduced before fixing: `test_process_one_rtt_packet_accepts_non_seed_local_cid` failed (panicked — the packet was never dispatched) against the unfixed code. Fixed: `LocalConnectionIdSet.contains()` added, used in place of the bare `c.scid` comparison, conn.v L1184; test passes fixed |
| MUST NOT provide more connection IDs than the peer's own advertised `active_connection_id_limit` | 5.1.1 | ✅ | `drain_pending_new_connection_ids`'s own loop condition (`for c.local_cid_set.active_count() < c.peer_active_connection_id_limit`) — never issues past the limit; test: `test_drain_pending_new_connection_ids_replenishes_up_to_peer_limit`'s own idempotency assertion |
| A NEW_CONNECTION_ID frame reusing a sequence number already seen MUST carry the SAME connection ID as before | 19.15 | ✅ | `PeerConnectionIdSet.note_new_connection_id` rejects a reused sequence number paired with a DIFFERENT `connection_id` (PROTOCOL_VIOLATION); an identical resend is idempotent; tests: `test_peer_connection_id_set_note_new_connection_id_rejects_sequence_reused_with_different_cid`, `test_peer_connection_id_set_note_new_connection_id_allows_identical_resend` |
| After processing a NEW_CONNECTION_ID frame (including any resulting retirements), if the number of active connection IDs exceeds this endpoint's OWN advertised `active_connection_id_limit`, the connection MUST be closed with CONNECTION_ID_LIMIT_ERROR | 5.1.1 | ✅ | `note_new_connection_id`'s returned `over_limit` field, checked in `dispatch_one_rtt_frame`'s `NewConnectionIdFrame` arm, propagates as `error_with_code(..., quic_error_connection_id_limit)` (0x09, RFC 9000 §20.1) — never silently accepted; test: `test_dispatch_new_connection_id_frame_over_limit_closes_with_connection_id_limit_error` |
| Upon receipt of an increased Retire Prior To field, the peer MUST stop using the corresponding connection IDs and retire them with RETIRE_CONNECTION_ID frames | 5.1.2 | ✅ | `note_new_connection_id` computes `newly_retired` (every currently-held sequence below the new `retire_prior_to`) and removes them from the active set; the caller queues a RETIRE_CONNECTION_ID for each via `pending_retire_connection_ids`, drained by `drain_pending_retire_connection_ids` on the next `poll()`; tests: `test_peer_connection_id_set_retire_prior_to_retires_lower_sequences`, `test_dispatch_new_connection_id_frame_retire_prior_to_queues_retirement` |
| A lower or equal Retire Prior To in a later frame MUST NOT un-retire anything already retired | 5.1.2 (implied — retirement is monotonic) | ✅ | `note_new_connection_id` only acts when `retire_prior_to > s.retire_prior_to` (strictly greater); test: `test_peer_connection_id_set_retire_prior_to_does_not_regress` |
| Receipt of a RETIRE_CONNECTION_ID frame containing a sequence number greater than any previously sent by this endpoint MUST be treated as a connection error of type PROTOCOL_VIOLATION | 19.16 | ✅ | `LocalConnectionIdSet.retire` errors when `seq >= s.next_seq`, propagated the same way as the CONNECTION_ID_LIMIT_ERROR row above; tests: `test_local_connection_id_set_retire_rejects_never_issued_sequence`, `test_dispatch_retire_connection_id_frame_rejects_never_issued_sequence` |
| A RETIRE_CONNECTION_ID frame's sequence number MUST NOT refer to the Destination Connection ID field of the packet the frame itself arrived in | 19.16 | ⏳ DEFERRED | Needs the current packet's own header available at frame-dispatch time, which `dispatch_one_rtt_frame`'s call chain doesn't plumb through today — a real, named, deliberate 14b scope limit (see its own doc comment on `LocalConnectionIdSet.retire`), not silently missed. Partially mitigated by the NEXT row's broader guard, which prevents this specific violation's worst realistic consequence even without the exact per-packet check |
| **(Implementation-level hardening, not itself literal RFC text, but closes the practical consequence of the row above being deferred)** An endpoint must always remain reachable by at least one currently-valid local connection ID — never let its own active local CID set reach zero | — | ✅ | **Self-found while designing the §19.16 row above's fix**, not reported externally: without SOME floor, a peer retiring every locally-issued sequence in turn (each individually legal in isolation, absent the deferred per-packet check above) could drive `LocalConnectionIdSet` to empty, after which `process_one_rtt_packet`'s own `contains()` check would reject every future 1-RTT packet — a connection-level DoS this endpoint would inflict on itself by honoring the request literally. Fixed: `LocalConnectionIdSet.retire` refuses (PROTOCOL_VIOLATION) a retirement that would leave zero active entries, while staying idempotent for an already-absent sequence; tests: `test_local_connection_id_set_retire_refuses_to_empty_the_set`, `test_local_connection_id_set_retire_allows_emptying_via_two_steps_leaving_one`, `test_dispatch_retire_connection_id_frame_refuses_to_empty_local_cid_set` |
| A newly-issued local CID must be reachable by a SERVER specifically, once multiple connections are demuxed by connection ID behind one shared socket (QuicListener) | 5.1 (implied by §5.1.1's issuance intent) | ⏳ DEFERRED | `QuicListener`'s own routing table (`listener.v`) is still keyed only by each connection's ORIGINAL `scid` — a real, named, deliberate scope limit, Phase 14d's job (see `active_connection_id_set.v`'s own module doc comment for the precise boundary: this endpoint's OWN `poll()`-level acceptance already works, per the row above; only the LISTENER's multi-connection demux doesn't yet) |
| A connection ID's own `active_connection_id_limit` transport parameter, if present, MUST be at least 2 | 18.2 | ✅ (pre-existing, re-confirmed) | `transport_parameters.v`'s `param_active_connection_id_limit` decode/encode paths both reject `v < min_active_connection_id_limit` (=2) — validated on BOTH what this endpoint sends and what a peer sends, before 14b's own code ever reads the value; `peer_active_connection_id_limit`/`own_active_connection_id_limit` (conn.v) therefore never observe an invalid raw value in practice |

**Still out of scope, deliberately (not audited above as gaps):** actually
switching this connection's active outgoing `dcid` to one of the peer's
pooled CIDs, or deciding WHEN to (path validation via PATH_CHALLENGE/
PATH_RESPONSE, Phase 14c/14e's job); self-initiated CID rotation for privacy
(this endpoint always sends `retire_prior_to: 0` in its own NEW_CONNECTION_ID
frames, never proactively asking the peer to retire anything).

## Immediate Close (RFC 9000 §10.2)

Audited 2026-08-14 against the primary text (`rfc-texts/rfc9000.txt` §10.2-
10.2.3) — this section previously did not exist; `connection_close.v` (Phase
8) had no matrix coverage at all, the same gap that let the discarded-key/
DCID/SCID findings above sit unaudited for `conn.v`.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Closing: retains only enough info to identify packets + send CONNECTION_CLOSE; sends it in response to any packet attributed to the connection | 10.2.1 | ✅ | `process_datagram` (conn.v): while `.closing`, still runs normal packet processing (frame dispatch is a superset of "attributes to the connection", not a violation — the RFC only says this is NOT required, never that it's forbidden), then unconditionally checks the rate-limited retransmit gate afterward |
| SHOULD limit the rate of packets sent in the closing state | 10.2.1 | ✅ | `ConnectionCloseTracker.note_packet_received_while_closing` (connection_close.v): at most one retransmission per received datagram — a stricter (1:1) bound than the RFC's own example ("progressively increasing"), an explicitly permitted "equivalent rate-limiting scheme" |
| An endpoint that discards packet protection keys when entering closing MUST limit cumulative sent bytes to 3x cumulative received bytes (anti-amplification) | 10.2.1 | N/A | This client never exercises the MAY this MUST is conditioned on — `discard_initial_keys`/`discard_handshake_keys` are only ever called at their normal RFC 9001 §4.9 points (already covered above), never additionally on entering `.closing`/`.draining`; grepped conn.v for both call sites to confirm neither is reachable from `close_with_error`/`enter_draining` |
| MUST discard packets from an unvalidated (migrated) address, or bound sent bytes to it, while closing | 10.2.1 | N/A | Connection migration is out of v1 scope project-wide (see §5.1 note above); `QuicConn` has no notion of peer socket address at all — the caller owns the UDP socket per this project's single-threaded, caller-driven architecture (`PROGRESS.md`), so a migrated-address check has no field to key off yet |
| An endpoint sending CONNECTION_CLOSE prior to handshake confirmation SHOULD use the highest available protection level, most-advanced-first (Handshake over Initial) | 10.2.3 | ✅ | `build_best_effort_close_packet` (conn.v): 1-RTT → Handshake → Initial, in that order, each gated on the corresponding keys still being available |
| **A CONNECTION_CLOSE of application-error type (0x1d) MUST be replaced by the transport-error type (0x1c), with the Reason Phrase field cleared, when sent in an Initial or Handshake packet** | 10.2.3 | ⚠️→✅ | **Self-found while building this section, not reported externally.** `close()` (the public API) always marks its request `is_application_error: true` with the caller's real reason string, with no way to know in advance which packet level `close_with_error`/`build_best_effort_close_packet` will actually pick — calling `close()` before `app_write_keys` exists (i.e. still mid-handshake, only Handshake/Initial keys available) encoded and sent the real application reason string in cleartext-adjacent Handshake/Initial protection. Reproduced before fixing: `test_close_before_one_rtt_keys_downgrades_to_transport_connection_close` failed on `assert !close_frame.is_application_error` against the unfixed code. Fixed: `close_with_error` now downgrades to transport-type + empty reason whenever `c.app_write_keys == none`, decided once before encoding (the same encoded frame is replayed verbatim on every §10.2.1 retransmission, so getting it right once here is sufficient); test passes fixed |
| Draining: received a peer CONNECTION_CLOSE (or reset); MUST NOT send anything further; MAY send one CONNECTION_CLOSE before entering | 10.2.2 | ✅ | `process_datagram` returns immediately when `.draining` (conn.v L536-538), before any outgoing path can run; `handle_peer_connection_close`/stateless-reset detection both route through `enter_draining` which never itself queues an outgoing datagram — the permitted "MAY send one" is simply not exercised, which is conformant (MAY, not MUST) |
| **Draining ends at the SAME time closing would have — a peer CONNECTION_CLOSE received while ALREADY closing MUST NOT restart or extend the clock** | 10.2.2 | ⚠️→✅ | **Self-found while building this section — the first draft of this row wrongly claimed `.closing`→`.draining` "doesn't happen in current code" without checking; re-verifying that specific claim (per this file's own "citation and consequence are separate things to verify independently" lesson) found it was wrong: `process_datagram` only special-cases `.draining` before dispatching frames, not `.closing`, so a peer CONNECTION_CLOSE arriving while this endpoint is already `.closing` (e.g. simultaneous close, or the peer replying to this endpoint's own CONNECTION_CLOSE) reaches `handle_peer_connection_close` → `enter_draining(now)` normally. `enter_draining` unconditionally recomputed `c.closing_deadline = c.closing_or_draining_deadline(now)` using the CURRENT `now`, overwriting the deadline `close_with_error` had already set from an EARLIER `now` — extending the period on every such packet instead of preserving the original end time the RFC requires. Reproduced before fixing: `test_closing_deadline_not_extended_by_peer_close_while_already_closing` failed on `assert preserved_deadline == original_deadline`. Fixed: `enter_draining` now only sets `closing_deadline` `if c.closing_deadline == none` |
| Endpoint with no connection state does not enter closing/draining on sending CONNECTION_CLOSE | 10.2 | N/A | Only reachable for a server rejecting a stateless Initial before any connection object exists — this client only ever calls `close_with_error` on an already-constructed `QuicConn`, which by definition has state |

## Stateless Reset (RFC 9000 §10.3)

Audited 2026-08-14 against the primary text (`rfc-texts/rfc9000.txt` §10.3-
10.3.1) — `stateless_reset.v` (an earlier phase) also had no matrix section
until now.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Sending a Stateless Reset (last-resort response to an unassociated packet, MAY) | 10.3 | N/A (server-only in practice) | A client with no listening/accept surface has no "packet I can't associate with any connection" case to respond to the way a server does — v1 is client-only (Phase 13, server, explicitly deferred); this codebase has no Stateless Reset ENCODER at all, only the detection side below |
| A stateless reset token is specific to a connection ID; learned via the peer's `stateless_reset_token` transport parameter (sequence 0) or a `NEW_CONNECTION_ID` frame (sequence 1+, as of Phase 14b) | 10.3 | ✅ | `record_token` called both from the transport-parameter path (`peer_params.stateless_reset_token`, keyed by `c.peer_scid`) and, as of 14b, from `dispatch_one_rtt_frame`'s `NewConnectionIdFrame` arm for every subsequently-issued peer CID (`c.stateless_reset.record_token(frame.connection_id, frame.stateless_reset_token)!`) — previously only sequence 0's token was ever recorded, since NEW_CONNECTION_ID frames were entirely ignored before 14b; test: `test_dispatch_new_connection_id_frame_records_stateless_reset_token` |
| Detection MUST only be attempted as a fallback AFTER normal packet processing has already failed, never as a first-choice interpretation (§10.3.1) | 10.3.1 | ✅ | `note_one_rtt_processing_failed` is called from every failure exit of `process_one_rtt_packet` (header parse, header-protection removal, PN decode, key resolution, AEAD decrypt) and nowhere else; a successful decrypt never reaches it |
| Comparison against the trailing 16 bytes MUST NOT be a variable-time operation an attacker could use to guess the token byte-by-byte | 10.3.1 (implementation-level, not literal text) | ✅ | `is_stateless_reset` uses `crypto.subtle.constant_time_compare`, not a byte loop or slice `==` |
| A genuine reset must still be recognizable even though it's shaped like an ordinary packet — a DCID-mismatch/other-failure short-circuit MUST NOT bypass the reset check | 10.3.1 (interaction with §7.2's DCID check, added this session) | ✅ | Already covered by the Connection-level state machine section above — `note_one_rtt_processing_failed` runs for the DCID-mismatch path too, not just decrypt failures |
| Endpoint receiving a valid Stateless Reset immediately ends the connection | 10.3 | ✅ | `note_one_rtt_processing_failed`: a match calls `enter_draining(now)` + reports a `connection_closed` event |
| MUST NOT treat a Stateless Reset as appropriate for signaling errors in an active connection (that's what CONNECTION_CLOSE is for) — this is a sender-side MUST | 10.3 | N/A | No encoder exists (see first row) — nothing in this codebase could violate it |
| Endpoints MUST discard packets too small to be valid QUIC packets (e.g. short-header <21 bytes) | 10.3 | ✅ | `is_stateless_reset` itself requires `datagram.len >= 16` before comparing; the actual packet-too-short rejection for ordinary processing is `header_protection.v`'s own sampling-length check (already covered under Header Protection), which runs and fails BEFORE `note_one_rtt_processing_failed` is ever reached for an undersized datagram — same effective outcome |

**Not yet audited against this section**: `stateless_reset.v`'s own pre-
existing `stateless_reset_test.v` suite (referenced, not re-derived line by
line — that file predates `conn.v` and was in scope for its own Phase 8
matrix work, which this pass did not separately redo). Flagged rather than
silently claimed complete.

## Flow control wiring in conn.v (RFC 9000 §4)

Audited 2026-08-14, in response to a direct user challenge ("how confident
are we sure RFC been completed for phase 9") after the Connection-level
state machine section above turned up real gaps — this section scopes
strictly to conn.v's WIRING of flow control (admission checks, frame
dispatch, window creation/advancement). `flow_control.v`'s own primitives
(`FlowControlWindow`/`ReceiveWindow`) and `stream.v`'s own state machine
were audited separately during Phases 6/8/9b review rounds (see
[[code-review-misses]]) and are not re-derived here.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Senders MUST NOT send data in excess of the stream OR connection send limit | 4.1 | ✅ | `drain_pending_stream_writes`: `needed > send_window.available() \|\| needed > c.conn_send_window.available()` gates every queued write before it's ever framed onto the wire |
| A receiver MUST close with FLOW_CONTROL_ERROR if the sender violates the advertised limit | 4.1 | ✅ (generic code permitted) | `ReceiveWindow.note_received` rejects and errors when the peer exceeds `w.advertised`, propagating up through `!` to `poll()`'s catch-all `close_with_error`. The reported wire error code is generic `PROTOCOL_VIOLATION` (no `quic_error_flow_control_error`/`STREAM_LIMIT_ERROR`/`STREAM_STATE_ERROR`/`FINAL_SIZE_ERROR` constants exist in this module at all) rather than the specific code — RFC 9000 §11 explicitly permits this: "a generic error code (such as PROTOCOL_VIOLATION or INTERNAL_ERROR) can always be used in place of specific error codes." Not a violation; logged as a 🔸 improvement candidate for interop-testing precision, not a conformance gap |
| A sender MUST ignore MAX_STREAM_DATA/MAX_DATA that doesn't increase the limit | 4.1 | ✅ | `FlowControlWindow.raise_limit`: `if new_limit > w.limit { w.limit = new_limit }` — a non-increasing value is silently a no-op, for both the `MaxDataFrame` and `MaxStreamDataFrame` dispatch arms |
| RESET_STREAM's Final Size MUST be used to account for consumed flow-control credit, both stream- and connection-level | 4.4/4.5 | ✅ | `handle_reset_stream_frame`: `recv_window.note_received(frame.final_size)` then propagates the resulting delta into `c.conn_recv_window.note_received(...)`, mirroring `handle_stream_frame`'s identical pattern for ordinary STREAM frames |
| Both endpoints MUST maintain flow-control state for a bidirectional stream's UNTERMINATED direction until that direction reaches a terminal state | 4.4 | ✅ (trivially, by design) | Neither `stream_send_windows` nor `stream_recv_windows` nor `c.streams` is ever `.delete()`'d anywhere in conn.v — every stream's state, in both directions, is retained for the connection's whole lifetime. Conservative (a memory-growth characteristic over a long-lived connection with many streams) but never violates this MUST |
| An endpoint MUST NOT send data on a stream at or beyond its own final size | 4.5 | ✅ | `write_stream` rejects further writes once `stream.send.state` is `.data_sent`/`.reset_sent`/`.reset_recvd`/`.data_recvd` — `.data_sent` is entered on `mark_fin_sent`, so a write after FIN is rejected before ever reaching the wire |
| Endpoints MUST NOT exceed the stream-count limit set by their peer | 4.6 | ✅ | `open_stream`: `if opened_count >= limit { ...; return error(...) }` before `c.streams.open_local_stream` is ever called — `QuicStreamSet.open_local_stream` itself does NOT check this by design (its own doc comment says so), so `open_stream` is the correct, sole enforcement point |
| A frame referencing a stream ID exceeding OUR OWN advertised limit MUST be a connection error (STREAM_LIMIT_ERROR) | 4.6 | ✅ (generic code permitted, same §11 allowance as above) | `handle_stream_frame`/`handle_reset_stream_frame` both pass `c.local_max_streams_uni`/`bidi` into `QuicStreamSet.get_or_create`, which enforces the bound (verified during Phase 6/8 review, not re-derived here) |
| MAX_STREAMS frames that do not increase the limit MUST be ignored | 4.6 | ✅ | `MaxStreamsFrame` dispatch arm: `if frame.maximum_streams > c.peer_max_streams_bidi/uni { ...update... }` — non-increasing values are a no-op, mirroring the `raise_limit` pattern above |
| A max_streams value > 2^60 (transport parameter or frame) MUST close the connection (TRANSPORT_PARAMETER_ERROR / FRAME_ENCODING_ERROR respectively) | 4.6 | ✅ (pre-existing, not conn.v's job) | Enforced at parse time in `transport_parameters.v` (`initial_max_streams_bidi/uni ≤ 2^60`, see the Transport Parameters section above) and `frame.v`'s `parse_max_streams_frame`/`parse_streams_blocked_frame` (both capped, per [[code-review-misses]]'s STREAMS_BLOCKED sibling-sweep fix) — conn.v never sees an out-of-bound value, since the parser rejects it before a `MaxStreamsFrame`/transport-parameter value ever reaches conn.v's dispatch |
| An endpoint unable to open a stream due to the peer's limit SHOULD send STREAMS_BLOCKED | 4.6 | ✅ | `open_stream` queues via `c.pending_streams_blocked`, drained by `drain_pending_streams_blocked`; deduplicated per still-unraised limit value (`streams_blocked_sent_bidi/uni`) so a caller retrying `open_stream` against the same unchanged limit doesn't re-queue redundant frames |
| Implementations MAY increase locally-advertised MAX_DATA/MAX_STREAM_DATA/MAX_STREAMS over time — not a MUST for any of the three | 4.2/4.6 | ✅ / 🔸 (scope choice) | MAX_DATA/MAX_STREAM_DATA: `drain_flow_control_raises` auto-tunes and re-advertises both via `ReceiveWindow.should_advertise_more()`. MAX_STREAMS: `local_max_streams_bidi/uni` are FIXED for the connection's lifetime (own doc comment, conn.v L172-176) — this endpoint never grows its own advertised stream-count limit as streams close. RFC 9000 §4.6 phrases this as "implementations MIGHT choose to," not a MUST — a deliberate, documented scope choice (bandwidth/complexity tradeoff), not a gap |

No new gaps found. One 🔸 advisory (generic vs. specific wire error codes, RFC-permitted) and one documented scope choice (fixed vs. growing local stream limits, RFC-optional either way).

## ACK generation timing (RFC 9000 §13.2)

Audited 2026-08-14, same session and same trigger as the Flow control
section above.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Ack-eliciting Initial/Handshake packets MUST be acknowledged IMMEDIATELY | 13.2.1 | ✅ | `drain_outgoing`'s auto-ACK fires unconditionally on the very next `poll()`/`process_timeouts()` call after any ack-eliciting packet is received, in every space — no batching/delay logic exists at all, which trivially satisfies "immediately" (0 delay ≤ any positive bound) |
| Ack-eliciting 0-RTT/1-RTT packets MUST be acknowledged within the advertised `max_ack_delay` | 13.2.1 | ✅ (0-RTT N/A, out of v1 scope) | Same immediate auto-ACK as above for 1-RTT; 0 delay is always ≤ `max_ack_delay` |
| **An endpoint MUST NOT send more than one ACK-only packet in response to receiving an ack-eliciting packet** | 13.2.1 | ✅ | `drain_outgoing` sends at most one ACK-only datagram per space per call, and clears `*_received_pns` immediately after — the next call has nothing pending unless a genuinely new packet arrived |
| **An endpoint MUST NOT send a non-ack-eliciting packet in response to a non-ack-eliciting packet (avoids an infinite ack-feedback loop)** | 13.2.1 | ⚠️→✅ | **Self-found while building this section, not reported externally.** `process_initial_or_handshake`/`process_one_rtt_packet` added EVERY successfully-processed packet's number to `*_received_pns` regardless of whether any of its frames were ack-eliciting, and `drain_outgoing` unconditionally sent an ACK-only packet (itself non-ack-eliciting) whenever that map was non-empty — so a peer's own ACK-only packet (ACK is explicitly non-ack-eliciting per this same section) triggered an ACK-only reply, the exact case this MUST prohibits. Reproduced before fixing: `test_non_ack_eliciting_packet_does_not_elicit_an_ack` sent a bare ACK-frame 1-RTT packet and asserted `result.outgoing.len == 0`; failed on the unfixed code. Fixed: new `frame_is_ack_eliciting()` classifier (RFC 9000 §13.2.1's own definition — all frames except ACK/PADDING/CONNECTION_CLOSE) plus a new `*_ack_eliciting_pending` bool per space, set when any frame in a received packet is ack-eliciting; `drain_outgoing`'s three auto-ACK branches now gate on `*_received_pns.len > 0 && *_ack_eliciting_pending`, not `.len > 0` alone. `*_received_pns` itself is untouched by this fix (still accumulates every received PN regardless of type, so once an ack-eliciting packet DOES trigger an ACK, any previously-pending non-ack-eliciting PNs are correctly included in its ranges, matching §13.2.1's "non-ack-eliciting packets are only acknowledged when an ACK frame is sent for other reasons") |
| An endpoint MUST NOT send an ack-eliciting frame in every packet that would otherwise be non-ack-eliciting (keepalive padding, avoids the same infinite loop) | 13.2.1 | N/A | This client never pads an otherwise-ACK-only packet with an extra ack-eliciting frame for keepalive purposes — the MUST's precondition never arises |
| ACK Delay MUST NOT include delays the endpoint doesn't control | 13.2.5 | ✅ | `build_ack_frame_for` always reports `ack_delay = 0` — accurate, since this implementation never intentionally delays an ACK once triggered (generates and sends it in the same call that observed the ack-eliciting packet) |
| ACK frames MUST only be carried in a packet using the SAME packet-number space as the packet(s) being acknowledged | 13.2.6 | ✅ | `build_ack_frame_for(.initial/.handshake/.application_data)` is always paired with the matching `build_initial_packet`/`build_handshake_packet`/`build_one_rtt_packet` — no cross-space mixing exists anywhere in `drain_outgoing` |
| A receiver SHOULD send an ACK after at least two ack-eliciting packets (bandwidth-efficiency guidance, not a MUST) | 13.2.2 | ✅ (more conservative than required) | This implementation ACKs after every single ack-eliciting packet rather than batching — strictly more prompt than the SHOULD's guidance, which is always safe (never a conformance issue to acknowledge MORE promptly than recommended) |

One real gap found and fixed (the non-ack-eliciting feedback-loop MUST). No
other gaps.

## Loss-detection / congestion-control wiring in conn.v (RFC 9002)

Audited 2026-08-14, same session and trigger as the two sections above.
Scope: conn.v's WIRING of `loss_detection.v`/`rtt.v`/`congestion_control.v`
— those files' own algorithms were already RFC-9002-audited during Phase 7
(see [[code-review-misses]] for that round's 3 fixes), not re-derived here.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| **`on_ack_received`'s `ack_delay_exponent` parameter must be the PEER's own advertised value (RFC 9000 §18.2), used to correctly scale the ACK frame's raw ACK Delay field — not this endpoint's own value or the RFC's absent-default** | 9002 §5.3 (via `loss_detection.v`'s own doc-comment contract) | ⚠️→✅ | **Self-found while building this section, not reported externally — and provable directly from the callee's own doc comment**, which states in plain text: "`ack_delay_exponent` is the PEER's own ack_delay_exponent transport parameter." `handle_ack_frame` instead passed the bare `frame.v` constant `default_ack_delay_exponent` (3) unconditionally, on every call, regardless of what the peer actually advertised (legal up to 20). Any peer advertising a non-default exponent had every ACK Delay field it ever sent misinterpreted, corrupting the `smoothed_rtt`/`rttvar` the PTO timer is computed from. Reproduced before fixing: `test_handle_ack_frame_uses_peer_advertised_ack_delay_exponent` set a peer `ack_delay_exponent` of 12, drove two RTT samples, and asserted the resulting `smoothed_rtt` matched the value the CORRECT exponent predicts (and explicitly did NOT match what the buggy default-3 exponent would have produced) — failed against the unfixed code exactly as predicted. Fixed: `handle_ack_frame` now reads `c.handshake.peer_transport_parameters.ack_delay_exponent or { default_ack_delay_exponent }` (the `or` branch correctly covers the RFC's own "absent → default 3" case, which is the ONLY case the old code accidentally handled right) |
| `on_ack_received`'s newly-acked/lost results MUST drive congestion control (`OnPacketsAcked`/`OnPacketsLost`, RFC 9002 Appendix A.6) | 9002 §7 (via Appendix A.6/A.10) | ✅ | `handle_ack_frame`: `congestion_control.on_packets_acked(result.newly_acked)` unconditional, `congestion_control.on_packets_lost(result.lost, result.persistent_congestion, now)` gated on `result.lost.len > 0` (an empty-slice call would be a harmless no-op either way, but the guard matches the sibling `process_timeouts` call site's own identical gating) |
| Every sent ack-eliciting/in-flight packet MUST be registered via `OnPacketSent` (Appendix A.5), and `OnPacketSentCC` MUST be called for in-flight packets specifically | 9002 §6.2 (via Appendix A.5) | ✅ (verified per-space, not assumed identical) | `build_handshake_packet`/`build_one_rtt_packet` both derive `in_flight := is_ack_eliciting` and gate `congestion_control.on_packet_sent_cc` on it — straightforward. `build_initial_packet` looks inconsistent at first read (hardcodes `in_flight=true` and calls `on_packet_sent_cc` UNCONDITIONALLY, with no `is_ack_eliciting` gate) — but this is CORRECT, not a sibling-parity bug: RFC 9000 §13.2.7 "PADDING Frames Consume Congestion Window" states packets containing PADDING are in flight for congestion-control purposes regardless of ack-eliciting status, and `build_initial_packet` always pads to the 1200-byte §14.1 floor via `pad_initial_payload` — so EVERY Initial packet this client sends genuinely is in flight, unconditionally, and the function's own doc comment already states this reasoning explicitly. Verified by reading the full §13.2.7 text and the padding call site, not accepted from the comment alone |
| A PTO timer expiration MUST send at least one ack-eliciting packet in the timed-out space | 9002 §6.2.4 | ✅ | `send_pto_probe` sends exactly one PING (always ack-eliciting) in `timeout_result.pto_space` — satisfies the MUST; the RFC's "MAY send up to two" and "SHOULD also probe other spaces with in-flight data" are both optional, and this v1 simplification (documented in the function's own comment) doesn't implement either optional behavior — a bandwidth-efficiency tradeoff, not a conformance gap |
| `process_timeouts`'s PTO-fired/packets-lost dispatch MUST match Appendix A.9's `OnLossDetectionTimeout` structure (PTO branch XOR loss branch, not both) | 9002 Appendix A.9 | ✅ | `process_timeouts`: `if timeout_result.pto_fired { send_pto_probe(...) } else if timeout_result.lost.len > 0 { congestion_control.on_packets_lost(...) }` — mirrors the pseudocode's own if/else-if structure exactly |
| **When Initial/Handshake keys are discarded, the sender MUST discard recovery state for packets sent with those keys AND remove them from bytes in flight** | 9002 §6.4 | ⚠️ STILL OPEN (pre-existing, self-disclosed, not fixed in this pass) | `discard_initial_keys`/`discard_handshake_keys` (conn.v) wipe the discarded space's `sent_packets` tracking (`c.loss_detection.initial/handshake = LossDetectionSpaceState{}`) but do NOT credit back whatever those packets' bytes contributed to `congestion_control.bytes_in_flight` — the byte count silently stays inflated for the rest of the connection. This is NOT a newly-found gap: both functions' own doc comments already state it explicitly ("the precise RFC 9002 §6.4 interaction with bytes_in_flight/congestion accounting for packets that were still outstanding in the discarded space is not separately modeled... a documented follow-up, not a Phase 9a blocker"). Bounded impact (fires at most twice per connection — once per space discarded — not unbounded or peer-triggerable per-packet) and affects only congestion-window headroom precision, not correctness/security. Flagging honestly as still-open per this file's own "no silent gaps" standard, rather than re-asserting it as newly resolved; a real fix needs `bytes_in_flight -= sum(sent_packets[space][*].sent_bytes)` at each discard point before wiping the map, not attempted here since it's an explicit, previously-agreed scope deferral, not a silent miss this pass should unilaterally overturn |

One real gap found and fixed (peer `ack_delay_exponent` ignored). One
pre-existing, already-self-disclosed gap (§6.4 bytes-in-flight credit-back
on key discard) confirmed still open, not newly discovered, left as a
flagged follow-up rather than fixed without being asked.

## Key update wiring in conn.v (RFC 9001 §6)

Audited 2026-08-14, same session and trigger as the sections above. Scope:
conn.v's WIRING of `key_update.v`'s `KeyUpdateState` — the READ-side
generation-resolution logic in `key_update.v` itself was already RFC-9001-
audited during Phase 8 (repeat-offender fixes for HP-key-preservation and
generation-ambiguity, see [[code-review-misses]]) and is not re-derived
here.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| An endpoint MAY initiate its own key update once the handshake is confirmed | 6/6.1 | N/A (documented v1 scope) | This client never spontaneously starts its own update — `key_update.v`'s file-level doc comment states this is deferred past v1. A MAY, not a MUST; legitimately out of scope |
| A peer's key update is detected by a Key Phase bit differing from the last-sent value; the endpoint uses the next key/IV to process it | 6.2 | ✅ (pre-existing, Phase 8) | `KeyUpdateState.resolve_read_keys`/`note_successful_decrypt` — already audited |
| **The endpoint MUST update its send keys to the corresponding key phase in response to a detected peer-initiated update** | 6.2 | ⚠️→✅ | **Self-found while building this section, not reported externally — and directly provable from `key_update.v`'s own file-level scope note, which conflated two different things.** The doc comment said "client-initiated key rotation... deferred past v1," correctly describing this client never choosing to START its own update — but `c.app_write_keys` was set exactly once (at handshake completion) and never touched again anywhere in conn.v, and `build_one_rtt_packet` hardcoded the outgoing Key Phase bit to `false` forever. That's not the same thing as never initiating: §6.2's MUST is a mandatory REACTION to whatever the peer does, not something this endpoint opts into. Since this never happened, every packet sent after a server-initiated rotation — including the ACK for the very packet that triggered it — stayed on generation 0 forever. Confirmed severe by reading the very next requirement below. Fixed: new `app_write_secret`/`app_write_generation` fields on `QuicConn`, a new `sync_write_keys_to_peer_update()` that steps the write chain forward one generation at a time using the same `derive_updated_secret`/`derive_updated_packet_protection_keys` primitives the read side uses (read/write chains are independent per §6.1, just seeded from different starting secrets), called immediately after every successful 1-RTT decrypt commit — before that same `poll()` call's `drain_outgoing` can send anything. `build_one_rtt_packet`'s Key Phase bit is now `c.app_write_generation % 2 == 1`. Verified via ablation, not just forward-tested: reverted both the sync call and the phase-bit expression, confirmed `test_client_follows_server_initiated_key_update` fails exactly as predicted (`assert c.app_write_generation == 1`), then restored and reconfirmed green — this finding was fixed before a proper Phase-R test existed (an accepted deviation given the fix's size), so the ablation stands in for the usual "reproduce on buggy code first" step |
| **Sending keys MUST be updated BEFORE sending an acknowledgment for the packet that was received with updated keys** | 6.2 | ✅ | `sync_write_keys_to_peer_update()` is called synchronously inside `process_one_rtt_packet`, strictly before that same `poll()` call reaches `drain_outgoing` (which is what would send the auto-ACK) — order is structural (both run inside the same function-call chain triggered by the same `poll()` invocation), not timing-dependent. Test confirms the actual outgoing ACK datagram decrypts correctly under the NEW generation's keys |
| An endpoint MUST retain old (read) keys until it has successfully unprotected a packet sent using the new keys | 6.1 | ✅ (pre-existing, Phase 8) | `KeyUpdateState.previous_keys` — already audited; no write-side analog needed (the write side controls its own timing, never needs to "still decrypt" with an old write generation) |
| Consecutive key updates without an intervening acknowledgment MAY be treated as KEY_UPDATE_ERROR (rate-limiting a peer that updates too fast) | 6.2 | ✅ (pre-existing, Phase 8) | `KeyUpdateState.max_key_updates_accepted` bounds total accepted updates over the connection's life — a coarse, time-independent stand-in for the RFC's timing-based pacing norm, already documented as such |
| Header protection key is NOT updated across a key update | 6.1 | ✅ (pre-existing, Phase 8) | `derive_updated_packet_protection_keys` preserves the `hp` field — the same function `sync_write_keys_to_peer_update` reuses for the write side, so this guarantee carries over automatically without needing to be re-derived |

One real, previously-undiscovered gap found and fixed — arguably the most
severe finding of this whole audit pass, since RFC 9001 §6.2's own final
paragraph gives a compliant server explicit license to treat the
now-fixed symptom as a fatal `KEY_UPDATE_ERROR` the first time it ever
rotates keys against this client.

## HTTP/3 framing layer (RFC 9114 §6.2, §7, §8.1, §9, §10.8)

Audited 2026-08-15, BEFORE writing `h3_frame.v`/`h3_stream_type.v`/
`h3_error.v`/`h3_reserved.v`/`h3_message_state.v` (Phase 10) — this section
was built from a full, section-by-section read of the fetched primary text
(`rfc-texts/rfc9114.txt`, §4.1, §6.2-§6.2.3, §7-§7.2.8, §8-§8.1, §9, §10.8,
§11.2.1-§11.2.4), not written after the fact and reconciled against
whatever the code happened to do. This is the direct structural response
to Phase 9's own standing lesson (see that section's postmortem above):
build the phase's RFC checklist before/during implementation, not as a
reactive audit once someone asks "are you sure."

**Scope boundary, stated up front:** "HTTP/3 framing" (RFC 9114 §7's own
title) covers the frame Type/Length/Payload envelope, every frame type's
payload layout, the unidirectional stream type header (§6.2), and the
parts of frame *legality* that need only a stream's ROLE (Table 1,
control-stream SETTINGS-first discipline). It deliberately does NOT cover
the rest of §4's message semantics — HEADERS→DATA*→trailer-HEADERS
ordering WITHIN one request/response, single-request-per-stream
enforcement, CONNECT's distinct framing, PUSH_PROMISE/CANCEL_PUSH/
MAX_PUSH_ID cross-frame state tracking (largest push ID advertised so far,
push IDs already used) — all of which need real request/response objects
and connection role state that don't exist until Phase 12 wires this layer
into `QuicConn`. Every row below marked "Phase 12" is a deliberate,
documented deferral, not a forgotten requirement — same discipline as the
RFC 9002 §6.4 row in the Key update section above.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Frame format is Type(varint) + Length(varint) + Payload(exactly Length bytes) | 7.1 | ✅ | `encode_h3_frame_envelope`/`H3FrameDecoder.next` — both fields use the shared QUIC varint codec (`varint.v`), not a bespoke encoding |
| A frame's declared Length MUST exactly match the length of the fields it contains — trailing or missing bytes MUST be H3_FRAME_ERROR | 7.1, 10.8 | ✅ | Every fixed-shape payload parser (CANCEL_PUSH/GOAWAY/MAX_PUSH_ID) checks `n == payload.len` after its one varint; SETTINGS' loop only exits cleanly at `offset == payload.len`, erroring on any truncation mid-pair. Tests: `test_cancel_push_frame_rejects_trailing_bytes`, `test_settings_frame_rejects_truncated_payload` |
| HTTP/3 frames can span multiple QUIC packets — parsing must be resumable, not single-shot | 7 (line 1415) | ✅ | `H3FrameDecoder` buffers across `push()` calls; `next()` returns `has_frame: false` (not an error) on an incomplete frame. Tests: `test_h3_frame_decoder_waits_for_full_frame_byte_by_byte`, `test_h3_frame_decoder_settings_split_across_pushes_mid_payload` |
| A declared Length far larger than what's buffered so far must never be misread as "ready" via integer truncation | 7.1 (self-derived hardening, not a literal RFC sentence) | ✅ | Caught in review before first compile, not by an external round: `int(length)` on an attacker-controlled u64 up to 2^62-1 truncates/wraps on Windows' 32-bit `int`. Fixed by comparing `total_u64` against `u64(d.pending.len)` before ever narrowing to `int`. Test: `test_h3_frame_decoder_huge_declared_length_with_insufficient_bytes_does_not_panic` |
| DATA frame payload is opaque content bytes | 7.2.1 | ✅ | `DataFrame`/`encode_data_frame`/decode arm |
| DATA frame received on control stream MUST be H3_FRAME_UNEXPECTED | 7.2.1 (Table 1) | ✅ (role-legality only) | `is_h3_frame_valid_on_stream` returns false for `DataFrame` on `.control`. The actual connection-close ACTION is Phase 12 (needs a real `QuicConn` to close) |
| HEADERS frame payload is a QPACK-encoded field section | 7.2.2 | ✅ (opaque bytes only) | `HeadersFrame` stores the still-encoded bytes; QPACK decode is Phase 11 |
| HEADERS on control stream MUST be H3_FRAME_UNEXPECTED | 7.2.2 (Table 1) | ✅ (role-legality only) | Same `is_h3_frame_valid_on_stream` table; action deferred to Phase 12, same as DATA above |
| CANCEL_PUSH carries one push-ID varint, sent only on the control stream | 7.2.3 | ✅ | `CancelPushFrame`/`encode_cancel_push_frame`; role legality via `is_h3_frame_valid_on_stream` |
| CANCEL_PUSH referencing a push ID greater than currently allowed, or not yet mentioned by a PUSH_PROMISE, MUST be H3_ID_ERROR | 7.2.3 | ⏳ Phase 12 | Needs cross-frame state (the client's own advertised max push ID; which push IDs have appeared in a PUSH_PROMISE) that doesn't exist until Phase 12 wires PUSH_PROMISE/MAX_PUSH_ID/CANCEL_PUSH together on a real connection |
| SETTINGS MUST be the first frame of each control stream; MUST NOT be sent subsequently; a second SETTINGS frame MUST be H3_FRAME_UNEXPECTED; a non-SETTINGS first frame (including grease) MUST/SHOULD be H3_MISSING_SETTINGS | 6.2.1, 7.2.4, 9 | ✅ | `H3ControlStreamState.note_frame` — the ONE piece of §4.1-adjacent sequencing state this phase does implement, since it needs only per-stream order, not request/response context. Tests: `test_h3_control_stream_state_rejects_non_settings_first_frame`, `test_h3_control_stream_state_rejects_grease_as_first_frame`, `test_h3_control_stream_state_rejects_second_settings_frame(_after_other_frames)` |
| SETTINGS received on a non-control stream MUST be H3_FRAME_UNEXPECTED | 7.2.4 (Table 1) | ✅ (role-legality only) | `is_h3_frame_valid_on_stream`; action deferred to Phase 12 |
| The same setting identifier MUST NOT occur more than once; a receiver MAY treat a duplicate as H3_SETTINGS_ERROR | 7.2.4 | ✅ (chose to enforce the MAY) | `decode_h3_settings_payload`'s `seen_ids` map. Documented in-code as a deliberate strict choice, not a literal MUST — matches this project's established preference for the RFC's own stricter reading where a MAY is offered (§4.1.2's "deliberately strict... permissive can expose implementations to vulnerabilities" rationale). Test: `test_settings_frame_rejects_duplicate_identifier` |
| An implementation MUST ignore any SETTINGS parameter with an identifier it does not understand | 7.2.4 | ✅ (parse-time: stored, not rejected) | Unrecognized (non-reserved, non-grease) identifiers decode into the `settings` list rather than erroring — e.g. QPACK's own 0x01/0x07, correctly NOT in this phase's reserved set. ACTING on "ignore" (i.e. not applying it) is Phase 12's job once settings are actually applied to connection state. Test: `test_settings_frame_accepts_unknown_non_reserved_identifier` |
| Setting identifiers of the form 0x1f*N+0x21 are reserved grease; MUST NOT be treated as meaningful | 7.2.4.1 | ✅ | Grease identifiers pass through `decode_h3_settings_payload` unrejected (same path as any other unrecognized id — no special-casing needed since grease is just a subset of "unrecognized"). Round-trip test: `test_settings_frame_roundtrip_and_preserves_order`'s second entry (0x21) |
| Setting identifiers HTTP/2 defined with no HTTP/3 equivalent (0x00, 0x02, 0x03, 0x04, 0x05) MUST NOT be sent; receipt MUST be H3_SETTINGS_ERROR | 7.2.4.1, 11.2.2 (Table 3) | ✅ | `h3_settings_reserved_h2_carryover_ids` + the check in `decode_h3_settings_payload`, exact values transcribed directly from Table 3, not recalled. Test: `test_settings_frame_rejects_reserved_h2_carryover_identifiers` (all 5) |
| PUSH_PROMISE carries a push ID + QPACK-encoded field section | 7.2.5 | ✅ (decode only) | `PushPromiseFrame`; no encoder exists — a v1 client role never sends this frame type (§7.2.5's own "A client MUST NOT send a PUSH_PROMISE frame"), enforced by API surface (no reachable call site) rather than a runtime check. Test: `test_push_promise_frame_decode_only` |
| PUSH_PROMISE containing a push ID larger than the client has advertised via MAX_PUSH_ID MUST be H3_ID_ERROR | 7.2.5 | ⏳ Phase 12 | Needs the client's own advertised max-push-ID state |
| A server reusing a push ID across multiple PUSH_PROMISE frames MUST send identical field sections; a client detecting a mismatch MUST be H3_GENERAL_PROTOCOL_ERROR | 7.2.5 | ⏳ Phase 12 | Needs cross-PUSH_PROMISE comparison state |
| PUSH_PROMISE on the control stream, or received by anything other than a client (server MUST treat receipt as an error too, but this is a client-only implementation), MUST be H3_FRAME_UNEXPECTED | 7.2.5 (Table 1) | ✅ (role-legality only, control-stream half) | `is_h3_frame_valid_on_stream`; action deferred to Phase 12 |
| GOAWAY is always sent on the control stream; applies to the whole connection | 7.2.6 (Table 1) | ✅ (role-legality only) | `is_h3_frame_valid_on_stream`; the actual close/drain behavior GOAWAY triggers is Phase 12 |
| GOAWAY carries a generic id: a client-initiated bidi stream ID (server→client) or a push ID (client→server) | 7.2.6 | ✅ (generic decode; direction left to caller) | `GoawayFrame{id}` — deliberately not split into two variants at this layer, since distinguishing them needs to know which direction/role this connection is (documented on the struct itself) |
| A client MUST treat a received GOAWAY whose stream ID is not a client-initiated bidirectional stream ID as H3_ID_ERROR | 7.2.6 | ✅ (pure predicate only) | `goaway_id_is_valid_client_initiated_bidi_stream_id` (RFC 9000 §2.1: id%4==0 for that stream category). The connection-error ACTION is Phase 12; this phase provides the one piece of the check that needs no connection state. Test: `test_goaway_id_is_valid_client_initiated_bidi_stream_id` |
| MAX_PUSH_ID is always sent on the control stream; a server MUST NOT send one; a client MUST treat receipt as H3_FRAME_UNEXPECTED | 7.2.7 (Table 1) | ✅ (role-legality only) + N/A (see next row) | `is_h3_frame_valid_on_stream`; the specific "client rejects any MAX_PUSH_ID it receives" behavior needs no state at all beyond "I am a client and I received this frame type" — a Phase 12 dispatch-level concern, not a framing concern |
| MAX_PUSH_ID cannot reduce the maximum; a smaller value than previously received MUST be H3_ID_ERROR | 7.2.7 | N/A for v1 client role | This rule binds a SERVER receiving MAX_PUSH_ID from a client (§7.2.7: "the maximum value for a push ID that the server can use"); a v1 client never receives one in a context where this check would apply — it only ever SENDS MAX_PUSH_ID. Genuinely out of scope by role, not a deferred gap; re-audit if/when Phase 13 (server support) is ever undertaken |
| Reserved frame types (0x1f*N+0x21) MAY be sent on any stream where frames are allowed; MUST NOT be treated as meaningful | 7.2.8 | ✅ | `H3RawFrame` + `is_h3_reserved_codepoint`; `is_h3_frame_valid_on_stream`'s `H3RawFrame` arm returns `true` for every role. Test: `test_decode_grease_frame_type_is_ignored_not_rejected`, `test_is_h3_frame_valid_on_stream_reserved_row_is_universal` |
| Frame types HTTP/2 used with no HTTP/3 equivalent (0x02, 0x06, 0x08, 0x09) MUST NOT be sent; receipt MUST be H3_FRAME_UNEXPECTED | 7.2.8, 11.2.1 (Table 2) | ✅ | `h3_reserved_h2_carryover_frame_types`, exact 4 values transcribed directly from Table 2 (not assumed from the H2 registry by analogy — verified each is genuinely absent from HTTP/3's own table). Tests: `test_decode_rejects_reserved_h2_carryover_frame_types`, `test_h3_frame_decoder_returns_error_for_reserved_frame_type_and_stops_consuming` |
| Genuinely unrecognized (non-reserved, non-grease) extension frame types MUST be ignored, not rejected | 9 | ✅ | Read §9's actual text directly ("Implementations MUST ignore unknown or unsupported values in all extensible protocol elements") rather than assuming HTTP/2's precedent carried over unchanged — falls into the same `H3RawFrame` path as grease. Test: `test_decode_genuinely_unknown_frame_type_is_ignored_not_rejected` |
| An unknown frame type in a position requiring a KNOWN type (i.e. first-frame-of-control-stream) does not satisfy that requirement and SHOULD be an error | 9 | ✅ | `H3ControlStreamState.note_frame` treats any non-SETTINGS first frame — including `H3RawFrame` — as `H3_MISSING_SETTINGS`. Test: `test_h3_control_stream_state_rejects_grease_as_first_frame` |
| Control stream: unidirectional, indicated by Stream Type 0x00 | 6.2.1 | ✅ | `h3_control_stream_type`, `classify_h3_unidirectional_stream_type` |
| Only one control stream per peer permitted; receipt of a second MUST be H3_STREAM_CREATION_ERROR; sender MUST NOT close it; closure at any point MUST be H3_CLOSED_CRITICAL_STREAM | 6.2.1 | ⏳ Phase 12 | Needs the connection's own stream registry (has a control stream already been claimed?) — no such registry exists in this framing-only file |
| Push stream: unidirectional, Stream Type 0x01 + push ID varint | 6.2.2 | ✅ | `h3_push_stream_type`, `parse_h3_unidirectional_stream_header`'s `.push` arm |
| A server receiving a client-initiated push stream MUST be H3_STREAM_CREATION_ERROR | 6.2.2 | N/A for v1 client role | This client never RECEIVES a client-initiated push stream (it isn't a server); genuinely out of role scope, same reasoning as the MAX_PUSH_ID-reduction row above |
| Each push ID MUST only be used once as a push stream header; a repeat MUST be H3_ID_ERROR | 6.2.2 | ⏳ Phase 12 | Needs cross-push-stream tracking of push IDs already seen as stream headers |
| Reserved stream types (0x1f*N+0x21) have no semantics; MUST NOT be treated as meaningful | 6.2.3 | ✅ | `classify_h3_unidirectional_stream_type` returns `.reserved` via the shared `is_h3_reserved_codepoint` helper. Test: `test_classify_h3_unidirectional_stream_type_known_kinds` |
| Unidirectional stream header parsing must be resumable — RFC places no requirement on how header bytes are split across QUIC STREAM frames | 6.2 (implied by the same "spans multiple packets" principle as frame parsing) | ✅ | `parse_h3_unidirectional_stream_header` returns `none` (not an error) on a short buffer, same design as `H3FrameDecoder`. Tests: `test_parse_h3_unidirectional_stream_header_returns_none_on_partial_type_varint`, `..._returns_none_on_partial_push_id`, `..._incremental_feed_byte_by_byte` |
| An unknown/unsupported unidirectional stream type MUST have its data discarded/aborted, and MUST NOT be treated as a connection error of any kind | 6.2 | ⏳ Phase 12 | The "abort or discard" ACTION needs a real QUIC stream to act on; this phase only classifies the type (`.unknown`) |
| Error codes 0x0100-0x0110 (17 values) | 8.1, 11.2.3 (Table 4) | ✅ | `H3ErrorCode` enum, every value transcribed directly from the fetched RFC text, cross-checked once against Table 4's restatement of the same 17 values |
| Error codes of the form 0x1f*N+0x21 are reserved grease; unknown/unexpected-context error codes MUST be treated as equivalent to H3_NO_ERROR | 8, 8.1 | ✅ (codepoint recognition only) | `is_h3_reserved_codepoint` covers this numeric space too (shared helper, verified identical formula across all 4 registries — see `h3_reserved.v`'s module doc comment). Actually REMAPPING an unrecognized error code to H3_NO_ERROR on receipt is a Phase 12 concern (needs a real place that receives a QUIC-carried error code) |

**Deliberately out of scope for this file, confirmed genuinely absent from
RFC 9114 §7 itself (not overlooked):** no frame-level maximum-size cap.
§7.1/§10.8 require only that Length match the payload's actual fields
exactly — DATA frames legitimately carry arbitrarily large bodies, and
capping Length here would incorrectly reject a spec-legal large DATA
frame. Resource exhaustion from a peer sending Length bytes before ever
completing a frame is already bounded upstream by QUIC's own per-stream
flow-control window (RFC 9000 §4.1) — `H3FrameDecoder.pending_len()` is
exposed specifically so Phase 12 can cross-check that assumption against
the real flow-control window once one exists, rather than this file
inventing its own arbitrary cap unprompted.

## QPACK (RFC 9204)

Audited 2026-08-16, BEFORE writing any `qpack_*.v` file (Phase 11) — built
from a full, section-by-section read of the fetched primary text
(`rfc-texts/rfc9204.txt`, all of §1-§8, Appendix A's static table, and
Appendix B's byte-exact worked examples), not written after the fact. Same
discipline as the HTTP/3 framing section above, itself the direct response
to Phase 9's own standing lesson.

**Scope boundary, stated up front, mirroring Phase 10's own precedent
exactly:** QPACK's tables, wire codecs, and the encoder/decoder STATE
MACHINES are all self-contained — like Phase 10's `H3ControlStreamState`,
they only need to be *fed* bytes/events by whatever eventually owns a real
QUIC stream, not the stream itself. That entire layer is Phase 11 scope.
What's deferred to Phase 12: writing encoder-stream bytes onto a real QUIC
unidirectional stream under real flow control (§2.1.3), blocking/unblocking
a live HTTP/3 request stream's read progress (§2.2.1 — needs Phase 12's
request/response objects), and applying a peer's actual
`SETTINGS_QPACK_MAX_TABLE_CAPACITY`/`SETTINGS_QPACK_BLOCKED_STREAMS` values
from a real SETTINGS frame to a real connection (Phase 11 provides the pure
extraction helper only). Every row below marked "Phase 12" is a deliberate,
documented deferral of exactly this shape — not a forgotten requirement.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Prefixed integer: N-bit prefix (2-8), continuation encoding identical to RFC 7541 §5.1 | 4.1.1 | ✅ | `qpack_primitives.v` `decode_prefixed_int`/`encode_prefixed_int`, parameterized prefix width; algorithm verified against the already-shipped, tested `h2_hpack.v` `read_int`/`h2_hpack_write_int` (RFC 7541 §5.1 sibling) before writing, not reinvented |
| Implementations MUST be able to decode integers up to and including 62 bits | 4.1.1 | ✅ | Decode cap chosen at 2^62-1 to match this project's own QUIC varint range (`varint.v`'s `max_varint`) — a deliberate, documented implementation limit satisfying the MUST-support minimum, not an arbitrary smaller cap |
| String literal: H bit + length as prefixed integer + Huffman-coded or raw bytes; N-bit prefix variant (prefix begins mid-byte, N in 2..8) | 4.1.2 | ✅ | `qpack_primitives.v` `decode_prefixed_string`/`encode_prefixed_string` |
| When Huffman-encoded, the Huffman table is RFC 7541 Appendix B, used WITHOUT MODIFICATION | 4.1.2 | ✅ | `qpack_huffman_table.v`/`qpack_huffman.v` are a verbatim copy of `h2_hpack_huffman_table.v`/`h2_hpack_huffman.v` (module/name-prefix changes only) — copying a proven, already-tested table is strictly safer than hand-transcribing RFC 7541 Appendix B's diagram a second time, and the RFC itself mandates byte-identity, so divergence would be a bug by definition |
| Static table has 99 entries (index 0-98), indexed from 0 (NOT 1, unlike HPACK) | 3.1, Appendix A | ✅ | `qpack_static_table.v`, all 99 rows transcribed directly from the fetched Appendix A table, not recalled from HPACK's 61-entry table by assumption. Test: exact-count + spot-check first/last/duplicate-name entries |
| Invalid static index in a field line representation MUST be QPACK_DECOMPRESSION_FAILED; same on the encoder stream MUST be QPACK_ENCODER_STREAM_ERROR | 3.1 | ✅ | Bounds-checked lookup returns a typed error; caller (field-line vs. encoder-instruction decode path) selects which QPACK error code applies |
| Dynamic table entry size = name.len + value.len + 32 (computed pre-Huffman) | 3.2.1 | ✅ | `qpack_dynamic_table.v` `entry_size` |
| Initial dynamic table capacity is 0; capacity changed only via Set Dynamic Table Capacity | 3.2.2 | ✅ | `QpackDynamicTable` zero-value capacity; `set_capacity` is the only mutator |
| Before inserting, entries evicted from the tail until size <= capacity - new entry size; MUST NOT evict a non-evictable entry; inserting an entry larger than capacity MUST be QPACK_ENCODER_STREAM_ERROR | 3.2.2 | ✅ | `QpackDynamicTable.insert`/`can_insert`; evictability = `abs_index < known_received_count && ref_count == 0` (§2.1.1) |
| Reducing capacity evicts entries down to the new capacity (same evictable-only constraint); capacity 0 clears the table, capacity can later be restored | 3.2.2 | ✅ (fixed 2026-08-19, was a false ✅) | `QpackDynamicTable.set_capacity` itself still evicts unconditionally (correct — it mirrors `insert`'s "trust the caller already checked" split, and the DECODER calls it directly on every encoder-supplied capacity value with no choice to reject). The evictable-only constraint is enforced by the new `can_set_capacity` check, called from `QpackEncoder.set_capacity` before applying a reduction. Luna review (round 2, GPT-5.6) found this row's prior ✅ was wrong: `QpackEncoder.set_capacity` had no such check at all, so an encoder-side capacity reduction could silently evict an entry an unacknowledged field section still referenced — Phase-R reproduced, fixed by adding `can_set_capacity` (mirrors `can_insert`'s simulate-eviction pattern) |
| Maximum dynamic table capacity is bounded by the decoder's `SETTINGS_QPACK_MAX_TABLE_CAPACITY`; encoder MUST NOT exceed it | 3.2.3 | ✅ (pure check; value plumbing is Phase 12) | `QpackEncoder.set_capacity(new_cap, peer_max)` takes the peer's max as an explicit parameter rather than owning SETTINGS state itself |
| 0-RTT remembered-value validation of `SETTINGS_QPACK_MAX_TABLE_CAPACITY` | 3.2.3 | N/A | This project has 0-RTT deferred to Phase 14 entirely (see "Known design notes" below); no 0-RTT code path exists for this check to guard |
| When max table capacity is 0, encoder MUST NOT insert entries and MUST NOT send any encoder instructions | 3.2.3 | ✅ | `QpackEncoder` guards every instruction-emitting path on `peer_max_capacity > 0` |
| Absolute index: fixed per entry, first insert = 0, increases by 1 per insertion | 3.2.4 | ✅ | `QpackDynamicTable.insert_count` used directly as the next absolute index |
| Relative index in ENCODER INSTRUCTIONS: 0 = most recently inserted entry (shifts as more instructions are processed) | 3.2.5, Fig. 2 | ✅ | `QpackDynamicTable.resolve_relative_from_insert_count` — relative-to-"now", used only by encoder-instruction decode/encode (Insert-with-dynamic-name-ref, Duplicate) |
| Relative index in FIELD LINE REPRESENTATIONS: 0 = entry with absolute index (Base - 1), stable regardless of processing order | 3.2.5, Fig. 3 | ✅ | `QpackDynamicTable.resolve_relative_from_base` — a distinct function from the encoder-instruction one above precisely because the reference point differs (this project's own doc comment calls out the distinction explicitly, since conflating the two contexts is the most likely transcription error here) |
| Post-Base index: 0 = entry with absolute index == Base, increasing with absolute index | 3.2.6, Fig. 4 | ✅ | `QpackDynamicTable.resolve_post_base` |
| Set Dynamic Table Capacity: `001` + 5-bit prefix capacity | 4.3.1 | ✅ | `qpack_encoder_instructions.v` `encode_set_dynamic_table_capacity`/decode arm |
| Insert With Name Reference: `1` + T(static/dynamic) + 6-bit prefix name index + value string literal | 4.3.2 | ✅ | `encode_insert_with_name_ref`/decode arm |
| Insert With Literal Name: `01` + name as 6-bit-prefix string literal + value as 8-bit-prefix string literal | 4.3.3 | ✅ | `encode_insert_with_literal_name`/decode arm |
| Duplicate: `000` + 5-bit prefix relative index; reinserts without resending name/value | 4.3.4 | ✅ | `encode_duplicate`/decode arm; dynamic-table `duplicate(rel_index)` copies name+value into a fresh entry at the new absolute index |
| Section Acknowledgment: `1` + 7-bit prefix stream ID; acknowledges the earliest unacknowledged field section with dynamic-table references on that stream | 4.4.1 | ✅ | `qpack_decoder_instructions.v` `encode_section_ack`/decode arm; `QpackEncoder.note_section_acknowledged(stream_id)` |
| Ack referring to a stream with nothing left to acknowledge MUST be QPACK_DECODER_STREAM_ERROR | 4.4.1 | ✅ | `note_section_acknowledged` errors when the stream has no outstanding unacknowledged field section |
| Stream Cancellation: `01` + 6-bit prefix stream ID; releases all of that stream's outstanding dynamic-table references | 4.4.2 | ✅ | `encode_stream_cancellation`/decode arm; `QpackEncoder.note_stream_cancelled(stream_id)` |
| Insert Count Increment: `00` + 6-bit prefix increment; increases Known Received Count by Increment | 4.4.3 | ✅ | `encode_insert_count_increment`/decode arm; `QpackEncoder.note_insert_count_increment(n)` |
| Increment of 0, or one that pushes Known Received Count beyond what the encoder has actually sent, MUST be QPACK_DECODER_STREAM_ERROR | 4.4.3 | ✅ | `note_insert_count_increment` bounds-checks against `dynamic_table.insert_count` |
| Encoded Field Section Prefix: Required Insert Count as 8-bit-prefix encoded integer (wraparound-encoded per the exact modular arithmetic given) + Sign bit + Delta Base as 7-bit-prefix integer | 4.5.1, 4.5.1.1, 4.5.1.2 | ✅ (fixed 2026-08-19) | `qpack_field_line.v` `encode_ric`/`decode_ric` and `encode_base`/`decode_base` transcribe the RFC's own pseudocode directly (not a from-scratch reimplementation of the modular arithmetic). Luna review (round 2) found `encode_ric` divided by zero (`% full_range`) whenever `max_table_capacity < 32` made `full_range` 0 — the RFC's own pseudocode never states this bound explicitly, and `decode_ric` already guarded it while `encode_ric` didn't; `encode_ric` now returns an error for that case, matching its sibling, and `encode_field_section_prefix`/`encode_field_section` propagate it as a Result |
| Decoder MUST reject an EncodedInsertCount value no conformant encoder could have produced | 4.5.1.1 | ✅ | `decode_ric` follows the RFC's decoder pseudocode's own error branches exactly (`EncodedInsertCount > FullRange`, post-unwrap `ReqInsertCount > FullRange`, decoded-zero-after-nonzero-input) |
| Base MUST NOT be negative; Sign=1 with Delta Base >= Required Insert Count is invalid | 4.5.1.2 | ✅ | `decode_base` returns an error on that condition |
| Indexed Field Line: `1` + T + 6-bit prefix index (absolute index < Base) | 4.5.2 | ✅ | `qpack_field_line.v` decode/encode arm |
| Indexed Field Line with Post-Base Index: `0001` + 4-bit prefix post-Base index (absolute index >= Base) | 4.5.3 | ✅ | decode/encode arm |
| Literal Field Line with Name Reference: `01` + N + T + 4-bit prefix name index + value string literal | 4.5.4 | ✅ | decode/encode arm, N bit threaded through to the returned/input field line's `never_index` |
| Literal Field Line with Post-Base Name Reference: `0000` + N + 3-bit prefix post-Base name index + value string literal | 4.5.5 | ✅ | decode/encode arm |
| Literal Field Line with Literal Name: `001` + N + H + 3-bit prefix name length/string + value string literal | 4.5.6 | ✅ | decode/encode arm |
| 'N' bit: intermediary MUST NOT re-encode with an indexed representation | 4.5.4, 7.1.3 | N/A | Binds an INTERMEDIARY re-forwarding a field line under a different QPACK/HPACK compression context; this is a v1 client/server endpoint, never a proxy re-encoding on behalf of a third party. The bit itself is still correctly parsed/encoded (see rows above) — only the re-encoding-constraint half of §7.1.3 is out of role scope |
| Encoder should mark low-entropy/high-value fields (Cookie, Authorization) as never-indexed | 7.1.3 (SHOULD-level guidance, not a MUST) | ✅ (policy choice) | `qpack_is_sensitive` mirrors `h2_hpack.v`'s existing `h2_is_sensitive` (cookie/authorization/proxy-authorization) — same security posture applied consistently across both compression schemes in this codebase, not a fresh, unreviewed policy |
| Reference to an evicted dynamic entry, or absolute index >= declared Required Insert Count, in a field line representation MUST be QPACK_DECOMPRESSION_FAILED | 2.2.3 | ✅ | `QpackDecoder.decode_field_section` checks both conditions before resolving any index |
| Reference to an evicted entry in an ENCODER instruction MUST be QPACK_ENCODER_STREAM_ERROR (distinct error code from the field-line case above) | 2.2.3 | ✅ | `QpackDecoder.apply_encoder_instruction` uses the encoder-stream error code, not the field-section one — a distinction easy to collapse by accident since both are "stale reference," verified as a deliberate two-branch design rather than one shared helper |
| Required Insert Count > decoder's current Insert Count ⇒ field section is "blocked", not an error; decoder waits, does not fail | 2.1.2, 2.2.1 | ✅ | `QpackDecoder.decode_field_section` returns a `blocked` result (not an error) in this case, mirroring Phase 10's `H3FrameDecoder`'s "return not-ready, not error" shape for the same "insufficient data so far" situation |
| Required Insert Count smaller than the field section's own actual minimum MUST be QPACK_DECOMPRESSION_FAILED; larger than expected MAY be QPACK_DECOMPRESSION_FAILED | 2.2.1 | ✅ (chose to enforce the MAY, consistent with this project's established preference — see Phase 10's SETTINGS-duplicate-ID row) | `QpackDecoder` tracks the actual max referenced absolute index while decoding and compares against the declared RIC after finishing |
| Encoder MUST limit streams that could become blocked to `SETTINGS_QPACK_BLOCKED_STREAMS`; exceeding the decoder's own promised limit MUST be QPACK_DECOMPRESSION_FAILED | 2.1.2 | ✅ (encoder self-limit) / ⏳ Phase 12 (decoder-side enforcement needs a live count of ACTUALLY blocked real streams) | `QpackEncoder.blocked_stream_budget` tracks how many in-flight field sections it has risked blocking, bounded by a caller-supplied `SETTINGS_QPACK_BLOCKED_STREAMS` value |
| Known Received Count: encoder's belief of decoder's Insert Count, updated by Section Ack (to at least the acked RIC) and Insert Count Increment | 2.1.4 | ✅ | `QpackEncoder.known_received_count`, updated by both `note_section_acknowledged` and `note_insert_count_increment` per their respective rules |
| Encoder MUST NOT insert an entry when doing so would require evicting a non-evictable entry (i.e., must skip indexing rather than force it) | 2.1.1 | ✅ | `QpackDynamicTable.can_insert` — `QpackEncoder`'s single-pass algorithm falls back to a literal when this returns false, per Appendix C's own `shouldIndex(...) and dynamicTable.canIndex(...)` gate |
| Draining-index heuristic to avoid referencing near-eviction entries | 2.1.1.1 | Deliberately not implemented (optional heuristic, not a MUST) | The RFC's own wording is "an encoder CAN... one heuristic is..." — a correct encoder may simply accept the (bounded, self-limited-by-`can_insert` above) risk of an occasional forced-literal fallback instead of pre-emptively avoiding it; noted here as a design choice, not a gap, same treatment as Phase 10's "no frame-size cap" note |
| Encoder SHOULD NOT write an instruction unless sufficient stream/connection flow-control credit is available for the whole instruction (deadlock avoidance) | 2.1.3 | ⏳ Phase 12 | Needs real QUIC stream flow-control state from `conn.v`, which this framing-only layer does not have |
| Streams: unidirectional, type 0x02 (encoder, both directions of use) / type 0x03 (decoder) | 4.2, 8.2 | ✅ | `qpack_stream_type.v` `qpack_encoder_stream_type`/`qpack_decoder_stream_type` constants |
| At most one encoder stream and one decoder stream per endpoint; a second instance of either MUST be H3_STREAM_CREATION_ERROR | 4.2 | ✅ (tracking state only; action deferred) | `QpackStreamRegistry`, mirrors Phase 10's `H3ControlStreamState` shape exactly (a from-scratch sibling comparison against that struct was done before writing this one) — records "seen" and returns the error on a repeat, the actual connection-close ACTION is Phase 12 same as every "role-legality only" row in the HTTP/3 section above |
| Sender MUST NOT close either stream; receiver MUST NOT request closure; closure of either MUST be H3_CLOSED_CRITICAL_STREAM | 4.2 | ⏳ Phase 12 | Needs a real QUIC stream whose closure can be observed/acted on |
| An endpoint MAY avoid creating an encoder stream if unused; MAY avoid a decoder stream if max dynamic table capacity is 0 | 4.2 | ✅ (permissive by construction) | Nothing in this phase forces stream creation — `QpackEncoder`/`QpackDecoder` work purely on bytes handed to them, imposing no "must open a stream" requirement of their own |
| `SETTINGS_QPACK_MAX_TABLE_CAPACITY` (0x01), default 0 | 5, 8.1 | ✅ | `qpack_settings.v` `qpack_max_table_capacity_from_settings`, default-0 fallback when absent from the peer's `[]H3Setting` |
| `SETTINGS_QPACK_BLOCKED_STREAMS` (0x07), default 0 | 5, 8.1 | ✅ | `qpack_blocked_streams_from_settings`, same default-fallback shape |
| Error codes QPACK_DECOMPRESSION_FAILED (0x0200), QPACK_ENCODER_STREAM_ERROR (0x0201), QPACK_DECODER_STREAM_ERROR (0x0202) | 6, 8.3 | ✅ | `qpack_error.v` `QpackErrorCode` enum, mirrors `h3_error.v`'s `H3ErrorCode` shape (sibling checked before writing) |
| Implementation MUST set a limit on accepted integer values/encoded length and string literal length; oversized MUST be a stream error (request stream) or connection error of the appropriate type (encoder/decoder stream) | 7.4 | ✅ (limit chosen + enforced; which error/scope applies is the caller's job per context) | `qpack_primitives.v` enforces a maximum decoded string length and the 62-bit integer cap from the row above; returns a typed error the caller maps to the right QPACK error code for its stream context |

**Deliberately out of scope for this file, confirmed genuinely absent from
RFC 9204 itself (not overlooked):** no additional dynamic-table probing
countermeasures beyond the 'N' bit and the sensitive-header policy above —
§7.1.2's "segregate access by entity" and "penalize repeated guesses"
mitigations are both explicitly framed as implementation options ("can
instead constrain," "might introduce a penalty"), not requirements, and
this v1 client has exactly one entity (itself) producing requests, so the
cross-entity threat model §7.1.1 describes (an intermediary or browser
multiplexing mutually distrustful origins on one connection) does not apply
until this codebase implements an intermediary role, which is outside all
committed scope (Phase 13 is server-only, not proxy).

## Known design notes (not bugs)

- **No 0-RTT** (Phase 14, explicitly out of committed scope): Early Secret is
  still computed for real (feeds the Handshake Secret derivation chain), but
  no PSK path, no early data key derivation, and `early_data` in
  EncryptedExtensions is a hard error rather than silently accepted.
- **No client-certificate authentication**: CertificateRequest is rejected
  outright rather than answered with an empty Certificate. `PROGRESS.md`'s
  stated scope.
- **STALE NOTE, corrected 2026-08-14 — kept for history, do not trust the
  claim below:** this used to say packet protection, header protection, the
  stream layer, loss detection, and connection lifecycle were "not yet on
  this branch" and warned every `⏳ DEFERRED` row above would need
  re-auditing once those branches landed. They landed (Phases 3/4/6/7/8/9,
  all the way through `conn.v`) and this note was never revisited — directly
  contributing to the gap the new "Connection-level state machine" section
  above exists to close. **The actual standing rule, not tied to any one
  phase:** any row marked `⏳ DEFERRED` because its enforcement point "isn't
  on this branch yet" MUST be re-audited the moment that file actually lands,
  as part of THAT phase's own `/vreview`/matrix-update step — not left for a
  future external reviewer to notice is still open.

## How to use

0. **Before triaging any new Codex round, grep this file for `⏳` and check
   each hit's cited file against `git log --oneline <base>..HEAD -- <file>`
   — if that file has ANY commits on this branch, the row is stale and MUST
   be re-verified against the current code (flip to ✅/⚠️ as appropriate)
   BEFORE using the matrix to argue "already covered."** The rule to
   re-audit deferred rows once their phase lands already existed in this
   file (see the branch-status note above) but was NOT followed when Phase
   3 and Phase 4 actually landed here — three rows (reserved-bits ×2, VN
   version-list discard) sat stale through five full Codex review rounds on
   this exact code, and a sixth Codex finding (undersized-Initial-datagram
   discard, pullrequestreview-4839675790) landed on a FOURTH stale row that
   additionally conflated two distinct §14.1 clauses under one vague title.
   Worse than merely stale: the VN row's description had the requirement
   backwards (inverted from RFC 9000 §6.2's actual text and from the
   correct, already-fixed code) — a wrong row is more dangerous than a
   missing one, since a future reviewer could "fix" correct code to match
   it. Found and closed 2026-08-02; see [[code-review-misses]].
1. On any change to a file listed above, re-walk the rows touching that area.
2. A new MUST discovered → add a row as ⚠️ GAP, then close it (fix + test) and
   flip to ✅ CONFORMS with the commit that closed it — same discipline as
   `h2_conformance_matrix.md`. Don't delete GAP rows once closed; leave the
   history (see the `initial_source_connection_id` row above as the template).
3. When a downstream phase branch (packet protection, streams, loss detection,
   connection lifecycle) merges into this branch, add new sections for it
   here rather than starting a second matrix file — one standing artifact per
   protocol, matching H2's convention.
4. Rows without a mechanical detector are verified by reading — this matrix
   itself is the detector for "missing MUST" findings; there is no script
   equivalent to `run_detectors.sh` for QUIC yet (the H2 detectors are keyed
   to H2-specific bug shapes and don't generalize).

## Server role (Phase 13) — added 2026-09-08, reconstructed FROM external findings

**Read the note before using this section.** Every row below was written
*after* vlang/v#28164's external review found it, not by a proactive audit —
this is a post-mortem reconstruction, so it is a floor on what the server role
requires, never a ceiling. Treat an area absent from this table as UNAUDITED,
not as conforming. The reason it exists at all: the server role was reviewed
incrementally as diffs against working client code, ~40 findings landed across
~20 review rounds, and four of the classes below produced no diff line for any
A-I angle to react to. See `/vreview` Phase 0 step 8 (new-role audit), which
this section is the worked example for.

### Loss recovery / retransmission (RFC 9000 §13) — the largest gap

A server must retain everything it sends until acknowledged. The client role
never exercised this in v1 (its flights are small and its own PTO path was
already built), so the port inherited none of it.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Initial ServerHello retained until acknowledged | 13.3 | GAP→fixed | found externally, `conn.v` |
| Server handshake CRYPTO retained for retransmission | 13.3 | GAP→fixed | found externally, `conn.v:2029` |
| HANDSHAKE_DONE retransmitted when its packet is lost | 13.3 | GAP→fixed | found externally, `conn.v:2064` |
| Response STREAM bytes retained for loss recovery | 13.3 | GAP→fixed | found externally, `h3_server_d_http3.v:1061` |

### Anti-amplification (RFC 9000 §8.1) — mechanism existed, never wired

`AntiAmplificationLimiter` was written in Phase 13b and no send path ever
called it. **The check that finds this is a CALL-SITE grep, not a definition
grep** — see Phase 0 step 8's "wired-not-just-written" sub-check.

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Next datagram must fit the remaining 3x budget before send | 8.1 | GAP→fixed | found externally |
| Close/CONNECTION_CLOSE packets counted against the budget | 8.1 | GAP→fixed | found externally, `conn.v:2665` |
| Budget lifted once Retry token validates the address | 8.1 | GAP→fixed | found externally, `accept.v:186` |

### Unbounded peer-controlled buffering (DoS) — mechanically detectable

All four were in scope for `detect_unbounded_accum.sh`, which was never run
against the server files. Run it on every new `h3_*`/server file.

| Requirement | Status | Evidence |
|---|---|---|
| Incomplete HEADERS frame buffering bounded | GAP→fixed | `h3_frame.v:428` |
| Incomplete DATA frame buffering bounded (aggregate) | GAP→fixed | `h3_conn.v:688` |
| Request-body cap enforced BEFORE buffering a whole DATA frame | GAP→fixed | `h3_server_d_http3.v:191` |
| Aggregate request-body buffering capped across streams | GAP→fixed | `h3_server_d_http3.v:191` |

### Role-asymmetric HTTP/3 frames (RFC 9114 §7.2) — inherited unchanged from the client port

Each of these means something *different* received as a server. The port
carried the client's interpretation across unchanged.

| Requirement | § | Status |
|---|---|---|
| MAX_PUSH_ID accepted (not rejected) in the server role | 7.2.7 | GAP→fixed |
| Repeated MAX_PUSH_ID allowed when non-decreasing | 7.2.7 | GAP→fixed |
| Client-sent PUSH_PROMISE is a connection error | 7.2.5 | GAP→fixed |
| GOAWAY identifier is a Push ID when received as a server | 7.2.6 | GAP→fixed |
| GOAWAY identifier must not increase | 7.2.6 | GAP→fixed |

### HTTP semantics at the server boundary — parity gaps vs `h2_server.v`

`h2_server.v` already implemented every one of these. A function-by-function
parity pass against it was never run (Phase 0 step 7, sibling search).

| Requirement | Status |
|---|---|
| Unknown request method rejected, not silently coerced to GET | GAP→fixed |
| CONNECT with empty `:authority` rejected | GAP→fixed |
| CONNECT rejected outright until tunnel dispatch exists | GAP→fixed |
| Handler-produced 1xx terminal responses rejected | GAP→fixed |
| No DATA on HEAD / 204 / 304 responses | GAP→fixed |
| Request trailer field sections validated | GAP→fixed |
| Oversized request streams stay rejected until completion | GAP→fixed |

#### Outbound response field sections (RFC 9114 §4.2) — added 2026-09-19

§4.2 verbatim: "An endpoint MUST NOT generate an HTTP/3 field section
containing connection-specific fields; any message containing
connection-specific fields MUST be treated as malformed. The only exception
to this is the TE header field, which MAY be present in an HTTP/3 *request*
header; when it is, it MUST NOT contain any value other than 'trailers'."
Both filters live in `h3_server_d_http3.v`: `h3_outbound_response_fields`
(header section) and `h3_outbound_trailer_fields` (trailer section), joined
by `h3_response_field_is_forbidden`. Walk BOTH sections per row — a rule
enforced in one and not the other is a GAP.

| Requirement | Status | Evidence |
|---|---|---|
| Connection-specific fields (`connection`/`keep-alive`/`proxy-connection`/`transfer-encoding`/`upgrade`) never generated in a response header OR trailer section | ✅ | `h3_response_field_is_forbidden` → `h2_conn_specific_headers`; both call sites |
| **TE never generated in a response header OR trailer section** — §4.2's exception covers request headers only, so a response TE is a connection-specific field | ⚠️→✅ | GAP on `29a933e6c3`: both filters checked only `h2_conn_specific_headers`, whose own doc comment says TE "is handled on the send side" — a claim no send-side code honored (medvednikov, vlang/v#28164 pullrequestreview-5246850132). Fixed `e041801019`; test `test_h3_server_drops_te_from_response_headers_and_trailers` fails on the prior head |
| Field names lowercase on the wire | ✅ | `key.to_lower()` in both filters |
| No invalid characters (NUL/CR/LF) in generated values | ✅ | `h2_field_value_has_forbidden_octet` drop in both filters (stricter than `h2_server.v`'s own send path, which does not check) |
| Only `:status` as a response pseudo-header; no handler-authored pseudo-header can leak | ✅ (by construction) | `Header.add_custom` → `is_valid` rejects `:` (not a tchar); the trailer filter's `starts_with(':')` guard is belt-and-braces |
| Request-side TE: value other than `trailers` rejected as malformed | ✅ | `h3_request_field_error` → `h2_request_field_error` (`h2_server.v`) |
| **Received response (client role, `h3_mux_conn_d_http3.v` `wait_response`) with a connection-specific field, uppercase/non-token name, forbidden octet, or TE -- in the header OR trailer section -- treated as malformed; trailers carry no pseudo-header; `content-length` digits-only, in range, consistent across duplicates** | ❌→✅ | GAP logged 2026-09-19 (only pseudo-headers validated; trailers not at all; malformed CL silently ignored). Fixed `c87a692e7a`, vlang/v#28875: `h3_response_field_error` on both sections. Tests `test_wait_response_rejects_malformed_response_fields` / `..._malformed_or_conflicting_content_length` fail on master. Intentionally stricter than the h2 client (which checks neither TE nor values). Local failure only -- no H3_MESSAGE_ERROR on the wire (no public per-stream reset API), same as the pre-existing `:status` checks |
| Leading/trailing whitespace in generated values | ADVISORY | RFC 9114 §4.2 has no such MUST (RFC 9113 §8.2.1 does); parity with `h2_server.v`, which also does not trim |

### Driver-loop / listener correctness

| Requirement | Status | Note |
|---|---|---|
| Due timeouts run even when a datagram also arrived | GAP→fixed | the loop was `if n > 0 { poll } else { process_timeouts }` — an either/or that starves timers under load |
| Response bodies fragmented before queuing | GAP→fixed | |
| More than one response chunk drained per drive | GAP→fixed | |
| Peer address changes rejected before polling pinned connections | GAP→fixed | `listener.v:302` |
| Handshake resources freed before retiring listener connections | GAP→fixed | `listener.v:437` |

### Still UNAUDITED for the server role

No proactive pass has been done on: server-side flow control (§4), stream
limits and MAX_STREAMS issuance (§4.6), key update as responder (RFC 9001 §6),
stateless reset generation (§10.3), connection migration (out of v1 scope but
its §5.1.x CID-state obligations are NOT — see Angle H's scope-note bullet),
or ECN/PMTU. Audit before touching any of them; do not infer from the fixed
rows above that the role is now generally covered.

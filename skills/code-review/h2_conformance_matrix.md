# HTTP/2 conformance matrix (vlang/v net.http client + minimal server)

A requirements-driven map of RFC 9113 (HTTP/2, obsoletes 7540) and RFC 7541
(HPACK) normative requirements to the V implementation. The point of this file is
to make **absence** visible: a diff-driven review reacts to what changed; a
missing MUST produces no diff. Audit by enumerating rows, not by waiting for a
reviewer. Update on every change to the h2 files; flip GAP→CONFORMS with a
`file:line` or commit when closed.

Files: `vlib/net/http/h2_frame.v` (framing), `h2_hpack*.v` (HPACK),
`h2_conn.v` (sync client), `h2_mux_conn.v` (mux client), `h2_server.v` (minimal
server), `h2_client.v` (Request↔H2 adapter).

Status: ✅ CONFORMS · ⚠️ GAP · 🔸 ADVISORY/optional · N/A.
Last audited 2026-07-02 (HEAD current branch — server h2spec baseline empty, 146/146).

## Framing (RFC 9113 §4, §6)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| DATA/HEADERS/CONTINUATION/PRIORITY/RST/PUSH_PROMISE on stream 0 → error | 6.1–6.10 | ✅ | h2_frame.v L246/258/289/309/349/403 |
| SETTINGS/PING/GOAWAY/WINDOW_UPDATE on non-zero stream → error | 6.5–6.9 | ✅ | h2_frame.v L321/365/377 |
| Padding length ≥ frame payload → error | 6.1 | ✅ | h2_strip_padding L236 |
| Fixed frame lengths (PRIORITY 5, RST 4, PING 8, WU 4, SETTINGS %6) | 6.x | ✅ | h2_frame.v L292/312/333/368/390 |
| SETTINGS ACK has empty payload | 6.5 | ✅ | h2_frame.v L326 |
| Unknown frame types ignored | 4.1 | ✅ | H2UnknownFrame L412 |
| Enforce SETTINGS_MAX_FRAME_SIZE on received frames | 4.2 | ✅ | h2_mux_conn.v mux_read_frame (FRAME_SIZE error) |
| Reserved bit on stream id ignored on read | 4.1 | ✅ | h2_parse_frame_header `& 0x7fff_ffff` L206 |

## Connection preface & SETTINGS (RFC 9113 §3.4, §6.5)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Client sends preface (magic + SETTINGS) before other frames | 3.4 | ✅ | handshake_locked sends h2_client_preface + SETTINGS; ACKs deferred pre-preface |
| Each received SETTINGS (non-ACK) gets exactly one ACK | 6.5 | ✅ | pending_settings_acks counter (per-frame ACK) |
| SETTINGS_ENABLE_PUSH must be 0/1 | 6.5.2 | ✅ | apply_peer_settings (error if >1) |
| SETTINGS_MAX_FRAME_SIZE in [16384, 2^24-1] | 6.5.2 | ✅ | apply_peer_settings range check |
| SETTINGS_INITIAL_WINDOW_SIZE ≤ 2^31-1; delta overflow → FLOW_CONTROL_ERROR | 6.5.2/6.9.2 | ✅ | apply_peer_settings two-pass (commit 321e9d3920) |
| SETTINGS_MAX_HEADER_LIST_SIZE honored on send (advisory) | 6.5.2 | ✅ | stored + enforced both paths (commit f541b520eb) |
| Respect SETTINGS_MAX_CONCURRENT_STREAMS | 5.1.2 | ✅ | peer_max_streams admission gate |

## Stream lifecycle & identifiers (RFC 9113 §5.1)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Client stream IDs odd, monotonic, ≤ 2^31-1 | 5.1.1 | ✅ | next_stream_id += 2; exhaustion check do_on_stream |
| Frame on idle (≥ next_id) or even (server-initiated) stream → conn error | 5.1.1 | ✅ | check_unknown_stream L1482 |
| DATA before response HEADERS → error | 8.1 | ✅ | h2_conn.v L283; mux on_response_data (reset_stream) |
| DATA after END_STREAM: closed (both sides)→conn error, half-closed-remote→RST | 5.1 | ✅ | h2_mux_conn.v L1428-1439 (send_closed split) |
| Per-stream faults use RST_STREAM, not connection error | 5.4 | ✅ | reset_stream throughout; manual error-scope audit clean |
| No new streams after GOAWAY (recheck serialized with write) | 6.8 | ✅ | goaway flag + wmu-serialized recheck (commit 4496950803) |

## Flow control (RFC 9113 §6.9)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| WINDOW_UPDATE 0 increment: stream 0→conn error, stream→RST | 6.9 | ✅ | on_window_update L1040/1051 vs L1057/1079 |
| Window > 2^31-1: stream 0→conn error, stream→RST | 6.9.1 | ✅ | same split |
| Padding counts toward flow control; credit flow_size not data.len | 6.9.1 | ✅ | detect_padding_credit.sh (commit 744325e1cf) |
| Connection-level receive window enforced | 6.9 | ✅ | conn_recv_window debit/credit (recv_wmu) |

## HPACK (RFC 7541)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Integer decode overflow rejected | 5.1 | ✅ | h2_hpack.v read_int L115 |
| Index 0 reference invalid | 6.1 | ✅ | h2_hpack.v L257 |
| Huffman: EOS symbol / >7-bit pad / non-all-ones pad rejected | 5.2 | ✅ | h2_hpack_huffman.v L77/86/91 |
| SETTINGS_HEADER_TABLE_SIZE constrains our ENCODER (not decoder) | 6.3 | ✅ | encoder.pending_max_table_size; detect_mux_table_size_update.sh |
| CONTINUATION-flood cap (CVE-2024-27316 class) | 6.10 | ✅ | h2_max_recv_header_block |
| HEADERS/CONTINUATION contiguity (no interleave, same stream, END_HEADERS) | 6.10 | ✅ | collect loop: "CONTINUATION on wrong stream"/"expected CONTINUATION"; server: dispatch_frame "unexpected CONTINUATION frame" rejects an orphan CONTINUATION when no block is in progress (h2_server.v ~L349, fixes Codex #27589 pullrequestreview-4613845079) |

## Header fields & messages (RFC 9113 §8.1–§8.3)

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Request: lowercase names, strip connection-specific, Host→:authority, cookie collapse | 8.2/8.2.2/8.2.5 | ✅ | to_h2_request h2_client.v |
| Request: TE only "trailers" | 8.2.2 | ✅ | to_h2_request (commit c53bd09018) |
| Response: reject uppercase field names | 8.2.1 | ✅ | h2_response_field_error (commit f0e9728282) |
| Response: reject connection-specific fields | 8.2.2 | ✅ | h2_response_field_error |
| Response: only :status pseudo, before regular, no duplicates | 8.3 | ✅ | seen_regular/seen_status checks (both paths) |
| Trailers: no pseudo-headers; §8.2 field rules apply | 8.1 | ✅ | trailers branch rejects (commit f0e9728282) |
| Response MUST carry valid :status (3-digit, not 101, 100-599) | 8.3.1 | ✅ | both paths validate :status |
| Malformed Content-Length → malformed | 8.1.1 | ✅ | all_digits guard + else-error (commit 4b2bc7081e) |
| Body length matches Content-Length at END_STREAM | 8.1.1 | ✅ | wait_response/read_response length check |
| 1xx interim: don't latch headers_done; END_STREAM on 1xx → error | 8.1 | ✅ | both paths (commits 0aa2c8d543, a6884cef9d) |
| Response trailers preserved to caller | 8.1 | ✅ | resp_trailers (commit dde05d7c80) |
| Field-name token charset fully validated (beyond uppercase) | 8.2.1 | 🔸 | only uppercase/empty/conn-specific checked; full RFC 5234 token charset not enforced (low risk; servers send valid tokens) |

## Server request validation (h2_server.v, RFC 9113 §8.1.2) — PR vlang/v#27569

Inbound-request equivalents of the client response rules above; malformed →
RST_STREAM(PROTOCOL_ERROR) (stream error, §8.1.1). Validated in finalize_headers
after the HPACK decode. Closed 12 h2spec cases (109→120 pass).

| Requirement | § | Status | Evidence |
|---|---|---|---|
| Request: reject uppercase / empty field names | 8.1.2 | ✅ | h2_request_field_error |
| Request: reject connection-specific fields; TE only "trailers" | 8.2.2 | ✅ | h2_request_field_error + h2_conn_specific_headers const |
| Request pseudo: known set only, no dups, before regular, :method/:path/:scheme present+non-empty | 8.1.2.1/8.1.2.3/8.3 | ✅ | h2_validate_request_pseudo |
| Request content-length == DATA length (charset-guarded parse) | 8.1.2.6 | ✅ | build_request + h2_all_digits |
| Request trailers: 2nd HEADERS block, no pseudo, decoded to keep HPACK in sync | 8.1 | ✅ | on_trailers/finalize_trailers |
| Negative stream window via SETTINGS tolerated (wait for WINDOW_UPDATE) | 6.9.2 | ✅ | send_body window loop (incidental h2spec pass) |
| Server HPACK decode errors → conn COMPRESSION_ERROR (not RST) | 4.3/5.2/6.x | ✅ | finalize_headers/finalize_trailers send_goaway(.compression_error) on decode failure (#27569, Codex); closed 9 h2spec hpack cases |
| Server stream-state: frame on idle stream → conn PROTOCOL_ERROR | 5.1/6.4 | ✅ | classify_stream; on_data/dispatch RST/handle_control_frame WINDOW_UPDATE (PR2, 8 cases). classify_stream also treats any `locally_reset` id as closed regardless of last_stream_id — a self-dependent PRIORITY (§5.3.1) can RST an id never opened via HEADERS, so in-flight DATA/WINDOW_UPDATE/RST_STREAM for it must drain per §6.4, not conn-error as idle (Codex P2, #27627 pullrequestreview-4618166175). The self-dependent-PRIORITY guard itself now gates RST on `classify_stream(...) != .closed` (idle or active → RST; closed, whether via locally_reset or normal completion → skip, since RST_STREAM is not a frame permitted on a closed stream) — a narrower `locally_reset`-only exemption missed the normal-completion case (Codex P2, #27627 pullrequestreview-4620220448). `finalize_headers` also now checks `s.self_dep` BEFORE `s.refused`: a HEADERS frame that is both over the concurrency limit and self-dependent must answer PROTOCOL_ERROR (malformed, will never succeed on retry), not REFUSED_STREAM (implies safe-to-retry-as-is) — the original check order let refusal mask the malformation (Codex P2, #27627 pullrequestreview-4620412384) |
| Server stream-state: DATA/HEADERS on closed/half-closed-remote → RST(STREAM_CLOSED) | 5.1/6.1 | ✅ | on_data closed-stream branch; on_headers over_end→finalize_trailers decodes HPACK then RSTs (Codex #27589 review_4588368602) |
| Server concurrency limit (HEADERS over MAX_CONCURRENT_STREAMS → REFUSED_STREAM) | 5.1.2 | ✅ | on_headers refused-flag + finalize_headers RST(REFUSED_STREAM); pump_for_window delegates to dispatch so an over-limit stream is refused even mid-stall (PR2, 88a5d3435a) |
| Server: unify frame readers — stall path (pump_for_window) routes through dispatch | 5.1/5.1.2 | ✅ | pump_for_window → dispatch_frame; half-closed-remote guard prevents run_request re-entrancy (88a5d3435a) |
| Server flow-control 0-increment / >2^31-1 bounds (conn→GOAWAY, stream→RST) | 6.9/6.9.1 | ✅ | handle_control_frame H2WindowUpdateFrame split (h2_server.v, PR3-final; 4 h2spec cases) |
| Server SETTINGS_ENABLE_PUSH ∈ {0,1} → conn PROTOCOL_ERROR | 6.5.2 | ✅ | apply_settings enable_push range check (h2_server.v, PR3-final) |
| Server priority self-dependency (HEADERS/PRIORITY/trailers) → RST(PROTOCOL_ERROR) | 5.3.1 (7540) | ✅ | self_dep flag decode-then-RST + H2PriorityFrame branch (h2_server.v, PR3-final; 2 h2spec cases) — h2spec baseline now EMPTY, 146/146 |

## Push & priority

| Requirement | § | Status | Evidence |
|---|---|---|---|
| PUSH_PROMISE when ENABLE_PUSH=0 → conn error | 8.4 | ✅ | dispatch_frame "unexpected PUSH_PROMISE" |
| PRIORITY frames tolerated/ignored (deprecated in 9113) | 5.3 | ✅ | parsed; no priority tree maintained (allowed) |

## Known design notes (not bugs)

- **G3 — connection layer trusts caller headers.** Request normalization
  (lowercase/strip/TE) lives in the adapter `to_h2_request`, not in
  `H2MuxConn.do`/`H2Conn.do`. The public `http.fetch` path always goes through the
  adapter, so it is conformant; a future *direct* `H2MuxConn` caller (Phase-3
  pooling) must pre-normalize. If direct callers proliferate, push the
  normalization down into `do_on_stream`.
- OpenSSL TLS-server backend is an error stub; only mbedtls server is real.

## How to use

1. On any change to the h2 files, re-walk the rows touching that area.
2. A new MUST discovered → add a row as ⚠️ GAP, then close it (fix + detector +
   test) and flip to ✅ with the commit.
3. The mechanical detectors in this directory are the enforcement arm for the
   rows that have one; rows without a detector are verified by reading.

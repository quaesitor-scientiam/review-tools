---
name: v-write
description: >
  Write-time sheet for V code. Load it before writing or editing any .v file: twenty V language
  facts, each with a program that was run, six structural defaults, and the per-function loop
  (contract, failing test, code, break it on purpose).
  Not a review step; /vreview still runs before a commit.
---

# V write-time sheet

Read this before writing or editing a `.v` file. It is short on purpose: a line earns its place
only if a logged miss or a correction traces back to it. Added 2026-11-22 and not yet tried on a
real task. For a change that adds behaviour, write a `/review-tools:design-brief` first.

Every fact in part 1 was run on 2026-11-22 on Windows (`S:\repo\vlang\v.exe`, `V 0.5.2 9621aa0`,
master of 2026-11-21) and in Ubuntu WSL (`V 0.5.2 0eab96b`). The two agree except where a row
says otherwise. The programs are in `vfacts/` beside this file, and `vfacts/README.md` has the
commands and the expected output. Rerun them after a compiler update and correct any line whose
output changed. Only fact 18 was also run on macOS.

## 1. Language facts, each with its run

| # | Fact | What the run printed | Write it this way |
|---|------|----------------------|-------------------|
| 1 | `defer` arms only when execution reaches it. One shared `defer` after two fallible calls leaks the first when the second fails. | shared: nothing freed. One `defer` per allocation: `freed own.a`. (`p01_defer.v`) | Put each `defer` on the line after the allocation it frees. |
| 2 | A missing map key reads as the zero value. For an enum value that is the **first member**. | `m['zzz']` on `map[string]Kind` gave `struct_`; on `map[string]int` gave `0`. (`p02_map.v`) | Test `k in m` first, or read with `m[k] or { ... }`. Never compare `m[k]` to an enum member unguarded. |
| 3 | `int` is 64 bits on this target. It does not wrap at 2^31. | `sizeof(int)=8`, `2147483647+1=2147483648`; the same sum in `i32` gave `-2147483648`. (`p03_int.v`) | Use `i32`/`u32` where a width is meant (wire fields, C structs). |
| 4 | A narrowing cast wraps without a diagnostic. | `u8(256)=0`, `u8(300)=44`. (`p03_int.v`) | Check the range before the cast and return an error. |
| 5 | A signed-to-unsigned cast keeps the bits, so a negative id equals a huge unsigned one. | `u32(-2) == u32(4294967294)` is `true`; as `i64` they differ. (`p03_int.v`) | Compare ids and sizes in one signedness chosen on purpose; widen before comparing. |
| 6 | `s.bytes()` holds exactly `s.len` bytes, with no 0 after them. A string that views other memory has no 0 after it either. | `len=3 cap=3` for `'abc'`; the byte after a 2-byte `tos` view of `xyz` was `122`. (`p04_bytes.v`) | For a C call that needs a terminator, copy the bytes and append a 0 (`mut c := b.clone()`, `c << u8(0)`). Never pass `len + 1`, and do not take `.str` of an arbitrary string as terminated. |
| 7 | A method that returns an array field returns the same buffer. | A write through `get()` changed the owner to `[99, 2, 3]`; through `.clone()` it did not. (`p05_share.v`) | A getter returns `.clone()` unless sharing is the documented contract. |
| 8 | A plain slice `a[..2]` printed the notice "an implicit clone of the slice was done", and the write through it **still changed the parent**. After `<<` the slice stopped sharing. | parent `[50, 2, 3, 4]`; after growth the parent kept `2` while the slice had `70`. (`p05_share.v`) | Never leave it implicit: write `a[..n].clone()` or `unsafe { a[..n] }`, and do not append to a shared slice. |
| 9 | Struct assignment copies the bytes. A pointer the struct holds into itself still points at the original. | `copy.p` had the address of the original's field. (`p06_struct_copy.v`) | A struct a C library keeps pointers into (TLS, sockets, callbacks) is stored and passed as `&T`. |
| 10 | A closure captures a value at creation. A captured `&T` sees later changes; a captured `int` does not. | captured `int` read `1` after `x = 2`; captured `&State` read `2`. (`p07_closure.v`) | Capture a pointer when the closure must see live state. For a spawned closure with state, prefer a named function. |
| 11 | `for p in ps` gives a copy of each element. | `[1, 2]` unchanged; `for mut p in ps` gave `[100, 100]`. (`p08_for.v`) | Use `for mut` (or index) to change elements. |
| 12 | Code under a `$if` that is false for this target is not checked. | A type error and an undefined function under `$if linux` compiled and ran on Windows; in WSL the same file was refused with both errors. (`p09_ifdef.v`) | Build and test on every platform the `$if` names (Windows, then WSL) before saying it compiles. |
| 13 | A typed constant does not convert like a literal. | `const billionth = i64(...)` passed to `math.fmod`: "cannot use `i64` as `f64`". (`p10_const.v`) | Cast at the call site. |
| 14 | `or {}` drops the error and the program goes on, exit 0. | "continued after a failed removal". (`p11_swallow.v`) | Every `or {}` on a write or removal says what stays behind and whether the summary and exit status report it. |
| 15 | A test that returns early under a `$if` is reported OK. | Without the flag: `OK`, 1 passed. With `-d some_flag`: the assert failed. (`t12/gated_test.v`) | A gated test counts only for the platforms and flags where its body runs. Name them. |
| 16 | `.free()` must have a pointer receiver. | `fn (r Res) free()` was refused by the compiler. (`p12_free_receiver.v`) | `fn (r &Res) free()` or `fn (mut r Res) free()`. |
| 17 | On Windows `os.getuid()` is 0 and `os.lstat` reports inode 0. | Windows: `getuid=0`, inode `0`. WSL: both non-zero. (`p13_windows_ids.v`) | Never tell users or files apart by uid or inode in code that also runs on Windows. |

| 18 | A `filelock.new_file` lock on Linux and macOS is lost when the process that holds it opens and closes the same file again. `filelock.new` is not affected, and on Windows neither kind is. | WSL and macOS: a second process was `refused` while the lock was held, then `acquired` after the holder opened and closed the file. `filelock.new` there, and both kinds on Windows: still `refused`. (`p14_filelock.v`) | While a `new_file` lock is held, never open the locked file again in that process. The run used `os.open` and `close`. |
| 19 | `==` on two `&Struct` values compares the fields, not the addresses. | Two separate allocations: with equal fields `a == b` is `true`, with one field different it is `false`; `voidptr(a) == voidptr(b)` is `false`. (`p15_pointer_eq.v`) | To ask "is this the same object", compare `voidptr(a) == voidptr(b)`. |
| 20 | A folder named like a module takes over `import <module>`, also for the runnable beside it. | With `cmd/mymod/` present, `v run cmd/cli` and `v run cmd/mymod` both stop with "bad module definition"; without it `cmd/cli` runs. (`t14_module_folder/`) | Never name a runnable's folder after the module it imports. Use `cmd/cli` or `examples/`. |

## 2. Recorded earlier, not reproduced

Two older notes that the runs of 2026-11-22 did not show. Do not rely on either.

- A memory note says `v test file_test.v` also compiles sibling test files. Two runs did **not**
  show that: two test files in one folder (`t13/`), and two in one module beside a module file.
  The note was about a `vlib` module.
- A memory note says `==` on two pointers to a struct with an interface field can fail in the
  generated C when the value behind the interface holds a C struct. `p15b_pointer_eq_c.v` builds
  and runs with tcc and gcc on Windows and with tcc, gcc and clang in WSL. The note was about
  several test files of `net.http` compiled together.

## 3. Structural defaults

These remove classes that make up most of the miss corpus. Departing from one is a question for
the user, not a silent choice.

1. **One function decides each question.** No second copy of a rule, a list or a parser. If two
   places must agree, one calls the other.
2. **No model of another tool.** Do not re-describe what an assembler, shell, C compiler or OS
   accepts. Call the tool, or ask.
3. **Lists come from the system.** Callers and siblings from graphify (`get_neighbors`) or
   `vprobe siblings`; spellings, flags and special names from the tool's own documentation.
   A list written from memory is marked as such and is not complete.
4. **A fallback states its triggers.** List every cause that reaches it and what it acts on.
5. **A failed look never takes the destructive branch.**
6. **A comment or doc sentence about behaviour is a claim.** Run it, or do not write it.

## 4. The loop for each function

1. Write its contract in one paragraph: inputs, every exit, what it must never do.
2. Write the test first and watch it fail for the stated reason.
3. Write the function. A `pub fn` gets its doc comment before its body.
4. Break it on purpose, once per branch (`vprobe mutate` with `changed_from`, or by hand), and
   read **which** test fails. A branch no test catches gets a test now.
5. Run `run_detectors.v` and `v fmt -w`, then start the next function.

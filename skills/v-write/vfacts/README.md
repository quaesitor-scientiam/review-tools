# The programs behind the V write-time sheet

One program per fact in part 1 of `../SKILL.md`. Run them from this folder after a compiler
update, compare with the output below, and correct the sheet where a line changed.

```powershell
$env:V_C_ERROR_BUG_REPORT_DISABLED = '1'
Get-ChildItem p*.v | ForEach-Object { "== $($_.Name)"; & S:\repo\vlang\v.exe run $_.FullName }
& S:\repo\vlang\v.exe test t12
& S:\repo\vlang\v.exe -d some_flag test t12
& S:\repo\vlang\v.exe test t13\a_test.v
foreach ($p in 'collides\mymod|cmd/cli', 'collides\mymod|cmd/mymod', 'control\mymod|cmd/cli') {
	$dir, $target = $p -split '\|'
	Push-Location "t14_module_folder\$dir"; & S:\repo\vlang\v.exe run $target; Pop-Location
}
```

On another machine use its own `v`. In WSL, copy this folder to a Linux folder first and run
`v run` on each file there.

Add `-showcc` to a run to see which compiler built it: a `C compiler cmd:` line means the
launcher fell back to the old compiler, and that run says nothing about the current one. (Seen
on 2026-11-22 with `-old-compiler -showcc`; none of the runs below printed it.)

## Output on 2026-11-22 (Windows `V 0.5.2 9621aa0` with tcc, and Ubuntu WSL `V 0.5.2 0eab96b`)

Both systems printed the same lines, except `p09_ifdef.v`, `p13_windows_ids.v` and
`p14_filelock.v` as marked.

```text
== p01_defer.v
shared_defer:
  returned false
own_defer:
  freed own.a
  returned false
== p02_map.v
missing key in map[string]Kind reads as: struct_
membership test says: false
missing key in map[string]int reads as: 0
same read with an or-block: -1
== p03_int.v
sizeof(int)=8 typeof(y)=int 2147483647+1=2147483648
same sum in i32: -2147483648
u8(256)=0 u8(300)=44
u32(-2) == u32(4294967294): true
i64(-2) == i64(u): false
== p04_bytes.v
s.len=3 s.bytes().len=3 cap=3
copy with a 0 appended: len=4 last=0
string view of 2 of 3 bytes: xy byte after it=122
== p05_share.v
(notice at line 25: an implicit clone of the slice was done here)
box after a write through get(): [99, 2, 3]
box after a write through get_copy(): [99, 2, 3]
parent after a write through its slice: [50, 2, 3, 4]
parent after the slice grew and was written again: [50, 2, 3, 4] slice=[50, 70, 60]
== p06_struct_copy.v
copy.fd=2 value behind copy.p=1 same address as original field: true
== p07_closure.v
captured int, read after x = 2: 1
captured &State, read after st.n = 2: 2
== p08_for.v
after for p in ps: [1, 2]
after for mut p in ps: [100, 100]
== p09_ifdef.v
windows branch ran
compiled and ran
   (WSL: does not compile. "cannot use `int literal` (right expression) as `string`" and
    "unknown function: undefined_name")
== p10_const.v
error: cannot use `i64` as `f64` in argument 2 to `math.fmod`   (does not compile, on purpose)
== p11_swallow.v
continued after a failed removal
== p12_free_receiver.v
error: `.free()` methods should be defined on either a `(mut x &Res)`, or a `(x &Res)` receiver
   (does not compile, on purpose)
== p13_windows_ids.v
getuid is 0: true lstat inode of this program is 0: true
   (WSL, as an ordinary user: false and false)
== p14_filelock.v   (Windows)
filelock.new_file: second process while held: refused; this process opened and closed the file again; second process then: refused
filelock.new: second process while held: refused; this process could not open the file again; second process then: refused
== p14_filelock.v   (WSL, and macOS)
filelock.new_file: second process while held: refused; this process opened and closed the file again; second process then: acquired
filelock.new: second process while held: refused; this process opened and closed the file again; second process then: refused
== p15_pointer_eq.v
two allocations with equal fields: a == b is true
two allocations with one field different: a == d is false
one allocation under two names: a == c is true
addresses of the two allocations: voidptr(a) == voidptr(b) is false
== p15b_pointer_eq_c.v
pointer == where the interface value holds a C struct: true
```

- `t12` without the flag: `OK`, 1 passed. With `-d some_flag`: `assert 1 == 2` fails.
- `t13\a_test.v`: `OK`, although `b_test.v` beside it does not compile (Windows only; not run
  in WSL).
- `t14_module_folder\collides\mymod`: `v run cmd/cli` and `v run cmd/mymod` both stop with
  `bad module definition: ... imports module "mymod" but cmd/mymod/main.v is defined as module`
  `` `main` ``. `t14_module_folder\control\mymod`, the same project without `cmd/mymod`:
  `v run cmd/cli` prints `cmd/cli: hello from the root module mymod`. Same on both systems.
- `p15b_pointer_eq_c.v` was also built with `-cc gcc` on Windows and with `-cc gcc` and
  `-cc clang` in WSL: same line.

On macOS only `p14_filelock.v` was run, on 2026-11-22 on a MacBook (its `v version` was not

enum Kind {
	struct_
	int_
}

fn main() {
	m := {
		'a': Kind.int_
	}
	println('missing key in map[string]Kind reads as: ${m['zzz']}')
	println('membership test says: ${'zzz' in m}')
	n := {
		'a': 5
	}
	println('missing key in map[string]int reads as: ${n['zzz']}')
	v := n['zzz'] or { -1 }
	println('same read with an or-block: ${v}')
}

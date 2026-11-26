module main

// a comment that says text == '0' is not code
fn f(text string, name string, words []string) bool {
	println("text == '0' is shown, not compared")
	if text.int() == 0 || name == 'x0' || name == 'v1' || name == '' {
		return true
	}
	n := text.len // a trailing comment: text == '0'
	if words[0] in ['a'] && g('0') {
		return n > 0
	}
	if name == '1x5' || name == '0a1' || name == '0x' {
		return false
	}
	m := n /
		2
	s := 'an unclosed string == '0
	u := name == "12
	return words.len > 0 && words[0] in ['a', 'b'] && name != '0x' && name == '$'
}

fn g(s string) bool {
	return s.len > 0
}

// inline_asm_raw_changes_nothing reports whether an instruction of the family `family` leaves its
// register destination as it was: `mov`, `or` or `and` of the register with itself, `lea` of its own
// value, or one of the families below with an operand that changes nothing. A 32-bit write on amd64
// clears the upper half of the register, so it changes it.
fn inline_asm_raw_changes_nothing(instruction InlineAsmRawInstruction, family string, arch_bits int) bool {
	if instruction.operands.len != 2 {
		return false
	}
	src := instruction.operands[0]
	dst := instruction.operands[1]
	width := inline_asm_att_register_width(dst.name, arch_bits)
	if width == 32 && arch_bits == 64 {
		return false
	}
	text := src.text.to_lower_ascii().replace_each(['%', '', ' ', '', '\t', ''])
	name := dst.name.to_lower_ascii()
	if family == 'lea' {
		if width != arch_bits {
			return false
		}
		index := if arch_bits == 64 { 'riz' } else { 'eiz' }
		address := text.all_after_first('(')
		return text.all_before('(') in ['', '0', '0x0']
			&& (address == '${name})' || address == '${name},${index},1)')
	}
	if src.kind == .register {
		return family in ['mov', 'or', 'and'] && src.name.to_lower_ascii() == name
	}
	if text in ['\$0', '\$0x0'] {
		return family in ['add', 'sub', 'or', 'xor', 'shl', 'shr', 'sar']
	}
	return text == '\$-1' && family == 'and'
}

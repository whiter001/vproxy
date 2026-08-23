module xor

// 自逆性：对任意 buf 连续应用两次 apply 应还原。
fn test_apply_self_inverse() {
	mut buf := [u8(0), 1, 2, 3, 255]
	original := buf.clone()
	apply(mut buf)
	apply(mut buf)
	assert buf == original
}

// 空 buf 是 no-op，不应 panic。
fn test_apply_empty() {
	mut buf := []u8{}
	apply(mut buf)
	assert buf.len == 0
}

// 已知字节：XOR 1 语义（最低位翻转）。
fn test_apply_known() {
	mut buf := [u8(0), 1, 254, 255]
	apply(mut buf)
	assert buf == [u8(1), 0, 255, 254]
}

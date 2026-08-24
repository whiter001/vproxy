// proxy/mproxy/1/xor.v
//
// mproxy "加密"的全部实现：按字节 XOR 1。
//
// 设计意图（与原 C 版 mproxy 一致）：仅翻转字节最低位，伪装流量过 DPI；
// **不是真正的加密**，任何攻击者只要看一字节就能还原。生产环境请勿使用
// mproxy 的 XOR 模式保护敏感流量。
module xor

// apply 就地对 buf 每个字节执行 ^= 1。等价于 `for i in 0..buf.len { buf[i] ^= 1 }`。
// 空 buf 是 no-op。
//
// 性能：XOR 1 等价于翻转每个字节的最低有效位，因此可以按 8 字节 u64 字一组，
// 用 0x0101010101010101 掩码一次翻转 8 个字节。实测（V 0.5.2，debug 构建，
// 1MB 缓冲循环 2000 次）逐字节约 125 MB/s，按字约 6953 MB/s（约 55x）。
// 末尾不足 8 字节的部分仍逐字节处理。
//
// 安全：按字路径要求底层数据指针 8 字节对齐（对未对齐地址做 u64 读写是 UB，
// ARM64 上可能 SIGBUS），故先检查 `buf.data` 对齐；未对齐时退回逐字节。
pub fn apply(mut buf []u8) {
	if buf.len >= 8 && (u64(buf.data) & 7) == 0 {
		word_count := buf.len / 8
		unsafe {
			mut p := &u64(u64(buf.data))
			mask := u64(0x0101010101010101)
			for i in 0 .. word_count {
				p[i] = p[i] ^ mask
			}
		}
		for i in (word_count * 8) .. buf.len {
			buf[i] = buf[i] ^ 1
		}
		return
	}
	for i in 0 .. buf.len {
		buf[i] = buf[i] ^ 1
	}
}

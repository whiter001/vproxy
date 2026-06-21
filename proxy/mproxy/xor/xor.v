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
pub fn apply(mut buf []u8) {
	for i in 0 .. buf.len {
		buf[i] = buf[i] ^ 1
	}
}

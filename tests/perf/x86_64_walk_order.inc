/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Macros the x86-64 walk probes share (x86_64_memory_walk_probe.inc,
 * x86_64_link_walk_probe.inc and x86_64_return_walk_probe.inc), the
 * counterpart of walk_order.inc. Include it after x86_64_probe_harness.inc.
 *
 * walk_order_fill fills `count` words at r14 with block indices below
 * `blocks`, both powers of two: a xorshift sequence when `random` is 1, the
 * indices in order otherwise. It runs once, before the timed loop, and uses
 * rax, rcx and rdx.
 *
 * walk_family emits one register-only instruction of eight families, chosen
 * by `index` modulo eight, each a gadget entry of its own. It reads r11 and
 * writes r10.
 */

.macro walk_order_fill count, blocks, random
	movabs	rax, 0x7f4a7c159e3779b9
	xor	ecx, ecx
.Lwalk_fill\@:
.if \random
	mov	rdx, rax
	shl	rdx, 13
	xor	rax, rdx
	mov	rdx, rax
	shr	rdx, 7
	xor	rax, rdx
	mov	rdx, rax
	shl	rdx, 17
	xor	rax, rdx
	mov	rdx, rax
	shr	rdx, 32
.else
	mov	edx, ecx
.endif
	and	edx, \blocks - 1
	mov	word ptr [r14 + rcx * 2], dx
	add	ecx, 1
	cmp	ecx, \count
	jb	.Lwalk_fill\@
.endm

.macro walk_family index
.if ((\index) & 7) == 0
	add	r10, r11
.elseif ((\index) & 7) == 1
	sub	r10, r11
.elseif ((\index) & 7) == 2
	xor	r10, r11
.elseif ((\index) & 7) == 3
	or	r10, r11
.elseif ((\index) & 7) == 4
	and	r10, r11
.elseif ((\index) & 7) == 5
	mov	r10, r11
.elseif ((\index) & 7) == 6
	lea	r10, [r10 + r11 * 2]
.else
	neg	r10
.endif
.endm

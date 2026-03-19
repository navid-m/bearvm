.text
.global _check
_check:
    ; prologue - frame size 16 (just fp+lr, no regs)
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    ; movz/movk to load a 64-bit pointer into x0
    movz x0, #0x1234
    movk x0, #0x5678, lsl #16
    movk x0, #0x9abc, lsl #32
    movk x0, #0xdef0, lsl #48

    ; load a fn pointer into x8 and call it
    movz x8, #0x1234
    blr x8

    ; return 0
    movz x0, #0
    ldp x29, x30, [sp], #16
    ret

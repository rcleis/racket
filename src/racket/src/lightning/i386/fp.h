/******************************** -*- C -*- ****************************
 *
 *	Run-time assembler & support macros for the i386 math coprocessor
 *
 ***********************************************************************/


/***********************************************************************
 *
 * Copyright 2000, 2001, 2002, 2004 Free Software Foundation, Inc.
 * Written by Paolo Bonzini.
 *
 * This file is part of GNU lightning.
 *
 * GNU lightning is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; either version 2.1, or (at your option)
 * any later version.
 * 
 * GNU lightning is distributed in the hope that it will be useful, but 
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 * 
 * You should have received a copy of the GNU Lesser General Public License
 * along with GNU lightning; see the file COPYING.LESSER; if not, write to the
 * Free Software Foundation, 59 Temple Place - Suite 330, Boston,
 * MA 02111-1307, USA.
 *
 ***********************************************************************/


#ifndef __lightning_asm_fp_h
#define __lightning_asm_fp_h

#ifdef JIT_X86_SSE

# include "fp-sse.h"

#else

/* We really must map the x87 stack onto a flat register file.  In practice,
   we can provide something sensible and make it work on the x86 using the
   stack like a file of eight registers.

   We use six or seven registers so as to have some freedom
   for floor, ceil, round, (and log, tan, atn and exp).

   Not hard at all, basically play with FXCH.  FXCH is mostly free,
   so the generated code is not bad.  Of course we special case when one
   of the operands turns out to be ST0.

   Here are the macros that actually do the trick.  */

#define JIT_FPR_NUM	       6
#define JIT_FPR(i)	       (i)

#define jit_fxch(rs, op)       (((rs) != 0 ? FXCHr(rs) : (void)0),      \
                                op, ((rs) != 0 ? FXCHr(rs) : (void)0))

#define jit_fp_unary(rd, s1, op)                       \
       ((rd) == (s1) ? jit_fxch ((rd), op)             \
        : (rd) == 0 ? (FSTPr (0), FLDr ((s1)-1), op)   \
        : (FLDr ((s1)), op, FSTPr ((rd))))

#define jit_fp_binary(rd, s1, s2, op, opr)             \
       ((rd) == (s1) ?                                 \
          ((s2) == 0 ? opr(0, (rd))                    \
           : (s2) == (s1) ? jit_fxch((rd), op(0, 0))   \
           : jit_fxch((rd), op((s2), 0)))              \
        : (rd) == (s2) ? ((s1) == 0 ? op((s1), (s2)) : jit_fxch((s2), opr((s1), 0))) \
        : (FLDr (s1), op(0, (s2)+1), FSTPr((rd)+1)))

#define jit_addr_d(rd,s1,s2)    jit_fp_binary((rd),(s1),(s2),FADDrr,FADDrr)
#define jit_subr_d(rd,s1,s2)    jit_fp_binary((rd),(s1),(s2),FSUBrr,FSUBRrr)
#define jit_subrr_d(rd,s1,s2)   jit_fp_binary((rd),(s1),(s2),FSUBRrr,FSUBrr)
#define jit_mulr_d(rd,s1,s2)    jit_fp_binary((rd),(s1),(s2),FMULrr,FMULrr)
#define jit_divr_d(rd,s1,s2)    jit_fp_binary((rd),(s1),(s2),FDIVrr,FDIVRrr)
#define jit_divrr_d(rd,s1,s2)   jit_fp_binary((rd),(s1),(s2),FDIVRrr,FDIVrr)

#define jit_abs_d(rd,rs)       jit_fp_unary ((rd), (rs), _OO (0xd9e1))
#define jit_negr_d(rd,rs)      jit_fp_unary ((rd), (rs), _OO (0xd9e0))
#define jit_sqrt_d(rd,rs)      jit_fp_unary ((rd), (rs), _OO (0xd9fa))

#define jit_addr_d_fppop(rd,s1,s2)  (FADDPr(1))
#define jit_subr_d_fppop(rd,s1,s2)  (FSUBPr(1))
#define jit_subrr_d_fppop(rd,s1,s2) (FSUBRPr(1))
#define jit_mulr_d_fppop(rd,s1,s2)  (FMULPr(1))
#define jit_divr_d_fppop(rd,s1,s2)  (FDIVPr(1))
#define jit_divrr_d_fppop(rd,s1,s2) (FDIVRPr(1))
#define jit_negr_d_fppop(rd,rs)     ( _OO (0xd9e0))
#define jit_abs_d_fppop(rd,rs)      ( _OO (0xd9e1))
#define jit_sqrt_d_fppop(rd,rs)     ( _OO (0xd9fa))

/* - moves:

	move FPR0 to FPR3
		FST  ST3

	move FPR3 to FPR0
		FXCH ST3
		FST  ST3

	move FPR3 to FPR1
                FLD  ST1
                FST  ST4   Stack is rotated, so FPRn becomes STn+1 */

#define jit_movr_d(rd,s1)                              \
       ((s1) == (rd) ? 0                               \
        : (rd) == 0 ? (FSTPr(0), FSTr (((s1)-1)))      \
        : (FLDr ((s1)), FSTPr ((rd)+1)))

#define jit_movr_d_rel(rd,s1) ((rd < s1) ? (FSTPr(0), FLDr(0)) : (FSTr(1)))
#define jit_movr_d_fppush(rd,s1) (FLDr(s1))

/* - loads:

	load into FPR0
		FSTP ST0
		FLD  [FUBAR]

	load into FPR3
		FSTP ST3     Save old st0 into destination register
		FLD  [FUBAR]
		FXCH ST3     Get back old st0

   (and similarly for immediates, using the stack) */

#define jit_movi_f(rd,immf)                     \
        (_O (0x68),                            \
         *((float *) _jit.x.pc) = (float) immf, \
         _jit.x.uc_pc += sizeof (float),       \
        jit_ldr_f((rd), _ESP),                 \
        ADDQir(4, _ESP))

union jit_double_imm {
  double d;
  int i[2];
};

#ifdef JIT_X86_64
# define jit_double_as_long(v) (*(double *)(_jit.x.uc_pc) = v, *(intptr_t *)(_jit.x.uc_pc))
# define _jit_push_d(immd) \
  (MOVQir(jit_double_as_long(immd), JIT_REXTMP),		\
   PUSHQr(JIT_REXTMP))
# define FPX() (void)0 /* don't need _REX(0,0,0), apparently */
#else
# define _jit_push_d(immd)                                                              \
        (_O (0x68),                                                                    \
         _jit.x.uc_pc[4] = 0x68,                                                       \
         ((union jit_double_imm *) (_jit.x.uc_pc + 5))->d = (double) immd,             \
         *((int *) _jit.x.uc_pc) = ((union jit_double_imm *) (_jit.x.uc_pc + 5))->i[1],        \
         _jit.x.uc_pc += 9)
# define FPX() ((void) 0)
#endif

#define jit_movi_d(rd,immd)                                                            \
        (_jit_push_d(immd),                                                            \
        jit_ldr_d((rd), _ESP),                                                         \
        ADDQir(8, _ESP))

#define jit_movi_d_fppush(rd,immd)                                                            \
        (_jit_push_d(immd),                                                            \
        jit_ldr_d_fppush((rd), _ESP),                                                         \
        ADDQir(8, _ESP))

#ifdef JIT_X86_64
#define jit_ldi_d_fppush(rd, is)   \
  (MOVQrr(JIT_R0, JIT_REXTMP), \
   MOVQir(((intptr_t)is), JIT_R0),  \
   jit_ldr_d_fppush(rd, JIT_R0), \
   MOVQrr(JIT_REXTMP, JIT_R0))
#else
#define jit_ldi_f(rd, is)                              \
  ((rd) == 0 ? (FSTPr (0), FLDSm((is), 0, 0, 0))       \
   : (FLDSm((is), 0, 0, 0), FSTPr ((rd) + 1)))

#define jit_ldi_d(rd, is)                              \
  ((rd) == 0 ? (FSTPr (0), FPX(), FLDLm((is), 0, 0, 0)) \
   : (FPX(), FLDLm((is), 0, 0, 0), FSTPr ((rd) + 1)))

#define jit_ldi_d_fppush(rd, is) (FPX(), FLDLm((is), 0, 0, 0))
#endif

#define jit_ldr_f(rd, rs)                              \
  ((rd) == 0 ? (FSTPr (0), FPX(), FLDSm(0, (rs), 0, 0)) \
   : (FPX(), FLDSm(0, (rs), 0, 0), FSTPr ((rd) + 1)))

#define jit_ldr_d(rd, rs)                              \
  ((rd) == 0 ? (FSTPr (0), FPX(), FLDLm(0, (rs), 0, 0)) \
   : (FPX(), FLDLm(0, (rs), 0, 0), FSTPr ((rd) + 1)))

#define jit_ldr_d_fppush(rd, rs) (FPX(), FLDLm(0, (rs), 0, 0))

#define jit_ldxi_f(rd, rs, is)                         \
  ((rd) == 0 ? (FSTPr (0), FPX(), FLDSm((is), (rs), 0, 0))	\
   : (FPX(), FLDSm((is), (rs), 0, 0), FSTPr ((rd) + 1)))

#define jit_ldxi_d(rd, rs, is)                         \
  ((rd) == 0 ? (FSTPr (0), FPX(), FLDLm((is), (rs), 0, 0))	\
   : (FPX(), FLDLm((is), (rs), 0, 0), FSTPr ((rd) + 1)))

#define jit_ldxi_d_fppush(rd, rs, is) (FPX(), FLDLm((is), (rs), 0, 0))

#define jit_ldxr_f(rd, s1, s2)                         \
  ((rd) == 0 ? (FSTPr (0), FPX(), FLDSm(0, (s1), (s2), 1))	\
   : (FPX(), FLDSm(0, (s1), (s2), 1), FSTPr ((rd) + 1)))

#define jit_ldxr_d(rd, s1, s2)                         \
  ((rd) == 0 ? (FSTPr (0), FPX(), FLDLm(0, (s1), (s2), 1))	\
   : (FPX(), FLDLm(0, (s1), (s2), 1), FSTPr ((rd) + 1)))

#define jit_ldxr_d_fppush(rd, s1, s2) (FPX(), FLDLm(0, (s1), (s2), 1))

#define jit_extr_i_d(rd, rs)   (PUSHLr((rs)),          \
  ((rd) == 0 ? (FSTPr (0), FILDLm(0, _ESP, 0, 0))      \
   : (FILDLm(0, _ESP, 0, 0), FSTPr ((rd) + 1))),       \
  POPLr((rs)))

#define jit_extr_i_d_fppush(rd, rs)  \
  (PUSHLr((rs)), FILDLm(0, _ESP, 0, 0), POPLr((rs)))
#ifdef JIT_X86_64
# define jit_extr_l_d_fppush(rd, rs)  \
  (PUSHQr((rs)), FILDQm(0, _ESP, 0, 0), POPQr((rs)))
#else
# define jit_extr_l_d_fppush(rd, rs) jit_extr_i_d_fppush(rd, rs)
#endif


#define jit_stxi_f(id, rd, rs) jit_fxch ((rs), FPX(), FSTSm((id), (rd), 0, 0))
#define jit_stxr_f(d1, d2, rs) jit_fxch ((rs), FPX(), FSTSm(0, (d1), (d2), 1))
#define jit_stxi_d(id, rd, rs) jit_fxch ((rs), FPX(), FSTLm((id), (rd), 0, 0))
#define jit_stxr_d(d1, d2, rs) jit_fxch ((rs), FPX(), FSTLm(0, (d1), (d2), 1))

#ifdef JIT_X86_64
#define jit_sti_d_fppop(is, rd)   \
  (MOVQrr(JIT_R0, JIT_REXTMP), \
   MOVQir(((intptr_t)is), JIT_R0),  \
   jit_str_d_fppop(JIT_R0, rd), \
   MOVQrr(JIT_REXTMP, JIT_R0))
#else
#define jit_sti_f(id, rs)      jit_fxch ((rs), FPX(), FSTSm((id), 0,    0, 0))
#define jit_str_f(rd, rs)      jit_fxch ((rs), FPX(), FSTSm(0,    (rd), 0, 0))
#define jit_sti_d(id, rs)      jit_fxch ((rs), FPX(), FSTLm((id), 0,    0, 0))
#define jit_str_d(rd, rs)      jit_fxch ((rs), FPX(), FSTLm(0,    (rd), 0, 0))

#define jit_sti_d_fppop(id, rs)      (FPX(), FSTPLm((id), 0,    0, 0))
#endif

#define jit_stxi_d_fppop(id, rd, rs) (FPX(), FSTPLm((id), (rd), 0, 0))
#define jit_str_d_fppop(rd, rs)      (FPX(), FSTPLm(0,    (rd), 0, 0))
#define jit_stxr_d_fppop(d1, d2, rs) (FPX(), FSTPLm(0,    (d1), (d2), 1))

/* Assume round to near mode */
#define jit_floorr_d_i(rd, rs) \
       (FLDr (rs), jit_floor2((rd), ((rd) == _EDX ? _EAX : _EDX)))

#define jit_ceilr_d_i(rd, rs)  \
       (FLDr (rs), jit_ceil2((rd), ((rd) == _EDX ? _EAX : _EDX)))

#define jit_truncr_d_i(rd, rs) \
       (FLDr (rs), jit_trunc2((rd), ((rd) == _EDX ? _EAX : _EDX)))

#define jit_calc_diff(ofs)		\
	FISTLm(ofs, _ESP, 0, 0),	\
	FILDLm(ofs, _ESP, 0, 0),	\
	FSUBRPr(1),			\
	FSTPSm(4+ofs, _ESP, 0, 0)	\

/* The real meat */
#define jit_floor2(rd, aux)		\
	(PUSHLr(aux),			\
	SUBLir(8, _ESP),		\
	jit_calc_diff(0),		\
	POPLr(rd),			/* floor in rd */ \
	POPLr(aux),			/* x-round(x) in aux */ \
	ADDLir(0x7FFFFFFF, aux),	/* carry if x-round(x) < -0 */ \
	SBBLir(0, rd),			/* subtract 1 if carry */ \
	POPLr(aux))

#define jit_ceil2(rd, aux)		\
	(PUSHLr(aux),			\
	SUBLir(8, _ESP),		\
	jit_calc_diff(0),		\
	POPLr(rd),			/* floor in rd */ \
	POPLr(aux),			/* x-round(x) in aux */ \
	TESTLrr(aux, aux),		\
	SETGr(jit_reg8(aux)),		\
	SHRLir(1, aux),			\
	ADCLir(0, rd),			\
	POPLr(aux))

/* a mingling of the two above */
#define jit_trunc2(rd, aux)			\
	(PUSHLr(aux),				\
	SUBLir(12, _ESP),			\
	FSTSm(0, _ESP, 0, 0),			\
	jit_calc_diff(4),			\
	POPLr(aux),				\
	POPLr(rd),				\
	TESTLrr(aux, aux),			\
	POPLr(aux),				\
	JSSm(_jit.x.pc + 11, 0, 0, 0),		\
	ADDLir(0x7FFFFFFF, aux),	/* 6 */	\
	SBBLir(0, rd),			/* 3 */ \
	JMPSm(_jit.x.pc + 10, 0, 0, 0),	/* 2 */ \
	TESTLrr(aux, aux),		/* 2 */ \
	SETGr(jit_reg8(aux)),		/* 3 */ \
	SHRLir(1, aux),			/* 2 */ \
	ADCLir(0, rd),			/* 3 */ \
	POPLr(aux))

/* the easy one */
#define jit_roundr_d_i(rd, rs)                         \
        (PUSHLr(_EAX),                                 \
        jit_fxch ((rs), FISTPLm(0, _ESP, 0, 0)),       \
	POPLr((rd)))
#define jit_roundr_d_l(rd, rs)                         \
        (PUSHQr(_EAX),                                 \
        jit_fxch ((rs), FISTPQm(0, _ESP, 0, 0)),       \
	POPQr((rd)))

#define jit_roundr_d_l_fppop(rd, rs)                   \
        (PUSHQr(_EAX),                                 \
         FISTPQm(0, _ESP, 0, 0),                       \
	 POPQr((rd)))

#define jit_fp_test(d, s1, s2, n, _and, res)           \
       (((s1) == 0 ? FUCOMr((s2)) : (FLDr((s1)), FUCOMPr((s2) + 1))),     \
        ((d) != _EAX ? MOVLrr(_EAX, (d)) : 0),                 \
        FNSTSWr(_EAX),                                         \
        SHRLir(n, _EAX),                                       \
        ((_and) ? ANDLir((_and), _EAX) : MOVLir(0, _EAX)),     \
        res,                                                   \
        ((d) != _EAX ? _O (0x90 + ((d) & 7)) : 0))     /* xchg */

#define jit_fp_btest(d, s1, s2, n, _and, cmp, res)             \
       (((s1) == 0 ? FCOMr((s2)) : (FLDr((s1)), FUCOMPr((s2) + 1))),    \
        (_jitl.r0_can_be_tmp ? 0 : PUSHQr(_EAX)),              \
        FNSTSWr(_EAX),                                         \
        SHRLir(n, _EAX),                                       \
        (void)((_and) ? ANDLir ((_and), _EAX) : 0),            \
        ((cmp) ? CMPLir ((cmp), _AL) : 0),                     \
        (void) (_jitl.r0_can_be_tmp ? 0 : POPQr(_EAX)),        \
        res ((d), 0, 0, 0), _jit.x.pc)

#define jit_fp_test_fppop(d, n, _and, res)                       \
       (FUCOMPPr(1),                                           \
        ((d) != _EAX ? MOVLrr(_EAX, (d)) : 0),                 \
        FNSTSWr(_EAX),                                         \
        SHRLir(n, _EAX),                                       \
        ((_and) ? ANDLir((_and), _EAX) : MOVLir(0, _EAX)),     \
        res,                                                   \
        ((d) != _EAX ? _O (0x90 + ((d) & 7)) : 0))     /* xchg */

#define jit_fp_btest_fppop(d, n, _and, cmp, res)               \
       (FUCOMPPr(1),                                           \
        (_jitl.r0_can_be_tmp ? 0 : PUSHQr(_EAX)),              \
        FNSTSWr(_EAX),                                         \
        SHRLir(n, _EAX),                                       \
        (void)((_and) ? ANDLir ((_and), _EAX) : 0),            \
        (void)((cmp) ? CMPLir ((cmp), _AL) : 0),               \
        (void) (_jitl.r0_can_be_tmp ? 0 : POPQr(_EAX)),        \
        res ((d), 0, 0, 0), _jit.x.pc)

#define jit_fp_btest_fppop(d, n, _and, cmp, res)               \
       (FUCOMPPr(1),                                           \
        (_jitl.r0_can_be_tmp ? 0 : PUSHQr(_EAX)),              \
        FNSTSWr(_EAX),                                         \
        SHRLir(n, _EAX),                                       \
        (void)((_and) ? ANDLir ((_and), _EAX) : 0),            \
        (void)((cmp) ? CMPLir ((cmp), _AL) : 0),               \
        (void) (_jitl.r0_can_be_tmp ? 0 : POPQr(_EAX)),        \
        res ((d), 0, 0, 0), _jit.x.pc)

#define jit_fp_btest_fppop_2(d, res)               \
       (FUCOMIPr(1), FSTPr(0), res ((d), 0, 0, 0), _jit.x.pc)

#define jit_nothing_needed(x)

/* After FNSTSW we have 1 if <, 40 if =, 0 if >, 45 if unordered.  Here
   is how to map the values of the status word's high byte to the
   conditions.

         <     =     >     unord    valid values    condition
  gt     no    no    yes   no       0               STSW & 45 == 0
  lt     yes   no    no    no       1               STSW & 45 == 1
  eq     no    yes   no    no       40              STSW & 45 == 40
  unord  no    no    no    yes      45              bit 2 == 1

  ge     no    yes   no    no       0, 40           bit 0 == 0
  unlt   yes   no    no    yes      1, 45           bit 0 == 1
  ltgt   yes   no    yes   no       0, 1            bit 6 == 0
  uneq   no    yes   no    yes      40, 45          bit 6 == 1
  le     yes   yes   no    no       1, 40           odd parity for STSW & 41
  ungt   no    no    yes   yes      0, 45           even parity for STSW & 41

  unle   yes   yes   no    yes      1, 40, 45       STSW & 45 != 0
  unge   no    yes   yes   yes      0, 40, 45       STSW & 45 != 1
  ne     yes   no    yes   yes      0, 1, 45        STSW & 45 != 40
  ord    yes   yes   yes   no       0, 1, 40        bit 2 == 0

  lt, le, ungt, unge are actually computed as gt, ge, unlt, unle with
  the operands swapped; it is more efficient this way.  */

#define jit_gtr_d(d, s1, s2)            jit_fp_test((d), (s1), (s2), 8, 0x45, SETZr (_AL))
#define jit_ger_d(d, s1, s2)            jit_fp_test((d), (s1), (s2), 9, 0, SBBBir (-1, _AL))
#define jit_unler_d(d, s1, s2)          jit_fp_test((d), (s1), (s2), 8, 0x45, SETNZr (_AL))
#define jit_unltr_d(d, s1, s2)          jit_fp_test((d), (s1), (s2), 9, 0, ADCBir (0, _AL))
#define jit_ltr_d(d, s1, s2)            jit_fp_test((d), (s2), (s1), 8, 0x45, SETZr (_AL))
#define jit_ler_d(d, s1, s2)            jit_fp_test((d), (s2), (s1), 9, 0, SBBBir (-1, _AL))
#define jit_unger_d(d, s1, s2)          jit_fp_test((d), (s2), (s1), 8, 0x45, SETNZr (_AL))
#define jit_ungtr_d(d, s1, s2)          jit_fp_test((d), (s2), (s1), 9, 0, ADCBir (0, _AL))
#define jit_eqr_d(d, s1, s2)            jit_fp_test((d), (s1), (s2), 8, 0x45, (CMPBir (0x40, _AL), SETEr (_AL)))
#define jit_ner_d(d, s1, s2)            jit_fp_test((d), (s1), (s2), 8, 0x45, (CMPBir (0x40, _AL), SETNEr (_AL)))
#define jit_ltgtr_d(d, s1, s2)          jit_fp_test((d), (s1), (s2), 15, 0, SBBBir (-1, _AL))
#define jit_uneqr_d(d, s1, s2)          jit_fp_test((d), (s1), (s2), 15, 0, ADCBir (0, _AL))
#define jit_ordr_d(d, s1, s2)           jit_fp_test((d), (s1), (s2), 11, 0, SBBBir (-1, _AL))
#define jit_unordr_d(d, s1, s2)         jit_fp_test((d), (s1), (s2), 11, 0, ADCBir (0, _AL))
#define jit_bgtr_d(d, s1, s2)           jit_fp_btest((d), (s1), (s2), 8, 0x45, 0, JZm)
#define jit_bger_d(d, s1, s2)           jit_fp_btest((d), (s1), (s2), 9, 0, 0, JNCm)
#define jit_bantigtr_d(d, s1, s2)       jit_fp_btest((d), (s1), (s2), 8, 0x45, 0, JNZm)
#define jit_bantiger_d(d, s1, s2)       jit_fp_btest((d), (s1), (s2), 9, 0, 0, JCm)
#define jit_bunler_d(d, s1, s2)         jit_fp_btest((d), (s1), (s2), 8, 0x45, 0, JNZm)
#define jit_bunltr_d(d, s1, s2)         jit_fp_btest((d), (s1), (s2), 9, 0, 0, JCm)
#define jit_bltr_d(d, s1, s2)           jit_fp_btest((d), (s2), (s1), 8, 0x45, 0, JZm)
#define jit_bler_d(d, s1, s2)           jit_fp_btest((d), (s2), (s1), 9, 0, 0, JNCm)
#define jit_bantiltr_d(d, s1, s2)       jit_fp_btest((d), (s2), (s1), 8, 0x45, 0, JNZm)
#define jit_bantiler_d(d, s1, s2)       jit_fp_btest((d), (s2), (s1), 9, 0, 0, JCm)
#define jit_bunger_d(d, s1, s2)         jit_fp_btest((d), (s2), (s1), 8, 0x45, 0, JNZm)
#define jit_bungtr_d(d, s1, s2)         jit_fp_btest((d), (s2), (s1), 9, 0, 0, JCm)
#define jit_beqr_d(d, s1, s2)           jit_fp_btest((d), (s1), (s2), 8, 0x45, 0x40, JZm)
#define jit_bantieqr_d(d, s1, s2)       jit_fp_btest((d), (s1), (s2), 8, 0x45, 0x40, JNZm)
#define jit_bner_d(d, s1, s2)           jit_fp_btest((d), (s1), (s2), 8, 0x45, 0x40, JNZm)
#define jit_bltgtr_d(d, s1, s2)         jit_fp_btest((d), (s1), (s2), 15, 0, 0, JNCm)
#define jit_buneqr_d(d, s1, s2)         jit_fp_btest((d), (s1), (s2), 15, 0, 0, JCm)
#define jit_bordr_d(d, s1, s2)          jit_fp_btest((d), (s1), (s2), 11, 0, 0, JNCm)
#define jit_bunordr_d(d, s1, s2)        jit_fp_btest((d), (s1), (s2), 11, 0, 0, JCm)

#define jit_bger_d_fppop(d, s1, s2)       jit_fp_btest_fppop((d), 9, 0, 0, JNCm)
/* #define jit_bantiger_d_fppop(d, s1, s2)   jit_fp_btest_fppop((d), 9, 0, 0, JCm) */
#define jit_bantiger_d_fppop(d, s1, s2)   jit_fp_btest_fppop_2((d), JBm)
#define jit_bler_d_fppop(d, s1, s2)       (FXCHr(1), jit_bger_d_fppop(d, s1, s2))
#define jit_bantiler_d_fppop(d, s1, s2)   (FXCHr(1), jit_bantiger_d_fppop(d, s1, s2))

#define jit_bgtr_d_fppop(d, s1, s2)       jit_fp_btest_fppop((d), 8, 0x45, 0, JZm)
/* #define jit_bantigtr_d_fppop(d, s1, s2)   jit_fp_btest_fppop((d), 8, 0x45, 0, JNZm) */
#define jit_bantigtr_d_fppop(d, s1, s2)   jit_fp_btest_fppop_2((d), JBEm)
#define jit_bltr_d_fppop(d, s1, s2)       (FXCHr(1), jit_bgtr_d_fppop(d, s1, s2))
#define jit_bantiltr_d_fppop(d, s1, s2)   (FXCHr(1), jit_bantigtr_d_fppop(d, s1, s2))

#define jit_beqr_d_fppop(d, s1, s2)       jit_fp_btest_fppop((d), 8, 0x45, 0x40, JZm)
#define jit_bantieqr_d_fppop(d, s1, s2)   jit_fp_btest_fppop((d), 8, 0x45, 0x40, JNZm)
/* Doesn't work right with +nan.0: */
/* #define jit_bantieqr_d_fppop(d, s1, s2)   jit_fp_btest_fppop_2((d), JNZm) */

#define jit_getarg_f(rd, ofs)        jit_ldxi_f((rd), JIT_FP,(ofs))
#define jit_getarg_d(rd, ofs)        jit_ldxi_d((rd), JIT_FP,(ofs))
#define jit_pusharg_d(rs)            (jit_subi_i(JIT_SP,JIT_SP,sizeof(double)), jit_str_d(JIT_SP,(rs)))
#define jit_pusharg_f(rs)            (jit_subi_i(JIT_SP,JIT_SP,sizeof(float)), jit_str_f(JIT_SP,(rs)))
#define jit_retval_d(op1)            jit_movr_d(0, (op1))


#if 0
#define jit_sin()	_OO(0xd9fe)			/* fsin */
#define jit_cos()	_OO(0xd9ff)			/* fcos */
#define jit_tan()	(_OO(0xd9f2), 			/* fptan */ \
			 FSTPr(0))			/* fstp st */
#define jit_atn()	(_OO(0xd9e8), 			/* fld1 */ \
			 _OO(0xd9f3))			/* fpatan */
#define jit_exp()	(_OO(0xd9ea), 			/* fldl2e */ \
			 FMULPr(1), 			/* fmulp */ \
			 _OO(0xd9c0),			/* fld st */ \
			 _OO(0xd9fc),		 	/* frndint */ \
			 _OO(0xdce9), 			/* fsubr */ \
			 FXCHr(1), 			/* fxch st(1) */ \
			 _OO(0xd9f0), 			/* f2xm1 */ \
			 _OO(0xd9e8), 			/* fld1 */ \
			 _OO(0xdec1), 			/* faddp */ \
			 _OO(0xd9fd), 			/* fscale */ \
			 FSTPr(1))			/* fstp st(1) */
#define jit_log()	(_OO(0xd9ed), 			/* fldln2 */ \
			 FXCHr(1), 			/* fxch st(1) */ \
			 _OO(0xd9f1))			/* fyl2x */
#endif

#endif

#endif /* __lightning_asm_h */

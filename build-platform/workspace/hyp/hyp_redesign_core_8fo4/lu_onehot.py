#!/usr/bin/env python3
# hyp8: load_unit FSM -> one-hot state. Keep verbatim load_control as ref.
import re

PATH = 'core/load_unit.sv'
src = open(PATH, encoding='utf-8').read().split('\n')

STATES = ['IDLE','WAIT_GNT','SEND_TAG','WAIT_PAGE_OFFSET','ABORT_TRANSACTION',
          'ABORT_TRANSACTION_NI','WAIT_TRANSLATION','WAIT_FLUSH','WAIT_WB_EMPTY','WAIT_SPEC_LOAD']

# 1. replace the enum decl with one-hot localparams + vector state
E0 = next(i for i,l in enumerate(src) if 'enum logic [3:0]' in l)
E1 = next(i for i,l in enumerate(src) if re.match(r'^\s*state_d, state_q;', l))
assert E0 < E1
gen_enum = [
"  // hyp8: one-hot FSM state (L1 request issue cycle unchanged). Each state is a",
"  // single bit of state_q; transitions write a one-hot literal LU_S_* into",
"  // state_d. The original encoded case is kept verbatim under translate_off as",
"  // load_control_ref with an encoding-equality assertion.",
"  localparam int LU_B_IDLE                = 0,",
"                 LU_B_WAIT_GNT            = 1,",
"                 LU_B_SEND_TAG            = 2,",
"                 LU_B_WAIT_PAGE_OFFSET    = 3,",
"                 LU_B_ABORT_TRANSACTION   = 4,",
"                 LU_B_ABORT_TRANSACTION_NI= 5,",
"                 LU_B_WAIT_TRANSLATION    = 6,",
"                 LU_B_WAIT_FLUSH          = 7,",
"                 LU_B_WAIT_WB_EMPTY       = 8,",
"                 LU_B_WAIT_SPEC_LOAD      = 9;",
] + [f"  localparam logic [9:0] LU_S_{s:<24} = 10'b1 << LU_B_{s};" for s in STATES] + [
"",
"  logic [9:0] state_d, state_q;",
]
src[E0:E1+1] = gen_enum

# 2. state_d = X -> LU_S_X ; case(state_q) -> case(1'b1) with bit items
LC = next(i for i,l in enumerate(src) if 'always_comb begin : load_control' in l)
LC_END = next(i for i,l in enumerate(src) if re.match(r'^  end\s*$', l) and i > LC)
blk = src[:]
for i in range(LC, LC_END+1):
    l = blk[i]
    l = re.sub(r'\bcase \(state_q\)', 'case (1\'b1)  // hyp8: one-hot state select', l)
    for s in STATES:
        # next-state literal
        l = re.sub(r'\bstate_d = '+s+r'\b', 'state_d = LU_S_'+s, l)
        # state_q == X / != X compares
        l = re.sub(r'\bstate_q == '+s+r'\b', 'state_q[LU_B_'+s+']', l)
        l = re.sub(r'\bstate_q != '+s+r'\b', '!state_q[LU_B_'+s+']', l)
        # case item label  (indent, optional comment text before)
        l = re.sub(r'^(\s*)'+s+r':', r'\1state_q[LU_B_'+s+']:', l)
    blk[i] = l
# also the wpo_cnt compare outside load_control
for i in range(len(blk)):
    if i < LC or i > LC_END:
        for s in STATES:
            blk[i] = re.sub(r'\bstate_q == '+s+r'\b', 'state_q[LU_B_'+s+']', blk[i])
            blk[i] = re.sub(r'\bstate_q != '+s+r'\b', '!state_q[LU_B_'+s+']', blk[i])
            blk[i] = re.sub(r'\bstate_q <= '+s+r'\b', 'state_q <= LU_S_'+s, blk[i])
src = blk

# sanity: no bare enum token left as a state reference
bad = [(i+1,l.strip()) for i,l in enumerate(src)
       if re.search(r'\bstate_[qd]\s*(==|!=|<=)\s*('+'|'.join(STATES)+r')\b', l)
       or re.search(r'^\s*('+'|'.join(STATES)+r')\s*:', l)]
for b in bad: print('LEFT:', b)

open(PATH,'w',encoding='utf-8').write('\n'.join(src))
print('done')

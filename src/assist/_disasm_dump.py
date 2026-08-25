#!/usr/bin/env python3.11
"""Disassemble every .pyc in assist/__pycache__ and dump structure + constants + bytecode.
Read-only: only reads .pyc, writes .disasm.txt next to them."""
import dis, marshal, os, sys, types

PYC_DIR = os.path.join(os.path.dirname(__file__), "__pycache__")

def load_code(path):
    with open(path, "rb") as f:
        data = f.read()
    # 3.7+ header is 16 bytes: magic(4) + bitfield/flags(4) + timestamp/hash(8)
    return marshal.loads(data[16:])

def walk_code(code, depth=0, lines=None):
    if lines is None:
        lines = []
    indent = "  " * depth
    lines.append(f"{indent}### CODE OBJECT: {code.co_name!r}  (qualname={code.co_qualname!r})")
    lines.append(f"{indent}    argcount={code.co_argcount} posonly={code.co_posonlyargcount} kwonly={code.co_kwonlyargcount}")
    lines.append(f"{indent}    varnames={code.co_varnames}")
    lines.append(f"{indent}    freevars={code.co_freevars} cellvars={code.co_cellvars}")
    if code.co_consts:
        lines.append(f"{indent}    -- consts ({len(code.co_consts)}) --")
        for i, c in enumerate(code.co_consts):
            if isinstance(c, types.CodeType):
                lines.append(f"{indent}      [{i}] <code {c.co_name!r}>")
            else:
                r = repr(c)
                if len(r) > 200:
                    r = r[:200] + "...(truncated)"
                lines.append(f"{indent}      [{i}] {type(c).__name__}: {r}")
    if code.co_names:
        lines.append(f"{indent}    -- names (attr/call targets) --")
        for n in code.co_names:
            lines.append(f"{indent}      {n}")
    lines.append(f"{indent}    -- DISASSEMBLY ({len(code.co_code)} bytes) --")
    try:
        for instr in dis.get_instructions(code):
            lines.append(f"{indent}      {instr.offset:4d} {instr.opname:<28s} {instr.argrepr or ''}")
    except Exception as e:
        lines.append(f"{indent}      <dis error: {e}>")
    lines.append("")
    for c in code.co_consts:
        if isinstance(c, types.CodeType):
            walk_code(c, depth+1, lines)
    return lines

for fn in sorted(os.listdir(PYC_DIR)):
    if not fn.endswith(".cpython-311.pyc"):
        continue
    path = os.path.join(PYC_DIR, fn)
    out = path + ".disasm.txt"
    try:
        code = load_code(path)
        lines = [f"===== {fn}  ({os.path.getsize(path)} bytes .pyc) =====", ""]
        walk_code(code, 0, lines)
        with open(out, "w") as f:
            f.write("\n".join(lines))
        print(f"OK  {fn}  ->  {out}  ({len(lines)} lines)")
    except Exception as e:
        print(f"ERR {fn}: {e}")

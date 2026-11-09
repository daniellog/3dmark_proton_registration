#!/usr/bin/env python3
"""Build a synthetic choros.jar for the 3DMark patch test suites.

The jar contains a structurally valid class with a single
ProductStateServiceImpl.checkCpusForInstructionsSetRequirement method, so the
patcher can be exercised without a real 3DMark installation.

Usage: make_choros_fixture.py <output.jar>
"""
import struct
import sys
import zipfile

METHOD = "checkCpusForInstructionsSetRequirement"
DESC = ("(Lcom/google/common/collect/ImmutableList$Builder;"
        "Lcom/futuremark/izzy/results/systeminfo/SystemInfo;"
        "Lcom/futuremark/izzy/results/systeminfo/InstructionSet;)V")
CLASS_ENTRY = "com/futuremark/choros/service/ProductStateServiceImpl.class"


def u2(v):
    return struct.pack(">H", v)


def utf8(s):
    b = s.encode()
    return b"\x01" + u2(len(b)) + b


def build_class():
    # 1=Test, 2=java/lang/Object, 3=Class(2), 4=method name,
    # 5=method descriptor, 6=Code, 7=Class(1)
    pool = [utf8("Test"), utf8("java/lang/Object"), b"\x07" + u2(2), utf8(METHOD),
            utf8(DESC), utf8("Code"), b"\x07" + u2(1)]
    out = b"\xca\xfe\xba\xbe" + u2(0) + u2(52) + u2(len(pool) + 1) + b"".join(pool)
    out += u2(0x0021) + u2(7) + u2(2)          # access, this=Test, super=Object
    out += u2(0)                               # interfaces
    out += u2(0)                               # fields
    code = b"\x00\x00\x00\x00\xb1"             # nop*4; return
    body = u2(0) + u2(1) + struct.pack(">I", len(code)) + code + u2(0) + u2(0)
    attributes = u2(1) + u2(6) + struct.pack(">I", len(body)) + body
    out += u2(1) + u2(0x000a) + u2(4) + u2(5) + attributes
    out += u2(0)                               # class attributes
    return out


def main():
    with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(CLASS_ENTRY, build_class())
        z.writestr("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\n")


if __name__ == "__main__":
    main()

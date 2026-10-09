#!/usr/bin/env python3
"""patch_libccl_thr_eintr.py [libccl_thr.so]

Fix the Quartus Prime 17.0.2 Lite (Build 602) parallel-synthesis stall seen under
Rosetta on Apple silicon (notes/quartus-apple-silicon.md).

thr_process_peek() polls a --parallel helper's output pipe with select() and returns
errno when select() fails, including EINTR. quartus_map's helper manager
(IPC_COMMAND::run_with_named_pipe in libccl_ipc.so) takes any error as a broken pipe,
waits 10 s, SIGTERMs the (healthy) helper and then blocks for ever opening that
helper's FIFO. This rewrites the 45-byte tail of thr_process_peek so that EINTR
returns 0 ("no data yet"; the caller polls again) and every other error is returned
as before.

The file is patched in place, only if it is exactly the 17.0.2 Build 602 library.
Runs on the image's own python3 (3.5).
"""
import hashlib
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/opt/intelFPGA/quartus/linux64/libccl_thr.so"
ORIG_MD5 = "b5293fee9b3dfd0dd993e8c2e1362c60"
PATCHED_MD5 = "798f2d480c7ac2a781723a7630514e1b"
OFFSET = 0x54EF  # thr_process_peek+0x74, just after "cmpl $-1, %eax" following select()

ORIG = bytes.fromhex(
    "7509"          # jne   ok
    "e89af8ffff"    # call  __errno_location
    "8b00"          # mov   (%rax),%eax
    "eb22"          # jmp   ret             <- every errno, EINTR included, returned
    "85c0"          # ok: test %eax,%eax
    "0f1f4000"      # nopl
    "7e0e"          # jle   ret0
    "4885db"        # test  %rbx,%rbx
    "7410"          # je    ret0
    "8903"          # mov   %eax,(%rbx)
    "b800000000"    # mov   $0,%eax
    "eb0c"          # jmp   ret
    "b800000000"    # ret0: mov $0,%eax
    "eb05"          # jmp   ret
    "b800000000"    # mov   $0,%eax
)
PATCH = bytes.fromhex(
    "7510"          # 54ef jne   ok
    "e89af8ffff"    # 54f1 call  __errno_location
    "8b00"          # 54f6 mov   (%rax),%eax
    "83f804"        # 54f8 cmp   $EINTR,%eax
    "751f"          # 54fb jne   ret         other errors: returned as before
    "31c0"          # 54fd zero: xor %eax,%eax
    "eb1b"          # 54ff jmp   ret         EINTR: "no data yet"
    "85c0"          # 5501 ok: test %eax,%eax
    "7ef8"          # 5503 jle   zero
    "4885db"        # 5505 test  %rbx,%rbx
    "74f3"          # 5508 je    zero
    "8903"          # 550a mov   %eax,(%rbx)
    "ebef"          # 550c jmp   zero
) + b"\x90" * 14    # 550e nop padding up to ret (551c)


def md5(data):
    return hashlib.md5(data).hexdigest()


def main():
    with open(PATH, "rb") as f:
        data = bytearray(f.read())
    if md5(data) == PATCHED_MD5:
        print("%s: already patched" % PATH)
        return 0
    if md5(data) != ORIG_MD5:
        print("%s: md5 %s is not Quartus 17.0.2 Build 602's libccl_thr.so; not touching it" % (PATH, md5(data)))
        return 1
    assert len(ORIG) == len(PATCH) == 45
    if bytes(data[OFFSET:OFFSET + len(ORIG)]) != ORIG:
        print("%s: unexpected bytes at 0x%x; not touching it" % (PATH, OFFSET))
        return 1
    data[OFFSET:OFFSET + len(PATCH)] = PATCH
    if md5(data) != PATCHED_MD5:
        print("%s: patched md5 %s is not %s; not writing it" % (PATH, md5(data), PATCHED_MD5))
        return 1
    with open(PATH, "r+b") as f:
        f.seek(OFFSET)
        f.write(PATCH)
    print("%s: patched (md5 %s)" % (PATH, PATCHED_MD5))
    return 0


if __name__ == "__main__":
    sys.exit(main())

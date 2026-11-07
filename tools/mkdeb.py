#!/usr/bin/env python3
"""自己写一个合法的 .deb（ar 归档）。

为什么要自己写：macOS 的 ar/ranlib 会把非 Mach-O 成员丢掉（日志里
"ranlib: warning: archive member 'debian-binary' not a mach-o file"），
结果产出一个 96 字节的空 deb。这里直接按 ar 格式写，跨平台一致。

用法: mkdeb.py <out.deb> <dir-with-members>
     成员固定为 debian-binary / control.tar.gz / data.tar.gz
"""
import sys, os, time


def pack(out, members):
    with open(out, "wb") as f:
        f.write(b"!<arch>\n")
        for name, path in members:
            data = open(path, "rb").read()
            hdr = "{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n".format(
                name, int(time.time()), 0, 0, "100644", len(data))
            if len(hdr) != 60:
                raise SystemExit("bad ar header len %d" % len(hdr))
            f.write(hdr.encode("ascii"))
            f.write(data)
            if len(data) % 2:
                f.write(b"\n")


if __name__ == "__main__":
    out, d = sys.argv[1], sys.argv[2]
    names = ["debian-binary", "control.tar.gz", "data.tar.gz"]
    missing = [n for n in names if not os.path.exists(os.path.join(d, n))]
    if missing:
        raise SystemExit("缺少成员: %s" % ", ".join(missing))
    pack(out, [(n, os.path.join(d, n)) for n in names])
    print("mkdeb: %s (%d bytes)" % (out, os.path.getsize(out)))

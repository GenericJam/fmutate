"""`python3 -m ziglang ...` (the ziglang wheel's zig) as tools/native_catalog/wasmcc's zig stand-in"""
import os
import sys

zig = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "zig")
os.execv(zig, [zig, *sys.argv[1:]])

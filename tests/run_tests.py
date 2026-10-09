#!/usr/bin/env python3
"""Run the Lua test suite without a system Lua install.

Uses the `lupa` package's embedded Lua 5.1 (the same Lua version as the WoW
client):  python3 -m pip install lupa && python3 tests/run_tests.py
If `lua5.1` is installed you can also just run:  lua5.1 tests/run.lua
"""

import os
import sys

try:
    import lupa.lua51 as lupa
except ImportError:
    sys.exit("lupa is not installed: python3 -m pip install lupa   (or run: lua5.1 tests/run.lua)")

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lua = lupa.LuaRuntime()
assert lua.eval("_VERSION") == "Lua 5.1", lua.eval("_VERSION")
try:
    lua.execute(f'arg = {{ [[{root}]] }}; dofile([[{root}/tests/run.lua]])')
except lupa.LuaError as e:
    print(e)
    sys.exit(1)

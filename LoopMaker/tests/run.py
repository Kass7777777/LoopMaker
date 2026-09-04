"""Run native Lua 5.4 tests through Lupa; no REAPER or audio files are needed."""
import argparse
from pathlib import Path
import sys
from time import perf_counter


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument('--ui', action='store_true', help='UI model, window and preset actions only')
    scope.add_argument('--full', action='store_true', help='All regression modules (default)')
    scope.add_argument('--modules', help='Comma-separated modules, e.g. main_window,ui_model')
    parser.add_argument('--verbose', action='store_true', help='Also show every passing case')
    parser.add_argument('--syntax', action='store_true', help='Check all project Lua files after tests')
    options = parser.parse_args()
    try:
        from lupa.lua54 import LuaRuntime
    except ImportError:
        print('Lua 5.4 runtime missing: install lupa into this Python environment.', file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parents[1]
    lua = LuaRuntime(unpack_returned_tuples=True)
    args = ['--ui'] if options.ui else ['--modules=' + options.modules] if options.modules is not None else []
    if options.verbose:
        args.append('--verbose')
    lua.globals().arg = lua.table_from(args)
    lua.globals().test_write = lambda *parts: print(''.join(map(str, parts)), end='', flush=True)
    lua.execute('io.write = test_write; os.exit = function(code) error("Tests exited with code " .. code, 0) end')
    started = perf_counter()
    try:
        lua.execute('dofile(...)', (root / 'tests/run.lua').as_posix())
        if options.syntax:
            check = lua.eval('function(p) local f,e=loadfile(p); return f~=nil,e end')
            files = sorted(root.rglob('*.lua'))
            for path in files:
                ok, reason = check(path.as_posix())
                if not ok:
                    raise RuntimeError(str(reason))
            print(f'Syntax: {len(files)} Lua files passed')
    except Exception as error:
        print(str(error).split('stack traceback:')[0].strip(), file=sys.stderr)
        return 1
    finally:
        print(f'Elapsed: {perf_counter() - started:.3f}s')
    return 0


if __name__ == '__main__':
    sys.exit(main())

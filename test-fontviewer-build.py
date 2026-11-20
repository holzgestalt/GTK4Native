"""Build the existing live-input test against ProjectCenter's PBX products.

This is test instrumentation only; application builds use the installed engine
and the original Xcode projects without any FontTableViewer build definition.
"""
import argparse
import importlib.util
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

engine, project, destination = map(Path, sys.argv[1:])
subprocess.run([sys.executable, str(engine), '--project', str(project), '--theme', 'GTK4Native'], check=True)
spec = importlib.util.spec_from_file_location('pbx_build', engine)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
build = module.Build(argparse.Namespace(project=project, target=None, configuration='Debug', build_dir=None, theme='GTK4Native'))
objects = []
for p, r in build.ordered:
    objects += build.compile_target(p, r, build.build_dir / 'Headers')
objects = [o for o in objects if not o.name.endswith('-main.m.o')]
root = Path(__file__).resolve().parent
header = next(p for p in build.root.paths.values() if p.name == 'GSWindowController.h')
flags = shlex.split(module.output(['gnustep-config', '--objc-flags']))
flags += build.sdk.compiler_flags()
flags += ['-I' + str(root), '-I' + str(header.parent), '-I' + str(build.build_dir / 'Headers')]
destination.mkdir(parents=True, exist_ok=True)
obj = destination / 'fonttableviewer-test.o'
subprocess.run(['clang', *flags, '-c', str(root / 'fonttableviewer-test.m'), '-o', str(obj)], check=True)
bundle = destination / 'FontTableViewerTest.app'
bundle.mkdir(exist_ok=True)
resources = bundle / 'Resources'
if resources.is_symlink(): resources.unlink()
elif resources.exists(): shutil.rmtree(resources)
resources.symlink_to(build.executable().parent / 'Resources')
libs = shlex.split(module.output(['pkg-config', '--libs', 'gnustep-theme-GTK4Native']))
libs += shlex.split(module.output(['gnustep-config', '--gui-libs']))
libs += build.sdk.link_flags()
subprocess.run(['clang++', *map(str, objects), str(obj), '-o', str(bundle / 'FontTableViewer'), *libs], check=True)

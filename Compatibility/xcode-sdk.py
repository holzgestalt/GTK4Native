"""Installed GTK4Native SDK hooks for ProjectCenter's PBX compiler.

These are toolchain capabilities, not application target/source declarations.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
SOURCES = [ROOT / 'FontToolsPlatform.m']
REPLACED_FRAMEWORKS = {'Sparkle': 'macOS updater is disabled in GNUstep source builds',
                       'WebKit': 'specification links use the installed GTK browser-link adapter'}


def compiler_flags():
    import shlex
    return ['-I' + str(ROOT), '-include', str(ROOT / 'FontToolsPlatform.h'),
            *shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'gtk4-x11'], text=True))]


def link_flags():
    return ['-lz', '-ldispatch']


def build_inputs():
    return [path for path in ROOT.rglob('*') if path.suffix in ('.h', '.m', '.py')]


def prepare_resources(resources):
    # Modern XIB decoding and native split hierarchy remain provider-owned.
    subprocess.run([sys.executable, str(ROOT / 'prepare-fontviewer-resources.py'), str(resources)], check=True)

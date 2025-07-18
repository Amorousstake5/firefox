#!/usr/bin/env python

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Utility functions for mozrunner"""

import os
import subprocess
import sys

import mozinfo

__all__ = ["findInPath"]


def findInPath(fileName, path=os.environ["PATH"]):
    """python equivalent of which; should really be in the stdlib"""
    dirs = path.split(os.pathsep)
    for dir in dirs:
        if os.path.isfile(os.path.join(dir, fileName)):
            return os.path.join(dir, fileName)
        if mozinfo.isWin:
            if os.path.isfile(os.path.join(dir, fileName + ".exe")):
                return os.path.join(dir, fileName + ".exe")


if __name__ == "__main__":
    for i in sys.argv[1:]:
        print(findInPath(i))


def _find_marionette_in_args(*args, **kwargs):
    try:
        m = [a for a in args + tuple(kwargs.values()) if hasattr(a, "session")][0]
    except IndexError:
        print("Can only apply decorator to function using a marionette object")
        raise
    return m


def _raw_log():
    import logging

    return logging.getLogger(__name__)


def test_environment(
    xrePath, env=None, crashreporter=True, debugger=False, useLSan=False, log=None
):
    """
    populate OS environment variables for mochitest and reftests.

    Originally comes from automationutils.py. Don't use that for new code.
    """

    env = os.environ.copy() if env is None else env
    log = log or _raw_log()

    assert os.path.isabs(xrePath)

    if mozinfo.isMac:
        ldLibraryPath = os.path.join(os.path.dirname(xrePath), "MacOS")
    else:
        ldLibraryPath = xrePath

    envVar = None
    if mozinfo.isLinux:
        envVar = "LD_LIBRARY_PATH"
    elif mozinfo.isMac:
        envVar = "DYLD_LIBRARY_PATH"
    elif mozinfo.isWin:
        envVar = "PATH"
    if envVar:
        envValue = (
            (env.get(envVar), str(ldLibraryPath))
            if mozinfo.isWin
            else (ldLibraryPath, env.get(envVar))
        )
        env[envVar] = os.path.pathsep.join([path for path in envValue if path])

    # Allow non-packaged builds to access symlinked modules in the source dir
    env["MOZ_DEVELOPER_REPO_DIR"] = mozinfo.info.get("topsrcdir")
    env["MOZ_DEVELOPER_OBJ_DIR"] = mozinfo.info.get("topobjdir")

    # crashreporter
    env["GNOME_DISABLE_CRASH_DIALOG"] = "1"
    env["XRE_NO_WINDOWS_CRASH_DIALOG"] = "1"

    if crashreporter and not debugger:
        env["MOZ_CRASHREPORTER_NO_REPORT"] = "1"
        env["MOZ_CRASHREPORTER"] = "1"
        env["MOZ_CRASHREPORTER_SHUTDOWN"] = "1"
    else:
        env["MOZ_CRASHREPORTER_DISABLE"] = "1"

    # Crash on non-local network connections by default.
    # MOZ_DISABLE_NONLOCAL_CONNECTIONS can be set to "0" to temporarily
    # enable non-local connections for the purposes of local testing.  Don't
    # override the user's choice here.  See bug 1049688.
    env.setdefault("MOZ_DISABLE_NONLOCAL_CONNECTIONS", "1")

    # Set WebRTC logging in case it is not set yet
    env.setdefault("MOZ_LOG", "signaling:3,mtransport:4,DataChannel:3,jsep:4")
    env.setdefault("R_LOG_LEVEL", "6")
    env.setdefault("R_LOG_DESTINATION", "stderr")
    env.setdefault("R_LOG_VERBOSE", "1")

    # Ask NSS to use lower-security password encryption. See Bug 1594559
    env.setdefault("NSS_MAX_MP_PBE_ITERATION_COUNT", "10")

    # ASan specific environment stuff
    if "ASAN_SYMBOLIZER_PATH" in env and os.path.isfile(env["ASAN_SYMBOLIZER_PATH"]):
        llvmsym = env["ASAN_SYMBOLIZER_PATH"]
    else:
        if mozinfo.isMac:
            llvmSymbolizerDir = ldLibraryPath
        else:
            llvmSymbolizerDir = xrePath
        llvmsym = os.path.join(
            llvmSymbolizerDir, "llvm-symbolizer" + mozinfo.info["bin_suffix"]
        )
    asan = bool(mozinfo.info.get("asan"))
    if asan:
        try:
            # Symbolizer support
            if os.path.isfile(llvmsym):
                env["ASAN_SYMBOLIZER_PATH"] = llvmsym
                log.info("INFO | runtests.py | ASan using symbolizer at %s" % llvmsym)
            else:
                log.error(
                    "TEST-UNEXPECTED-FAIL | runtests.py | Failed to find"
                    " ASan symbolizer at %s" % llvmsym
                )

            # Returns total system memory in kilobytes.
            if mozinfo.isWin:
                argstring = "(Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1024"
                args = ["powershell.exe", "-c", argstring]
                output = subprocess.run(
                    args, text=True, capture_output=True, check=True
                ).stdout

                totalMemory = int(output.strip())
            elif mozinfo.isMac:
                # pylint --py3k W1619
                totalMemory = (
                    int(os.popen("sysctl hw.memsize").readlines()[0].split()[1]) / 1024
                )
            else:
                totalMemory = int(os.popen("free").readlines()[1].split()[1])

            # Only 4 GB RAM or less available? Use custom ASan options to reduce
            # the amount of resources required to do the tests. Standard options
            # will otherwise lead to OOM conditions on the current test machines.
            message = "INFO | runtests.py | ASan running in %s configuration"
            asanOptions = []
            if totalMemory <= 1024 * 1024 * 4:
                message = message % "low-memory"
                asanOptions = ["quarantine_size=50331648", "malloc_context_size=5"]
            else:
                message = message % "default memory"

            if useLSan:
                log.info("LSan enabled.")
                asanOptions.append("detect_leaks=1")
                lsanOptions = ["exitcode=0"]
                # Uncomment out the next line to report the addresses of leaked objects.
                # lsanOptions.append("report_objects=1")
                env["LSAN_OPTIONS"] = ":".join(lsanOptions)

            if len(asanOptions):
                env["ASAN_OPTIONS"] = ":".join(asanOptions)

        except OSError as err:
            log.info(
                "Failed determine available memory, disabling ASan"
                " low-memory configuration: %s" % err.strerror
            )
        except Exception:
            log.info(
                "Failed determine available memory, disabling ASan"
                " low-memory configuration"
            )
        else:
            log.info(message)

    tsan = bool(mozinfo.info.get("tsan"))
    if tsan and mozinfo.isLinux:
        # Symbolizer support.
        if os.path.isfile(llvmsym):
            env["TSAN_OPTIONS"] = "external_symbolizer_path=%s" % llvmsym
            log.info("INFO | runtests.py | TSan using symbolizer at %s" % llvmsym)
        else:
            log.error(
                "TEST-UNEXPECTED-FAIL | runtests.py | Failed to find TSan"
                " symbolizer at %s" % llvmsym
            )

    ubsan = bool(mozinfo.info.get("ubsan"))
    if ubsan and (mozinfo.isLinux or mozinfo.isMac):
        log.info("UBSan enabled.")

    return env


def get_stack_fixer_function(utilityPath, symbolsPath, hideErrors=False):
    """
    Return a stack fixing function, if possible, to use on output lines.

    A stack fixing function checks if a line conforms to the output from
    MozFormatCodeAddressDetails.  If the line does not, the line is returned
    unchanged.  If the line does, an attempt is made to convert the
    file+offset into something human-readable (e.g. a function name).
    """
    if not mozinfo.info.get("debug"):
        return None

    if os.getenv("MOZ_DISABLE_STACK_FIX", 0):
        print(
            "WARNING: No stack-fixing will occur because MOZ_DISABLE_STACK_FIX is set"
        )
        return None

    def import_stack_fixer_module(module_name):
        sys.path.insert(0, utilityPath)
        module = __import__(module_name, globals(), locals(), [])
        sys.path.pop(0)
        return module

    if symbolsPath and os.path.exists(symbolsPath):
        # Run each line through fix_stacks.py, using breakpad symbol files.
        # This method is preferred for automation, since native symbols may
        # have been stripped.
        stack_fixer_module = import_stack_fixer_module("fix_stacks")

        def stack_fixer_function(line):
            return stack_fixer_module.fixSymbols(
                line,
                slowWarning=True,
                breakpadSymsDir=symbolsPath,
                hide_errors=hideErrors,
            )

    elif mozinfo.isLinux or mozinfo.isMac or mozinfo.isWin:
        # Run each line through fix_stacks.py. This method is preferred for
        # developer machines, so we don't have to run "mach buildsymbols".
        stack_fixer_module = import_stack_fixer_module("fix_stacks")

        def stack_fixer_function(line):
            return stack_fixer_module.fixSymbols(
                line, slowWarning=True, hide_errors=hideErrors
            )

    else:
        return None

    return stack_fixer_function

#!/usr/bin/env python3
# PreToolUse guard for the Bash tool: refuses the two command shapes that leave a finished or failed
# build unnoticed. Exit status 2 blocks the call and returns stderr to Claude.
import json
import re
import sys

command = json.load(sys.stdin).get("tool_input", {}).get("command", "")

# Heredoc bodies are data (commit messages, scripts written to files), not commands.
command = re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?^\s*\2\s*$", "<<heredoc", command, flags=re.S | re.M)
# Quoted strings are arguments; a launch is an unquoted word.
unquoted = re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "''", command)

launch = re.search(r"(^|[;&|(\n]|\bnohup)\s*(bash\s+|sh\s+)?\S*AquaWebKitSupport/build\.sh\b", unquoted)
if launch:
    without_redirects = re.sub(r"&&|[0-9]*>&[0-9]*|&>", "", unquoted)
    if re.search(r"\bnohup\b", unquoted) or "&" in without_redirects:
        sys.stderr.write(
            "Blocked: do not wrap AquaWebKitSupport/build.sh in nohup or '&'. Run it as the whole command with "
            "the Bash tool's run_in_background: true, e.g. `bash AquaWebKitSupport/build.sh >> /tmp/wk_build.log 2>&1`, "
            "so the harness notifies you when the build exits, whether it passed or failed.\n")
        sys.exit(2)

for match in re.finditer(r"\bpgrep\b((?:\s+-[A-Za-z]+)*)\s+(?:'([^']*)'|\"([^\"]*)\"|(\S+))", command):
    flags, pattern = match.group(1), match.group(2) or match.group(3) or match.group(4) or ""
    if "f" in flags.replace("-", "") and re.search(r"build\.sh|ninja", pattern) and "[" not in pattern:
        sys.stderr.write(
            "Blocked: `pgrep -f` with a pattern naming build.sh or ninja matches the waiting shell's own command "
            "line, so a wait on it never ends. Launch the build with run_in_background: true and act on its "
            "completion notification instead.\n")
        sys.exit(2)

#!/usr/bin/env python3
# Stop hook: refuses to let a turn end while the final message admits unfinished work, and tells Claude
# which phrases did it. After MAX_BLOCKS consecutive refusals in one session the stop goes through and the
# user sees why, so a false positive cannot loop forever.
import json
import os
import re
import sys

MAX_BLOCKS = 5

PATTERNS = [
    r"\bstill open\b",
    r"\bOPEN\b",
    r"\bnot (?:yet )?root[- ]caused\b",
    r"\bunresolved\b",
    r"\bnot (?:yet )?(?:fixed|resolved|investigated|verified|tested|done|finished)\b",
    r"\bfollow[- ]?ups?\b",
    r"\bleft (?:as|for) (?:a |an )?(?:follow|later|future|todo|open)",
    r"\bremains? to be\b",
    r"\b(?:could|can)(?:n't| ?not) (?:fix|root[- ]cause|resolve|finish|complete)\b",
    r"\bTODO\b",
    r"\bnext steps?\b",
    r"\bknown (?:issue|limitation|bug)s?\b",
    r"\bout of scope\b",
    r"\bpre-?existing\b",
    r"\bnot (?:caused by|related to|part of) (?:this|my) change\b",
    r"\b(?:blocked|waiting) on\b",
    r"\bneeds? your\b",
    r"\byours to\b",
    r"\bI(?:'ll| will) leave\b",
    r"\bseparate (?:issue|bug|change|task)\b",
    r"\bdefer(?:red|ring)?\b",
]

CASE_SENSITIVE = {r"\bOPEN\b", r"\bTODO\b"}


def last_assistant_text(payload):
    text = payload.get("last_assistant_message")
    if isinstance(text, str) and text.strip():
        return text
    path = payload.get("transcript_path")
    if not path or not os.path.exists(path):
        return ""
    last = ""
    with open(path, encoding="utf-8", errors="replace") as transcript:
        for line in transcript:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") != "assistant":
                continue
            content = entry.get("message", {}).get("content")
            if isinstance(content, str):
                parts = [content]
            else:
                parts = [c.get("text", "") for c in content or [] if isinstance(c, dict) and c.get("type") == "text"]
            joined = "\n".join(p for p in parts if p)
            if joined.strip():
                last = joined
    return last


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    text = last_assistant_text(payload)
    # Quoted material (code spans and blocks, block quotes) is not the assistant's own claim.
    prose = re.sub(r"```.*?```", "", text, flags=re.S)
    prose = re.sub(r"`[^`\n]*`", "", prose)
    prose = "\n".join(l for l in prose.splitlines() if not l.lstrip().startswith(">"))
    hits = sorted({m.group(0) for p in PATTERNS for m in re.finditer(p, prose, 0 if p in CASE_SENSITIVE else re.I)})

    session = re.sub(r"[^A-Za-z0-9_-]", "", str(payload.get("session_id", "default"))) or "default"
    counter = os.path.join(os.environ.get("TMPDIR", "/tmp"), "claude-stop-guard-%s" % session)
    if not hits:
        if os.path.exists(counter):
            os.remove(counter)
        return
    try:
        count = int(open(counter).read().strip() or 0)
    except (OSError, ValueError):
        count = 0
    if count >= MAX_BLOCKS:
        os.remove(counter)
        print(json.dumps({"systemMessage": "Stop guard released after %d refusals; the final message still says: %s" % (MAX_BLOCKS, ", ".join(hits))}))
        return
    with open(counter, "w") as f:
        f.write(str(count + 1))
    print(json.dumps({
        "decision": "block",
        "reason": ("Your final message admits unfinished work (%s). Ending a turn with an open item is forbidden "
                   "(CLAUDE.md, Autonomy). Do the work now: root-cause and fix it, verify it, get the reviewer's "
                   "approval, commit, and only then report what you DID. If the phrase is a false positive, "
                   "rewrite the report so it states only finished work.") % ", ".join(hits),
    }))


main()

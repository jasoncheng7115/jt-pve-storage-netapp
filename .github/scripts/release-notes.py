#!/usr/bin/env python3
"""Build GitHub Release notes for a tag from the bilingual CHANGELOGs.

Fails loudly rather than publishing an empty or wrong release: a missing or
empty CHANGELOG section is an error, not an empty release body.

Writes RELEASE_TITLE.txt and RELEASE_NOTES.md into the working directory.
"""
import re
import sys


def section(path, version):
    """Return the body of '## [version] - date' up to the next '## ['."""
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        sys.exit(f"ERROR: {path} not found")

    pat = re.compile(
        r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)",
        re.S | re.M,
    )
    m = pat.search(text)
    if not m:
        sys.exit(f"ERROR: no '## [{version}]' section in {path}")
    body = m.group(1).strip()
    if not body:
        sys.exit(f"ERROR: the '## [{version}]' section in {path} is empty")
    return body


def first_heading(body):
    m = re.search(r"^#{3,4} (.+)$", body, re.M)
    return m.group(1).strip() if m else None


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: release-notes.py <tag>   e.g. 0.2.28-1")
    tag = sys.argv[1]
    version = tag.rsplit("-", 1)[0]  # 0.2.28-1 -> 0.2.28

    en = section("CHANGELOG.md", version)
    zh = section("CHANGELOG_zh-TW.md", version)

    heading = first_heading(en)
    # Em-dash between the version and the name, never a colon (project style).
    title = f"{tag} — {heading}" if heading else tag

    deb = f"jt-pve-storage-netapp_{tag}_all.deb"
    body = f"""## Installation

```bash
dpkg -i {deb}
```

After upgrading, run `systemctl restart pvestatd` on **every** cluster node.
A reload sends SIGHUP and Proxmox VE re-execs with the same PID, which does not
reliably reload Perl modules, so the previously running plugin code stays active.

Full documentation: https://jasoncheng7115.github.io/jt-pve-storage-netapp/

---

{en}

---

<details>
<summary>繁體中文</summary>

{zh}

</details>
"""

    with open("RELEASE_TITLE.txt", "w", encoding="utf-8") as f:
        f.write(title)
    with open("RELEASE_NOTES.md", "w", encoding="utf-8") as f:
        f.write(body)
    print(f"title: {title}")
    print(f"notes: {len(body)} bytes")


if __name__ == "__main__":
    main()

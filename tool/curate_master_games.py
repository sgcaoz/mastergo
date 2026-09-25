#!/usr/bin/env python3
"""Extract a curated public-domain master-game set from Brouwer + tasuki sources."""

from __future__ import annotations

import re
import shutil
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STAGING = Path("/tmp/mastergo_sgf/staging")
TAR = Path("/tmp/mastergo_sgf/games.tgz")
TASUKI = Path("/tmp/mastergo_sgf/tasuki")

# Selection is by collection/role, not individual famous-game IDs.
TAR_MEMBERS: list[tuple[str, str, list[str]]] = []

def add(path: str, category: str, *tags: str) -> None:
    TAR_MEMBERS.append((path, category, list(tags)))

# 古谱：当湖十局
for i in range(1, 11):
    add(f"games/ancient/old_chinese/DH{i:02d}.sgf", "ancient", "danghu")

# 古谱：秀策耳赤之局、道策全集稍后按 DT 过滤
add("games/Shusaku/126.sgf", "ancient", "shusaku", "castle")

# 国际大赛：应氏杯第 1 届决赛（目录 17–21 为决赛五局）
for n in range(17, 22):
    add(f"games/Ing/01/{n:02d}.sgf", "international", "ing_cup")
# 应氏杯第 8 届决赛（目录末尾 33–37）
for n in range(33, 38):
    add(f"games/Ing/08/{n:02d}.sgf", "international", "ing_cup")

# 各公开赛决赛：取首届 + 一届中期 + 较近一届（有 F*.sgf 的杯赛）
for cup, tag, editions in (
    ("LG", "lg_cup", ("01", "15", "25")),
    ("Samsung", "samsung_cup", ("01", "18", "28")),
    ("Chunlan", "chunlan_cup", ("01", "08", "14")),
    ("Mlily", "mlily_cup", ("01", "04")),
    ("Toyota", "toyota_denso_cup", ("01", "03")),
):
    for ed in editions:
        # F*.sgf are finals in this archive's convention.
        TAR_MEMBERS.append((f"games/{cup}/{ed}/", category := "international", [tag]))

for ed in ("01", "15", "31"):
    add(f"games/AsianTV/{ed}/F.sgf", "international", "asian_tv_cup")

add("games/Fujitsu/01/15.sgf", "international", "fujitsu_cup")
add("games/Fujitsu/04/F01.sgf", "international", "fujitsu_cup")
add("games/Fujitsu/24/F01.sgf", "international", "fujitsu_cup")

# 人机：樊麾五番棋；乌镇 pairgo/team 不与现有柯洁三局重复的 4、5
for n in range(1, 6):
    add(f"games/AlphaGo/FanHui/{n}.sgf", "ai", "alphago", "fan_hui")
add("games/AlphaGo/May2017/4.sgf", "ai", "alphago", "wuzhen")
add("games/AlphaGo/May2017/5.sgf", "ai", "alphago", "wuzhen")

# 道策 / 丈和：整目录抽出后按谱面（日期、对手）过滤，不绑死文件编号。

TASUKI_ANCIENT = [
    "1582.sgf", "1625.sgf", "1682.sgf", "1683.sgf", "1705.sgf", "1740.sgf",
    "1792.sgf", "1812.sgf", "1815.sgf", "1820.sgf", "1835.sgf", "1842.sgf",
    "1844.sgf", "1846.sgf", "1851.sgf", "1852.sgf", "1853.sgf", "1895.sgf",
]
TASUKI_CLASSIC = [
    "1926.sgf", "1929.sgf", "1933.sgf", "1934.sgf", "1938.sgf", "1939.sgf",
    "1945.sgf", "1948.sgf", "1951.sgf", "1957.sgf", "1957a.sgf", "1959.sgf",
    "2003.sgf",
]

PROP_RE = re.compile(r"([A-Z]+)\[((?:\\.|[^\]])*)\]")


def first_game(text: str) -> str:
    start = text.find("(;")
    if start < 0:
        return text
    depth = 0
    for i, ch in enumerate(text[start:], start):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return text[start:]


def props(text: str) -> dict[str, str]:
    head = text[: min(len(text), 2500)]
    out: dict[str, str] = {}
    for key, val in PROP_RE.findall(head):
        out.setdefault(key, val.replace("\\]", "]"))
    return out


def move_count(text: str) -> int:
    return len(re.findall(r";[BW]\[(?:[a-s]{2})?\]", text))


def slug(raw: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "_", raw).strip("_").lower()
    return s[:80] or "game"


def write_game(dest_id: str, text: str, category: str, tags: list[str], source: str) -> None:
    body = first_game(text).strip() + "\n"
    p = props(body)
    moves = move_count(body)
    re_ = (p.get("RE") or "").lower()
    if "unfinished" in re_ or re_ in {"?", "void"}:
        print(f"SKIP incomplete RE={p.get('RE')} {source}")
        return
    sz = int(p.get("SZ") or "19")
    if sz != 19:
        print(f"SKIP size={sz} {source}")
        return
    if not p.get("PB") or not p.get("PW"):
        print(f"SKIP missing players {source}")
        return
    try:
        ha = int(p.get("HA") or "0")
    except ValueError:
        ha = 0
    min_moves = 50 if ha >= 2 else 80
    if moves < min_moves:
        print(f"SKIP short moves={moves} {source}")
        return
    meta = STAGING / f"{dest_id}.meta"
    sgf_path = STAGING / f"{dest_id}.sgf"
    sgf_path.write_text(body, encoding="utf-8")
    meta.write_text(
        "\n".join(
            [
                f"category={category}",
                f"tags={','.join(tags)}",
                f"source={source}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"OK {dest_id} moves={moves} {p.get('PB')} vs {p.get('PW')} {p.get('DT', '')}")


def extract_exact(tf: tarfile.TarFile, member: str, category: str, tags: list[str]) -> None:
    try:
        f = tf.extractfile(member)
    except KeyError:
        print(f"MISS {member}")
        return
    if f is None:
        print(f"MISS {member}")
        return
    text = f.read().decode("utf-8", errors="replace")
    dest_id = slug(member.replace("games/", "").replace(".sgf", ""))
    write_game(dest_id, text, category, tags, member)


def extract_prefix_finals(tf: tarfile.TarFile, prefix: str, category: str, tags: list[str]) -> None:
    names = [n for n in tf.getnames() if n.startswith(prefix) and n.endswith(".sgf")]
    finals = [n for n in names if re.search(r"/F[0-9]*\.sgf$", n)]
    chosen = finals if finals else []
    for member in chosen:
        extract_exact(tf, member, category, tags)


def pick_dosaku_jowa(tf: tarfile.TarFile) -> None:
    want_dt = {
        "1670-11-29": ("ancient", ["dosaku", "castle", "tengen"]),
        "1684-01-05": ("ancient", ["dosaku", "castle"]),
        "1835-07": ("ancient", ["jowa", "blood_vomiting"]),
    }
    for prefix, default_tags in (
        ("games/Dosaku/", ["dosaku"]),
        ("games/ancient/Honinbo_Jowa/", ["jowa"]),
    ):
        for name in tf.getnames():
            if not name.startswith(prefix) or not name.endswith(".sgf"):
                continue
            f = tf.extractfile(name)
            if f is None:
                continue
            text = f.read().decode("utf-8", errors="replace")
            p = props(first_game(text))
            dt = p.get("DT") or ""
            pb = p.get("PB") or ""
            pw = p.get("PW") or ""
            matched = None
            for key, meta in want_dt.items():
                if dt.startswith(key):
                    matched = meta
                    break
            if matched is None and prefix.endswith("Honinbo_Jowa/") and "1835" in dt:
                if "Intetsu" in pb or "Intetsu" in pw or "因徹" in pb or "因徹" in pw:
                    matched = ("ancient", ["jowa", "blood_vomiting"])
            if matched is None:
                continue
            dest_id = slug(name.replace("games/", "").replace(".sgf", ""))
            write_game(dest_id, text, matched[0], matched[1], name)


def main() -> None:
    if STAGING.exists():
        shutil.rmtree(STAGING)
    STAGING.mkdir(parents=True)
    if not TAR.exists():
        raise SystemExit(f"missing {TAR}")

    with tarfile.open(TAR, "r:gz") as tf:
        names = set(tf.getnames())
        for path, category, tags in TAR_MEMBERS:
            if path.endswith("/"):
                extract_prefix_finals(tf, path, category, tags)
            elif path in names:
                extract_exact(tf, path, category, tags)
            else:
                print(f"MISS {path}")
        pick_dosaku_jowa(tf)

    for fn in TASUKI_ANCIENT:
        src = TASUKI / fn
        if src.exists():
            write_game(
                slug(f"famous_{fn[:-4]}"),
                src.read_text(encoding="utf-8", errors="replace"),
                "ancient",
                ["famous"],
                f"tasuki/{fn}",
            )
    for fn in TASUKI_CLASSIC:
        src = TASUKI / fn
        if src.exists():
            write_game(
                slug(f"famous_{fn[:-4]}"),
                src.read_text(encoding="utf-8", errors="replace"),
                "classic",
                ["famous"],
                f"tasuki/{fn}",
            )

    print(f"staged {len(list(STAGING.glob('*.sgf')))} sgf files")


if __name__ == "__main__":
    main()

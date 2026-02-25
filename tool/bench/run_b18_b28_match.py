#!/usr/bin/env python3
import csv
import json
import random
import re
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


@dataclass
class EngineSpec:
    name: str
    model_path: Path
    visits: int


class GtpEngine:
    def __init__(self, katago_bin: Path, config_path: Path, spec: EngineSpec) -> None:
        self.spec = spec
        self.proc = subprocess.Popen(
            [
                str(katago_bin),
                "gtp",
                "-config",
                str(config_path),
                "-model",
                str(spec.model_path),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        if self.proc.stdin is None or self.proc.stdout is None:
            raise RuntimeError(f"Failed to start process for {spec.name}")

    def cmd(self, command: str) -> str:
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()
        lines: list[str] = []
        while True:
            line = self.proc.stdout.readline()
            if line == "":
                raise RuntimeError(
                    f"Engine {self.spec.name} closed unexpectedly while running: {command}"
                )
            line = line.rstrip("\n")
            if line == "":
                if lines:
                    break
                continue
            lines.append(line)
        first = lines[0]
        if first.startswith("?"):
            raise RuntimeError(
                f"Engine {self.spec.name} command failed: {command} -> {' | '.join(lines)}"
            )
        if not first.startswith("="):
            raise RuntimeError(
                f"Engine {self.spec.name} malformed response: {command} -> {' | '.join(lines)}"
            )
        if len(lines) == 1:
            return first[1:].strip()
        rest = [first[1:].strip(), *lines[1:]]
        return "\n".join([s for s in rest if s])

    def close(self) -> None:
        try:
            self.cmd("quit")
        except Exception:
            pass
        finally:
            self.proc.kill()
            self.proc.wait(timeout=5)


_PLAY_RE = re.compile(r"\bplay\s+([A-Za-z][0-9]{1,2}|pass|resign)\b", re.IGNORECASE)
_WHITE_WIN_RE = re.compile(r"^whiteWin\s+([0-9]*\.?[0-9]+)$", re.MULTILINE)
_WHITE_LOSS_RE = re.compile(r"^whiteLoss\s+([0-9]*\.?[0-9]+)$", re.MULTILINE)


@dataclass
class PerturbationConfig:
    enabled: bool
    global_seed: int
    move_temperature_min: float
    move_temperature_max: float


def setup_game(engine: GtpEngine) -> None:
    engine.cmd("boardsize 19")
    engine.cmd("komi 6.5")
    # Keep rules fixed across all games to make results comparable.
    try:
        engine.cmd("kata-set-rules chinese")
    except Exception:
        pass
    engine.cmd(f"kata-set-param maxVisits {engine.spec.visits}")
    try:
        engine.cmd("kata-set-param reportAnalysisWinratesAs BLACK")
    except Exception:
        pass
    engine.cmd("clear_board")


def apply_perturbation_for_game(
    engine: GtpEngine, game_rng: random.Random, perturb_cfg: PerturbationConfig
) -> dict:
    if not perturb_cfg.enabled:
        return {"seed": None, "chosen_move_temperature": 0.0}

    # Give each engine independent randomness per game to avoid deterministic repeats.
    engine_seed = game_rng.randint(1, 2_147_483_647)
    move_temp = game_rng.uniform(
        perturb_cfg.move_temperature_min, perturb_cfg.move_temperature_max
    )

    # Best effort: if a parameter is unsupported by the current engine build,
    # do not fail the benchmark run.
    try:
        engine.cmd(f"kata-set-param searchRandSeed {engine_seed}")
    except Exception:
        pass
    try:
        engine.cmd(f"kata-set-param chosenMoveTemperature {move_temp:.4f}")
    except Exception:
        pass
    try:
        engine.cmd(f"kata-set-param chosenMoveTemperatureEarly {move_temp:.4f}")
    except Exception:
        pass

    return {
        "seed": engine_seed,
        "chosen_move_temperature": round(move_temp, 4),
    }


def parse_search_analyze(output: str) -> str:
    move_match = _PLAY_RE.search(output)
    move = move_match.group(1).upper() if move_match else ""
    return move


def query_self_winrate(engine: GtpEngine, own_color: str) -> float | None:
    raw = engine.cmd("kata-raw-nn 0")
    white_win_match = _WHITE_WIN_RE.search(raw)
    white_loss_match = _WHITE_LOSS_RE.search(raw)
    if not white_win_match or not white_loss_match:
        return None
    white_win = float(white_win_match.group(1))
    white_loss = float(white_loss_match.group(1))
    denom = white_win + white_loss
    if denom <= 0:
        return None
    normalized_white = white_win / denom
    if own_color.upper() == "W":
        return normalized_white
    return 1.0 - normalized_white


def main() -> int:
    repo = Path("/Users/caozheng/mastergo")
    katago_bin = repo / "assets/native/ios/simulator-arm64/katago"
    config_path = repo / "tool/bench/katago_gtp_benchmark.cfg"
    b28_model = repo / "android/katagomodel/src/main/assets/models/katago/standard.bin.gz"
    b18_model = (
        repo
        / "tool/bench/models/kata1-b18c384nbt-s9996604416-d4316597426.bin.gz"
    )

    if not katago_bin.exists():
        raise FileNotFoundError(f"KataGo binary not found: {katago_bin}")
    if not b28_model.exists():
        raise FileNotFoundError(f"B28 model not found: {b28_model}")
    if not b18_model.exists():
        raise FileNotFoundError(f"B18 model not found: {b18_model}")

    b28 = EngineSpec(name="b28_v2", model_path=b28_model, visits=2)
    b18 = EngineSpec(name="b18_v10", model_path=b18_model, visits=2)
    perturb_cfg = PerturbationConfig(
        enabled=True,
        global_seed=int(time.time()),
        move_temperature_min=0.2,
        move_temperature_max=0.6,
    )

    engines = {
        b28.name: GtpEngine(katago_bin, config_path, b28),
        b18.name: GtpEngine(katago_bin, config_path, b18),
    }

    result_dir = repo / "tool/bench/results"
    result_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = result_dir / f"b18_vs_b28_moves_{stamp}.csv"
    json_path = result_dir / f"b18_vs_b28_summary_{stamp}.json"
    live_status_path = result_dir / f"b18_vs_b28_live_status_{stamp}.json"
    print(
        f"[RUN] moves_csv={csv_path} summary_json={json_path} live_status_json={live_status_path}",
        flush=True,
    )

    moves_rows: list[dict] = []
    games_summary: list[dict] = []
    totals = {b28.name: {"wins": 0, "moves": 0, "time_ms": 0.0}, b18.name: {"wins": 0, "moves": 0, "time_ms": 0.0}}

    try:
        for game_index in range(10):
            black = b28.name if game_index < 5 else b18.name
            white = b18.name if black == b28.name else b28.name
            color_of = {black: "B", white: "W"}
            # Restart both engines each game to clear search/NN caches and avoid game N copying game 1.
            for e in engines.values():
                e.close()
            engines = {
                b28.name: GtpEngine(katago_bin, config_path, b28),
                b18.name: GtpEngine(katago_bin, config_path, b18),
            }
            game_rng = random.Random(perturb_cfg.global_seed + game_index)
            game_perturb = {}
            for e in engines.values():
                setup_game(e)
                game_perturb[e.spec.name] = apply_perturbation_for_game(
                    e, game_rng, perturb_cfg
                )
            print(
                f"[GAME-START] game={game_index + 1}/10 black={black} white={white}",
                flush=True,
            )

            to_move = "B"
            pass_count = 0
            winner = ""
            win_reason = ""
            final_score = ""
            move_no = 0
            game_time = {b28.name: 0.0, b18.name: 0.0}
            game_moves = {b28.name: 0, b18.name: 0}

            while move_no < 500:
                player = black if to_move == "B" else white
                opponent = white if player == black else black
                color = "b" if to_move == "B" else "w"

                self_wr_before = query_self_winrate(engines[player], color_of[player])
                opp_wr_before = query_self_winrate(engines[opponent], color_of[opponent])

                if move_no >= 50 and self_wr_before is not None and self_wr_before < 0.03:
                    move_clean = "RESIGN"
                    elapsed_ms = 0.0
                    move_no += 1
                    lowered = "resign"
                    winner = opponent
                    win_reason = "auto_resign_below_3pct_after_50"
                    game_moves[player] += 1
                    totals[player]["moves"] += 1
                    moves_rows.append(
                        {
                            "game": game_index + 1,
                            "move_no": move_no,
                            "color": to_move,
                            "player": player,
                            "move": move_clean,
                            "elapsed_ms": round(elapsed_ms, 3),
                            "self_winrate": round(self_wr_before * 100, 3) if self_wr_before is not None else None,
                            "opp_self_winrate": round(opp_wr_before * 100, 3) if opp_wr_before is not None else None,
                            "auto_resign": True,
                        }
                    )
                    log_line = (
                        f"[MOVE] game={game_index + 1}/10 black={black} white={white} "
                        f"move_no={move_no} player={player} player_total_ms={game_time[player]:.1f} "
                        f"move=RESIGN self_wr={(self_wr_before*100):.2f}% "
                        f"opp_wr={(opp_wr_before*100):.2f}%"
                        if (self_wr_before is not None and opp_wr_before is not None)
                        else f"[MOVE] game={game_index + 1}/10 black={black} white={white} "
                        f"move_no={move_no} player={player} player_total_ms={game_time[player]:.1f} move=RESIGN"
                    )
                    print(log_line, flush=True)
                    live_status = {
                        "game": game_index + 1,
                        "black": black,
                        "white": white,
                        "move_no": move_no,
                        "player": player,
                        "player_total_ms": round(game_time[player], 3),
                        "move": "RESIGN",
                        "self_winrate_pct": round(self_wr_before * 100, 3) if self_wr_before is not None else None,
                        "opponent_self_winrate_pct": round(opp_wr_before * 100, 3) if opp_wr_before is not None else None,
                        "timestamp": datetime.now().isoformat(timespec="seconds"),
                    }
                    live_status_path.write_text(
                        json.dumps(live_status, ensure_ascii=False, indent=2),
                        encoding="utf-8",
                    )
                    break

                t0 = time.perf_counter()
                analyze_output = engines[player].cmd(f"kata-search_analyze {color}")
                elapsed_ms = (time.perf_counter() - t0) * 1000.0
                move_clean = parse_search_analyze(analyze_output)
                if not move_clean:
                    raise RuntimeError(
                        f"Could not parse move from analyze output for {player}: {analyze_output}"
                    )
                move_no += 1
                game_time[player] += elapsed_ms
                game_moves[player] += 1
                totals[player]["time_ms"] += elapsed_ms
                totals[player]["moves"] += 1

                # Use one canonical source for winrate direction (kata-raw-nn).
                self_wr = self_wr_before

                moves_rows.append(
                    {
                        "game": game_index + 1,
                        "move_no": move_no,
                        "color": to_move,
                        "player": player,
                        "move": move_clean,
                        "elapsed_ms": round(elapsed_ms, 3),
                        "self_winrate": round(self_wr * 100, 3) if self_wr is not None else None,
                        "opp_self_winrate": round(opp_wr_before * 100, 3) if opp_wr_before is not None else None,
                        "auto_resign": False,
                    }
                )
                log_line = (
                    f"[MOVE] game={game_index + 1}/10 black={black} white={white} "
                    f"move_no={move_no} player={player} player_total_ms={game_time[player]:.1f} "
                    f"move={move_clean} self_wr={(self_wr*100):.2f}% opp_wr={(opp_wr_before*100):.2f}%"
                    if (self_wr is not None and opp_wr_before is not None)
                    else f"[MOVE] game={game_index + 1}/10 black={black} white={white} "
                    f"move_no={move_no} player={player} player_total_ms={game_time[player]:.1f} move={move_clean}"
                )
                print(log_line, flush=True)
                live_status = {
                    "game": game_index + 1,
                    "black": black,
                    "white": white,
                    "move_no": move_no,
                    "player": player,
                    "player_total_ms": round(game_time[player], 3),
                    "move": move_clean,
                    "self_winrate_pct": round(self_wr * 100, 3) if self_wr is not None else None,
                    "opponent_self_winrate_pct": round(opp_wr_before * 100, 3) if opp_wr_before is not None else None,
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                }
                live_status_path.write_text(
                    json.dumps(live_status, ensure_ascii=False, indent=2),
                    encoding="utf-8",
                )

                lowered = move_clean.lower()
                if lowered == "resign":
                    winner = opponent
                    win_reason = "resign"
                    break

                for target in (player, opponent):
                    try:
                        engines[target].cmd(f"play {color} {move_clean}")
                    except RuntimeError as exc:
                        # Some KataGo commands may already apply the move internally.
                        if target == player and "illegal move" in str(exc).lower():
                            pass
                        else:
                            raise

                if lowered == "pass":
                    pass_count += 1
                    if pass_count >= 2:
                        final_score = engines[player].cmd("final_score")
                        if final_score.startswith("B+"):
                            winner = black
                        elif final_score.startswith("W+"):
                            winner = white
                        else:
                            winner = ""
                        win_reason = f"final_score:{final_score}"
                        break
                else:
                    pass_count = 0

                to_move = "W" if to_move == "B" else "B"

            if not winner:
                final_score = engines[black].cmd("final_score")
                if final_score.startswith("B+"):
                    winner = black
                elif final_score.startswith("W+"):
                    winner = white
                win_reason = f"max_moves:{final_score}"

            totals[winner]["wins"] += 1
            games_summary.append(
                {
                    "game": game_index + 1,
                    "black": black,
                    "white": white,
                    "winner": winner,
                    "reason": win_reason,
                    "moves": move_no,
                    "avg_ms_black": round(game_time[black] / max(1, game_moves[black]), 3),
                    "avg_ms_white": round(game_time[white] / max(1, game_moves[white]), 3),
                    "perturbation": game_perturb,
                }
            )
            print(
                f"[GAME-END] game={game_index + 1}/10 winner={winner} reason={win_reason} moves={move_no}",
                flush=True,
            )

    finally:
        for e in engines.values():
            e.close()

    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "game",
                "move_no",
                "color",
                "player",
                "move",
                "elapsed_ms",
                "self_winrate",
                "opp_self_winrate",
                "auto_resign",
            ],
        )
        writer.writeheader()
        writer.writerows(moves_rows)

    summary = {
        "config": {
            "board_size": 19,
            "komi": 6.5,
            "games": 10,
            "black_assignment": "b28 first 5 games, b18 next 5 games",
            "models": {
                b28.name: {"path": str(b28.model_path), "visits": b28.visits},
                b18.name: {"path": str(b18.model_path), "visits": b18.visits},
            },
            "perturbation": {
                "enabled": perturb_cfg.enabled,
                "global_seed": perturb_cfg.global_seed,
                "move_temperature_min": perturb_cfg.move_temperature_min,
                "move_temperature_max": perturb_cfg.move_temperature_max,
            },
        },
        "games": games_summary,
        "totals": {
            k: {
                "wins": v["wins"],
                "moves": v["moves"],
                "avg_move_ms": round(v["time_ms"] / max(1, v["moves"]), 3),
            }
            for k, v in totals.items()
        },
        "files": {
            "moves_csv": str(csv_path),
            "summary_json": str(json_path),
            "live_status_json": str(live_status_path),
        },
    }
    with json_path.open("w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

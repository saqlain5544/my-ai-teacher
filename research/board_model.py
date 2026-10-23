#!/usr/bin/env python3
"""Reference semantics for a mentor 'course board' (not app code).

Run: python3 research/board_model.py
It exercises the invariants the report argues for: one focus card, a parked lane
for detours, evidence-gated completion, stable ids, a revision, and a compact
state header that is cheap enough to inject at the tail of every request.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from typing import Optional

LANES = ("backlog", "doing", "review", "done", "parked")


class BoardError(Exception):
    pass


@dataclass
class Card:
    id: str
    title: str
    lane: str = "backlog"
    next: Optional[str] = None
    objectives: list[str] = field(default_factory=list)
    evidence: list[str] = field(default_factory=list)
    after: list[str] = field(default_factory=list)
    note: Optional[str] = None
    parked_reason: Optional[str] = None


@dataclass
class Board:
    goal: str
    subject: str = "Calculus I"
    deadline: Optional[date] = None
    cards: list[Card] = field(default_factory=list)
    focus_id: Optional[str] = None
    open_loop: Optional[str] = None
    watch: Optional[str] = None
    revision: int = 0
    log: list[str] = field(default_factory=list)

    # -- reads ---------------------------------------------------------------
    def card(self, cid: str) -> Card:
        for c in self.cards:
            if c.id == cid:
                return c
        raise BoardError(f"unknown card {cid}")

    @property
    def focus(self) -> Optional[Card]:
        return self.card(self.focus_id) if self.focus_id else None

    def lane(self, name: str) -> list[Card]:
        return [c for c in self.cards if c.lane == name]

    # -- writes --------------------------------------------------------------
    def _touch(self, event: str) -> None:
        self.revision += 1
        self.log.append(f"r{self.revision} {event}")
        if len(self.log) > 200:
            self.log = self.log[-200:]

    def add(self, title: str, *, next: Optional[str] = None, objectives: Optional[list[str]] = None,
            after: Optional[list[str]] = None, lane: str = "backlog", note: Optional[str] = None) -> Card:
        assert lane in LANES
        cid = f"c{len(self.cards) + 1}"
        c = Card(cid, title, lane, next, objectives or [], [], after or [], note=note)
        self.cards.append(c)
        self._touch(f"add {cid} {title!r}")
        return c

    def start(self, cid: str) -> Card:
        c = self.card(cid)
        if c.lane == "done":
            raise BoardError("a done card must be reopened first")
        if self.focus_id and self.focus_id != cid:
            raise BoardError(f"WIP=1: {self.focus_id} is doing; park or complete it first")
        c.lane = "doing"
        c.parked_reason = None
        self.focus_id = cid
        self._touch(f"start {cid}")
        return c

    def park(self, cid: str, reason: str) -> Card:
        if not reason.strip():
            raise BoardError("parking needs a reason (what the detour was and why it is deferred)")
        c = self.card(cid)
        if c.lane == "done":
            raise BoardError("cannot park a done card")
        c.lane = "parked"
        c.parked_reason = reason
        if self.focus_id == cid:
            self.focus_id = None
        self._touch(f"park {cid}: {reason}")
        return c

    def resume(self, cid: str) -> Card:
        c = self.card(cid)
        if c.lane != "parked":
            raise BoardError("only parked cards resume")
        return self.start(cid)

    def complete(self, cid: str, evidence: str) -> Card:
        if not evidence.strip():
            raise BoardError("completion needs evidence (a quiz score, an exercise pass, a correct explanation)")
        c = self.card(cid)
        c.lane = "done"
        c.evidence.append(evidence)
        if self.focus_id == cid:
            self.focus_id = None
        self._touch(f"done {cid}: {evidence}")
        return c

    def next_action(self, n: int = 2) -> list[Card]:
        order = {c.id: i for i, c in enumerate(self.cards)}
        ready = [c for c in self.cards if c.lane in ("backlog", "review")
                 and all(self.card(a).lane == "done" for a in c.after)]
        if ready:
            return sorted(ready, key=lambda c: order[c.id])[:n]
        # Nothing is unblocked yet: show what follows the focus, with its blocker.
        blocked = [c for c in self.cards if c.lane in ("backlog", "review") and c.after]
        return sorted(blocked, key=lambda c: order[c.id])[:n]

    # -- render --------------------------------------------------------------
    def header(self, *, max_chars: int = 1_200) -> str:
        f = self.focus
        if not f:
            raise BoardError("a header needs a focus card")
        days = (self.deadline - date.today()).days if self.deadline else None
        when = f" · final in {days} days" if days is not None and days >= 0 else ""
        lines = [
            f'<lesson_state rev="{self.revision}" source="app">',
            f"Course: {self.subject} — {self.goal}{when}",
            f"Focus: {f.id} {f.title} (doing)" + (f" — {f.note}" if f.note else ""),
            f"Next: {f.next or 'choose the next concrete action'}",
        ]
        nxt = self.next_action(2)
        if nxt:
            lines.append("Then: " + " · ".join(
                f"{c.id} {c.title}" + (f" (after {', '.join(c.after)})" if any(self.card(a).lane != "done" for a in c.after) else "")
                for c in nxt))
        parked = self.lane("parked")
        if parked:
            lines.append(f"Parked ({len(parked)}): " + "; ".join(c.title for c in parked[:4]))
        if self.open_loop:
            lines.append(f"Open loop: {self.open_loop}")
        if self.watch:
            lines.append(f"Watch: {self.watch}")
        ev = [e for c in self.cards for e in c.evidence]
        if ev:
            lines.append("Evidence: " + "; ".join(ev[-3:]))
        # Usage rules live once in the system prompt, not in every header: the header is data, not instructions.
        lines.append("</lesson_state>")
        s = "\n".join(lines)
        return s if len(s) <= max_chars else s[: max_chars - 20] + "\n…[state clipped]…\n</lesson_state>"

    def full(self) -> str:
        out = [f"# {self.subject} — {self.goal}", f"Revision {self.revision}", ""]
        for lane in LANES:
            cs = self.lane(lane)
            if not cs:
                continue
            out.append(f"## {lane} ({len(cs)})")
            for c in cs:
                line = f"- {c.id} {c.title}"
                if c.next:
                    line += f" — next: {c.next}"
                if c.evidence:
                    line += f" — evidence: {'; '.join(c.evidence)}"
                if c.parked_reason:
                    line += f" — parked: {c.parked_reason}"
                out.append(line)
            out.append("")
        return "\n".join(out).strip()


def tokens(s: str) -> int:
    """Same approximation as the app's ContextPolicy (chars / 4)."""
    return len(s) // 4


def demo() -> None:
    b = Board("be ready for the final", deadline=date.fromordinal(date.today().toordinal() + 12))
    b.add("Limits and continuity", next="three one-sided-limit problems, then a continuity check",
          objectives=["graphical limits", "one-sided limits", "continuity"], lane="doing")
    b.focus_id = "c1"
    b.add("Derivatives", after=["c1"], objectives=["rules", "chain rule"])
    b.add("Applications", after=["c2"], objectives=["optimization", "related rates"])
    b.add("Review: one-sided limits", lane="review")
    b.add("Why does 0.999… equal 1?", lane="parked", note="learner tangent, answered; return if limits come up again")
    b.open_loop = "awaiting the learner's attempt at lim x→2⁻ |x-2|/(x-2)"
    b.watch = "one-sided limits (2 misses); hint rung: targeted hint"

    h = b.header()
    f = b.full()
    print("HEADER\n" + h + "\n")
    print(f"header: {len(h)} chars ≈ {tokens(h)} tokens")
    print(f"full board: {len(f)} chars ≈ {tokens(f)} tokens ({len(b.cards)} cards)")
    big = Board("a 30-card course")
    for i in range(1, 31):
        big.add(f"Module {i}", next=f"one concrete action for module {i}")
    big.focus_id = "c1"; big.card("c1").lane = "doing"
    bh, bf = big.header(), big.full()
    print(f"30-card header: {len(bh)} chars ≈ {tokens(bh)} tokens; full: {len(bf)} chars ≈ {tokens(bf)} tokens")
    print(f"log entries: {len(b.log)}; revision: {b.revision}")

    # Invariants
    try:
        b.start("c2")
        raise AssertionError("WIP=1 was not enforced")
    except BoardError as e:
        print("WIP check:", e)
    try:
        b.complete("c1", "")
        raise AssertionError("evidence-free completion was accepted")
    except BoardError as e:
        print("evidence check:", e)

    b.complete("c1", "one-sided limits: 3/3 unaided, including a jump discontinuity")
    b.start("c2")
    assert b.focus_id == "c2"
    print(f"after completion/start: focus={b.focus_id}, revision={b.revision}")
    assert tokens(b.header()) < 200, "header should stay well under 200 tokens"


if __name__ == "__main__":
    demo()

"""Implementation of Lane W's helpers."""

impl age_in_days(meta: str) -> int {
    if not meta {
        return -1;
    }
    raw = meta.strip().lower();
    # Compact form first: LinkedIn's "3d", "2w", "5mo", "18h".
    digits = "";
    for ch in raw {
        if ch.isdigit() {
            digits += ch;
        } else {
            break;
        }
    }
    if not digits {
        return -1;
    }
    n = int(digits);
    rest = raw[len(digits):].strip();
    if rest.startswith("h") or "hour" in rest {
        return 0;
    }
    if rest.startswith("d") or "day" in rest {
        return n;
    }
    if rest.startswith("w") or "week" in rest {
        return n * 7;
    }
    if rest.startswith("mo") or "month" in rest {
        return n * 30;
    }
    if rest.startswith("y") or "year" in rest {
        return n * 365;
    }
    return -1;
}


impl founder_of(lane: Lane) -> Founder | None {
    # Lane <- HasLane <- ResearchRun <- Runs <- Founder
    runs = [lane <-:HasLane:<-];
    if not runs {
        return None;
    }
    founders = [runs[0] <-:Runs:<-];
    if not founders {
        return None;
    }
    return founders[0];
}


impl LaneW.narrate(here: Lane, sentence: str, kind: ReasoningKind) {
    self.seq += 1;
    r = Reasoning(t=time.time(), sentence=sentence, kind=kind);
    here +>:Emitted(seq=self.seq):+> r;
}


impl LaneW.attach_evidence(
    p: Prospect, quote: str, kind: EvidenceKind, url: str, recency: int
) -> bool {
    cleaned = quote.strip();
    if not cleaned {
        return False;
    }
    p +>:HasEvidence(lane=LaneId.W, confidence=1.0):+> Evidence(
        source=EvidenceSource.LINKEDIN,
        quote=cleaned,
        url=url,
        kind=kind,
        recency_days=recency
    );
    self.evidence_written += 1;
    return True;
}

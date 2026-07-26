"""Rehearsal seeding - REHEARSAL AND VERIFICATION ONLY.

This module exists so the conversion half of the pipeline (compose, send,
reply, call, book) can be exercised end to end without waiting on a full
six-minute research run, and so the demo can be rehearsed on the venue wifi
before it matters.

It is NOT part of the product path. Nothing here is invented evidence: the
caller must supply the quote and the artifact, because a seeded prospect with
fabricated evidence would produce an email that looks grounded and is not -
exactly the failure this system exists to prevent. The confirm flag is there so
this can never be triggered by accident against a live graph.
"""

import time;

import from contracts { EvidenceSource, EvidenceKind, EmailSource, CompletenessTier, LaneId }
import from schema {
    Founder, Prospect, Evidence, GithubProfile, LinkedinProfile,
    HasEvidence, Identity, HasWarmLead
}
import from contracts { IdentityTier }
import from svc { cfg }


"""Seed one real, consenting human plus the evidence we genuinely hold on them.

Returns the prospect jid so a rehearsal script can drive the rest of the chain.
"""
walker:pub SeedRehearsalProspect {
    has confirm: str = "";
    has name: str = "";
    has preferred_name: str = "";
    has email: str = "";
    has handle: str = "";
    has headline: str = "";
    has company: str = "";
    has linkedin_quote: str = "";
    has github_artifact: str = "";
    has github_login: str = "";
    has score: float = 0.94;
    has score_pre_crosslink: float = 0.71;
    has reports: list[dict] = [];

    can seed with Root entry {
        if self.confirm != "rehearsal" {
            raise ValueError(
                "SeedRehearsalProspect writes test data into the live graph and will not "
                + "run unless you pass confirm='rehearsal'. Use it for rehearsal and "
                + "verification only - never as part of a demo run."
            );
        }
        if not self.linkedin_quote and not self.github_artifact {
            raise ValueError(
                "refusing to seed a prospect with no evidence: supply linkedin_quote "
                + "and/or github_artifact. Seeding an evidence-free prospect would let "
                + "ComposeOutreach appear to work while producing a generic email."
            );
        }

        founders = [root --> [?:Founder]];
        founder: Founder | None = None;
        if founders {
            founder = founders[0];
        } else {
            founder = root ++> Founder(
                name=cfg("FOUNDER_NAME", "Elijah Umana"),
                email=cfg("FOUNDER_EMAIL", ""),
                product_summary=cfg(
                    "FOUNDER_NEEDS",
                    "three beta testers this week who have actually felt this problem"
                ),
                one_liner=cfg(
                    "FOUNDER_ONE_LINER",
                    "TRACTION finds the handful of people who already described your problem in public, then emails, calls and books them."
                )
            );
        }

        target_name = self.name if self.name else cfg("TEAMMATE_NAME", "");
        target_email = self.email if self.email else cfg("TEAMMATE_EMAIL", "");
        if not target_name or not target_email {
            raise ValueError(
                "SeedRehearsalProspect needs a name and an email - pass them explicitly "
                + "or set TEAMMATE_NAME and TEAMMATE_EMAIL in .env"
            );
        }

        # What she is actually called, which is not what her profile says.
        called = self.preferred_name if self.preferred_name else cfg("TEAMMATE_PREFERRED_NAME", "");
        prospect = root ++> Prospect(
            name=target_name,
            preferred_name=called,
            handle=self.handle if self.handle else target_email.split("@")[0],
            headline=self.headline,
            company=self.company,
            email=target_email,
            email_source=EmailSource.PROVIDED,
            tier=CompletenessTier.S,
            score=self.score,
            score_pre_crosslink=self.score_pre_crosslink
        );
        if founder is not None {
            founder +>:HasWarmLead(note="rehearsal warm lead"):+> prospect;
        }

        made: list[str] = [];
        if self.linkedin_quote {
            prospect +>:HasEvidence(lane=LaneId.A, confidence=0.9):+> Evidence(
                source=EvidenceSource.LINKEDIN,
                quote=self.linkedin_quote,
                kind=EvidenceKind.COMMENT,
                recency_days=3
            );
            made.append("linkedin");
        }
        if self.github_artifact {
            prospect +>:HasEvidence(lane=LaneId.D, confidence=0.9):+> Evidence(
                source=EvidenceSource.GITHUB,
                quote=self.github_artifact,
                kind=EvidenceKind.REPO,
                recency_days=9
            );
            made.append("github");
        }
        if self.github_login {
            prospect +>:Identity(tier=IdentityTier.VERIFIED, basis="rehearsal seed", confidence=1.0):+> GithubProfile(
                login=self.github_login,
                name=target_name,
                top_repo=self.github_artifact,
                url=f"https://github.com/{self.github_login}"
            );
        }

        report {
            "ok": True,
            "prospect_id": jid(prospect),
            "name": prospect.name,
            "email": prospect.email,
            "evidence": made,
            "seeded_at": time.time()
        };
        disengage;
    }
}

"""Graph walkers, deterministic demo adapters, and typed public endpoints."""

import from .domain {
    ProductUnderstanding,
    PersonaView,
    ProspectView,
    ActivityView,
    InsightView,
    WorkspaceView,
    TractionEntity,
    Founder,
    Product,
    ProductArtifact,
    ProductHypothesis,
    TargetUser,
    PainSignal,
    Prospect,
    SourceProfile,
    OutreachDraftNode,
    OutreachThread,
    ExternalActivity,
    Meeting,
    Interview,
    Insight,
    OwnsProduct,
    IncludesArtifact,
    SuggestsHypothesis,
    TargetsUser,
    SupportedBySignal,
    RevealsProspect,
    ObservedAt,
    PromptsOutreach,
    OpensThread,
    LogsActivity,
    BooksMeeting,
    CapturesInterview,
    ProducesInsight,
    RevisesHypothesis
}

def _founder() -> Founder | None {
    founders = [root-->[?:Founder]];
    return founders[0] if founders else None;
}

def _product() -> Product | None {
    founder = _founder();
    if founder is not None {
        products = [founder->:OwnsProduct:->];
        return products[0] if products else None;
    }
    return None;
}

def _understanding(product: Product) -> ProductUnderstanding {
    return ProductUnderstanding(
        product=product.description,
        job=product.job,
        audience=product.audience,
        moment=product.moment,
        alternative=product.alternative,
        difference=product.difference,
        learning_goal=product.learning_goal,
        concepts=product.concepts
    );
}

def _persona_view(persona: TargetUser) -> PersonaView {
    return PersonaView(
        id=jid(persona),
        title=persona.title,
        description=persona.description,
        pain=persona.pain,
        signal=persona.signal,
        research_goal=persona.research_goal,
        source_plan=persona.source_plan,
        approved=persona.approved
    );
}

def _prospect_view(prospect: Prospect) -> ProspectView {
    profiles = [prospect->:ObservedAt:->];
    drafts = [prospect->:PromptsOutreach:->];
    source = profiles[0] if profiles else None;
    draft = drafts[0] if drafts else None;
    return ProspectView(
        id=jid(prospect),
        name=prospect.name,
        initials=prospect.initials,
        role=prospect.role,
        organization=prospect.organization,
        email=prospect.email,
        phone=prospect.phone,
        location=prospect.location,
        source=source.source if source is not None else "",
        profile_url=source.profile_url if source is not None else "",
        evidence_url=source.evidence_url if source is not None else "",
        evidence=source.excerpt if source is not None else "",
        evidence_date=source.published_at if source is not None else "",
        why_useful=prospect.why_useful,
        research_question=prospect.research_question,
        assumption_challenged=prospect.assumption_challenged,
        confidence=prospect.confidence,
        status=prospect.status,
        draft_subject=draft.subject if draft is not None else "",
        draft_body=draft.body if draft is not None else ""
    );
}

def _activity_view(activity: ExternalActivity) -> ActivityView {
    return ActivityView(
        id=jid(activity),
        timestamp=activity.timestamp,
        channel=activity.channel,
        activity_type=activity.activity_type,
        identity=activity.identity,
        state=activity.state,
        label=activity.label,
        link_label=activity.link_label,
        external_url=activity.external_url,
        prospect_name=activity.prospect_name,
        hypothesis=activity.hypothesis,
        transcript_title=activity.transcript_title,
        transcript=activity.transcript,
        learnable=activity.learnable,
        is_demo=activity.is_demo
    );
}

def _insight_view(insight: Insight) -> InsightView {
    return InsightView(
        id=jid(insight),
        label=insight.label,
        detail=insight.detail,
        evidence=insight.evidence,
        impact=insight.impact
    );
}

def _workspace() -> WorkspaceView {
    founder = _founder();
    product = _product();
    artifact_names: list[str] = [];
    personas: list[PersonaView] = [];
    prospects: list[ProspectView] = [];
    activities: list[ActivityView] = [];
    insights: list[InsightView] = [];
    version = 1;
    product_description = "";
    product_understanding: ProductUnderstanding | None = None;
    understanding_confirmed = False;
    understanding_note = "";
    persona_note = "";

    if product is not None {
        product_description = product.description;
        product_understanding = _understanding(product);
        understanding_confirmed = product.understanding_confirmed;
        understanding_note = product.founder_note;
        artifact_names = [a.name for a in [product->:IncludesArtifact:->]];
        hypotheses = [product->:SuggestsHypothesis:->];
        for hypothesis in hypotheses {
            if hypothesis.founder_note {
                persona_note = hypothesis.founder_note;
            }
            if hypothesis.version > version {
                version = hypothesis.version;
            }
            for persona in [hypothesis->:TargetsUser:->] {
                personas.append(_persona_view(persona));
            }
            for signal in [hypothesis->:SupportedBySignal:->] {
                for prospect in [signal->:RevealsProspect:->] {
                    prospects.append(_prospect_view(prospect));
                    for draft in [prospect->:PromptsOutreach:->] {
                        for thread in [draft->:OpensThread:->] {
                            for activity in [thread->:LogsActivity:->] {
                                activities.append(_activity_view(activity));
                            }
                            for meeting in [thread->:BooksMeeting:->] {
                                for interview in [meeting->:CapturesInterview:->] {
                                    activities.append(
                                        ActivityView(
                                            id=jid(interview),
                                            timestamp=interview.completed_at,
                                            channel="Zoom",
                                            activity_type="meeting",
                                            identity=(
                                                founder.name
                                                if founder is not None
                                                else "Becky Zhu"
                                            ) + " + Traction",
                                            state="Completed",
                                            label="Research meeting completed",
                                            link_label="Read transcript",
                                            external_url="",
                                            prospect_name=prospect.name,
                                            hypothesis=prospect.assumption_challenged,
                                            transcript_title="Research meeting transcript",
                                            transcript=interview.transcript_excerpt,
                                            learnable=True,
                                            is_demo=True
                                        )
                                    );
                                    for insight in [interview->:ProducesInsight:->] {
                                        insights.append(_insight_view(insight));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return WorkspaceView(
        founder_name=founder.name if founder is not None else "Becky Zhu",
        founder_email=founder.email if founder is not None else "becky@traction.ai",
        company=founder.company if founder is not None else "Traction",
        gmail_connected=founder.gmail_connected if founder is not None else True,
        calendar_connected=founder.calendar_connected if founder is not None else True,
        zoom_connected=founder.zoom_connected if founder is not None else True,
        product_description=product_description,
        understanding=product_understanding,
        understanding_confirmed=understanding_confirmed,
        understanding_note=understanding_note,
        artifact_names=artifact_names,
        personas=personas,
        persona_note=persona_note,
        prospects=prospects,
        activities=activities,
        insights=insights,
        hypothesis_version=version
    );
}

walker UnderstandProduct {
    has reports: list[ProductUnderstanding] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can follow with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can explain with Product entry {
        report _understanding(here);
    }
}

walker IngestProductArtifact {
    has artifact_type: str,
        name: str,
        external_url: str = "",
        reports: list[ProductArtifact] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can follow with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can ingest with Product entry {
        artifact = here +>:IncludesArtifact:+> ProductArtifact(
            artifact_type=self.artifact_type,
            name=self.name,
            external_url=self.external_url,
            adapter="Demo"
        );
        report artifact;
        disengage;
    }
}

walker ExtractProductAssumptions {
    has reports: list[ProductHypothesis] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can follow with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can extract with Product entry {
        existing = [here->:SuggestsHypothesis:->];
        if existing {
            report existing[0];
            disengage;
        }
        hypothesis = here +>:SuggestsHypothesis:+> ProductHypothesis(
            title="Connection quality over contact volume",
            statement="Travelers value trusted, low-pressure introductions to locals more than a large directory of recommendations.",
            status="active",
            version=1
        );
        report hypothesis;
        disengage;
    }
}

walker ConfirmFounderUnderstanding {
    has job: str,
        audience: str,
        moment: str,
        alternative: str,
        difference: str,
        learning_goal: str,
        concepts: list[str],
        founder_note: str = "",
        reports: list[ProductUnderstanding] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can follow with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can confirm with Product entry {
        here.job = self.job;
        here.audience = self.audience;
        here.moment = self.moment;
        here.alternative = self.alternative;
        here.difference = self.difference;
        here.learning_goal = self.learning_goal;
        here.concepts = self.concepts;
        here.founder_note = self.founder_note;
        here.understanding_confirmed = True;
        report _understanding(here);
        disengage;
    }
}

walker BuildTargetPersonas {
    has founder_note: str = "",
        reports: list[TargetUser] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can follow_founder with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can follow_product with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can build with ProductHypothesis entry {
        existing = [here->:TargetsUser:->];
        if existing {
            for persona in existing {
                report persona;
            }
            disengage;
        }
        p1 = here +>:TargetsUser:+> TargetUser(
            title="New-in-town solo travelers",
            description="People arriving alone who want a human connection, not another attractions list.",
            pain="Discovery apps answer where to go but not who it would feel natural to meet.",
            signal="Posts asking how to meet locals without tours, dating apps, or networking events.",
            research_goal="Learn what makes a local introduction feel safe and non-transactional."
        );
        p2 = here +>:TargetsUser:+> TargetUser(
            title="Community-minded locals",
            description="Locals who enjoy sharing overlooked places and meeting visitors with common interests.",
            pain="Existing platforms turn local knowledge into reviews, content, or unpaid concierge work.",
            signal="Maintains local guides, contributes neighborhood lists, or organizes small meetups.",
            research_goal="Test what value exchange makes participation sustainable."
        );
        p3 = here +>:TargetsUser:+> TargetUser(
            title="Remote workers seeking belonging",
            description="People staying several weeks who want lightweight recurring social ties.",
            pain="They are too temporary for traditional communities but want more depth than tourist events.",
            signal="Builds or joins open-source nomad, coworking, or city-community projects.",
            research_goal="Separate short-term novelty from a repeatable need for belonging."
        );
        p4 = here +>:TargetsUser:+> TargetUser(
            title="Hosts of small local communities",
            description="Organizers with trusted groups who carefully manage introductions and culture.",
            pain="Broad distribution creates low-intent joins and moderation work.",
            signal="Discusses curation, trust, attendance quality, or matching in community tools.",
            research_goal="Understand which trust signals can scale without flattening community culture."
        );
        here.founder_note = self.founder_note;
        report p1;
        report p2;
        report p3;
        report p4;
    }
}

walker FindLinkedInPainSignals {
    has reports: list[Prospect] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can search with ProductHypothesis entry {
        existing: list[PainSignal] = [];
        for signal in [here->:SupportedBySignal:->[?:PainSignal]] {
            if signal.source == "LinkedIn" {
                existing.append(signal);
            }
        }
        if existing {
            for signal in existing {
                for prospect in [signal->:RevealsProspect:->] {
                    report prospect;
                }
            }
            disengage;
        }
        s1 = here +>:SupportedBySignal:+> PainSignal(
            source="LinkedIn",
            summary="Solo traveler explicitly wants local connection without a transactional tour.",
            behavior="Asked her network for alternatives to tours and dating apps.",
            intensity="High — repeated across three trips",
            recency="12 days ago",
            assumption_challenged="Travelers want in-person connection, not simply better place recommendations.",
            confidence=0.96
        );
        maya = s1 +>:RevealsProspect:+> Prospect(
            name="Maya Chen",
            initials="MC",
            role="Product designer · frequent solo traveler",
            organization="Atlas Labs · San Francisco",
            email="maya.chen@atlaslabs.example",
            phone="+1 (415) 555-0142",
            location="San Francisco, CA",
            why_useful="Maya names the exact non-transactional behavior the product hopes to enable and has tried the main alternatives.",
            research_question="What would make an introduction to a local feel safe enough to accept?",
            assumption_challenged="Trust is the binding constraint, not supply of local recommendations.",
            confidence=0.96
        );
        maya +>:ObservedAt:+> SourceProfile(
            source="LinkedIn",
            profile_url="https://www.linkedin.com/in/mayachen",
            evidence_url="https://www.linkedin.com/feed/update/urn:li:activity:demo-maya",
            excerpt="Solo travel is easy until dinner. I can find 50 ‘hidden gems,’ but not one low-pressure way to meet someone who actually lives there — without booking a tour or opening a dating app.",
            published_at="LinkedIn post · 12 days ago"
        );
        s2 = here +>:SupportedBySignal:+> PainSignal(
            source="LinkedIn",
            summary="A local community host resists broad event distribution because it lowers trust.",
            behavior="Keeps neighborhood dinners invite-only and manually vets introductions.",
            intensity="Medium-high — recurring moderation cost",
            recency="6 days ago",
            assumption_challenged="More introductions can harm the local side if curation is weak.",
            confidence=0.91
        );
        priya = s2 +>:RevealsProspect:+> Prospect(
            name="Priya Shah",
            initials="PS",
            role="Community founder",
            organization="Sunday Table · Austin",
            email="priya@sundaytable.example",
            phone="+1 (512) 555-0189",
            location="Austin, TX",
            why_useful="Priya controls a trusted local network and can explain why high-intent introductions still create social risk.",
            research_question="Which signals make a visitor feel additive rather than extractive?",
            assumption_challenged="A good match must protect local community quality, not just traveler safety.",
            confidence=0.91
        );
        priya +>:ObservedAt:+> SourceProfile(
            source="LinkedIn",
            profile_url="https://www.linkedin.com/in/priyashah",
            evidence_url="https://www.linkedin.com/feed/update/urn:li:activity:demo-priya",
            excerpt="Every event platform tells me to grow distribution. The reason our neighborhood dinners work is the opposite: careful introductions, context, and a clear reason each person belongs.",
            published_at="LinkedIn post · 6 days ago"
        );
        report maya;
        report priya;
    }
}

walker FindGitHubPainSignals {
    has reports: list[Prospect] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can search with ProductHypothesis entry {
        existing: list[PainSignal] = [];
        for signal in [here->:SupportedBySignal:->[?:PainSignal]] {
            if signal.source == "GitHub" {
                existing.append(signal);
            }
        }
        if existing {
            for signal in existing {
                for prospect in [signal->:RevealsProspect:->] {
                    report prospect;
                }
            }
            disengage;
        }
        s1 = here +>:SupportedBySignal:+> PainSignal(
            source="GitHub",
            summary="Open-source city guide maintainer needs social context, not more place data.",
            behavior="Built a contextual local guide and documented why rating systems fail.",
            intensity="High — built a workaround",
            recency="3 weeks ago",
            assumption_challenged="The valuable local knowledge is relational and situational.",
            confidence=0.94
        );
        jordan = s1 +>:RevealsProspect:+> Prospect(
            name="Jordan Lee",
            initials="JL",
            role="Open-source maintainer · remote worker",
            organization="NearHere · Brooklyn",
            email="jordan@nearhere.example",
            phone="+1 (718) 555-0176",
            location="Brooklyn, NY",
            why_useful="Jordan has already built the closest technical workaround and can pinpoint where place data stops being useful.",
            research_question="What context must travel with a local recommendation for it to create connection?",
            assumption_challenged="Matching around shared context may matter more than venue quality.",
            confidence=0.94
        );
        jordan +>:ObservedAt:+> SourceProfile(
            source="GitHub",
            profile_url="https://github.com/jordanlee",
            evidence_url="https://github.com/demo/nearhere/discussions/42",
            excerpt="The map was the easy part. People don’t need another pin — they need the story, who would enjoy it with them, and whether showing up alone will feel awkward.",
            published_at="GitHub discussion · 3 weeks ago"
        );
        s2 = here +>:SupportedBySignal:+> PainSignal(
            source="GitHub",
            summary="A meetup matching prototype failed when recommendations felt automated and context-free.",
            behavior="Archived a matching bot and published a detailed failure note.",
            intensity="High — abandoned shipped prototype",
            recency="1 month ago",
            assumption_challenged="Automation must preserve human intent and consent.",
            confidence=0.89
        );
        leo = s2 +>:RevealsProspect:+> Prospect(
            name="Leo Martins",
            initials="LM",
            role="Engineer · community tool builder",
            organization="OpenCircle · Lisbon",
            email="leo@opencircle.example",
            phone="+351 21 555 0134",
            location="Lisbon, Portugal",
            why_useful="Leo can explain a concrete product failure where efficient matching reduced trust and response quality.",
            research_question="Where should the agent stop automating and ask a human for consent?",
            assumption_challenged="A lower-volume founder-led introduction may outperform autonomous outreach.",
            confidence=0.89
        );
        leo +>:ObservedAt:+> SourceProfile(
            source="GitHub",
            profile_url="https://github.com/leomartins",
            evidence_url="https://github.com/demo/opencircle/blob/main/POSTMORTEM.md",
            excerpt="Our bot optimized match rate and accidentally removed the reason people trusted the intro. Once messages felt generated, thoughtful replies dropped to almost zero.",
            published_at="GitHub postmortem · 1 month ago"
        );
        report jordan;
        report leo;
    }
}

walker RankResearchProspects {
    has found: list[Prospect] = [],
        reports: list[list[ProspectView]] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can hypothesis_to_signal with ProductHypothesis entry {
        visit [->:SupportedBySignal:->];
    }

    can signal_to_prospect with PainSignal entry {
        visit [->:RevealsProspect:->];
    }

    can collect with Prospect entry {
        self.found.append(here);
    }

    can finish with Root exit {
        ranked = sorted(
            self.found, key=lambda (p: Prospect) { p.confidence; }, reverse=True
        );
        report [_prospect_view(p) for p in ranked];
    }
}

walker GenerateResearchQuestions {
    has reports: list[Prospect] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can hypothesis_to_signal with ProductHypothesis entry {
        visit [->:SupportedBySignal:->];
    }

    can signal_to_prospect with PainSignal entry {
        visit [->:RevealsProspect:->];
    }

    can keep with Prospect entry {
        report here;
    }
}

walker DraftFounderOutreach {
    has reports: list[OutreachDraftNode] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can hypothesis_to_signal with ProductHypothesis entry {
        visit [->:SupportedBySignal:->];
    }

    can signal_to_prospect with PainSignal entry {
        visit [->:RevealsProspect:->];
    }

    can write with Prospect entry {
        existing = [here->:PromptsOutreach:->];
        if existing {
            report existing[0];
            skip;
        }
        profiles = [here->:ObservedAt:->];
        evidence = profiles[0].excerpt if profiles else "your public note";
        body = "Hi " + here.name.split()[0] + ",\n\nI’m Becky, building a product around more human local discovery. Your note — “" + evidence + "” — challenged how I’m thinking about the problem.\n\nI’m not selling anything. Would you be open to a 25-minute research conversation about " + here.research_question.lower() + "\n\nBecky\nFounder, Traction";
        draft = here +>:PromptsOutreach:+> OutreachDraftNode(
            subject="A question about your " + profiles[0].source + " note",
            body=body,
            evidence_line=evidence,
            research_ask=here.research_question
        );
        report draft;
    }
}

walker ApproveAndSendOutreach {
    has prospect_id: str,
        revised_body: str = "",
        reports: list[ExternalActivity] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can hypothesis_to_signal with ProductHypothesis entry {
        visit [->:SupportedBySignal:->];
    }

    can signal_to_prospect with PainSignal entry {
        visit [->:RevealsProspect:->];
    }

    can send with Prospect entry {
        if jid(here) != self.prospect_id {
            skip;
        }
        drafts = [here->:PromptsOutreach:->];
        if not drafts {
            disengage;
        }
        draft = drafts[0];
        if self.revised_body.strip() {
            draft.body = self.revised_body;
        }
        draft.approved = True;
        draft.sent = True;
        here.status = "Sent";
        thread = draft +>:OpensThread:+> OutreachThread(
            channel="Gmail",
            sender_identity="Becky Zhu <becky@traction.ai>",
            state="Sent"
        );
        activity = thread +>:LogsActivity:+> ExternalActivity(
            timestamp="Today · 10:24 AM",
            channel="Gmail",
            activity_type="email",
            identity="Becky Zhu <becky@traction.ai>",
            state="Sent",
            label="Founder research email sent",
            link_label="Open in Gmail",
            external_url="https://mail.google.com/mail/u/0/#sent",
            prospect_name=here.name,
            hypothesis=here.assumption_challenged,
            is_demo=True
        );
        report activity;
        disengage;
    }
}

walker RecordExternalEvent {
    has prospect_id: str,
        channel: str,
        state: str,
        label: str,
        external_url: str,
        reports: list[ExternalActivity] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can hypothesis_to_signal with ProductHypothesis entry {
        visit [->:SupportedBySignal:->];
    }

    can signal_to_prospect with PainSignal entry {
        visit [->:RevealsProspect:->];
    }

    can record with Prospect entry {
        if jid(here) != self.prospect_id {
            skip;
        }
        drafts = [here->:PromptsOutreach:->];
        if not drafts {
            disengage;
        }
        threads = [drafts[0]->:OpensThread:->];
        if not threads {
            disengage;
        }
        activity = threads[0] +>:LogsActivity:+> ExternalActivity(
            timestamp="Today · 1:08 PM",
            channel=self.channel,
            identity="Becky Zhu <becky@traction.ai>",
            state=self.state,
            label=self.label,
            link_label="Open original",
            external_url=self.external_url,
            prospect_name=here.name,
            hypothesis=here.assumption_challenged,
            is_demo=True
        );
        report activity;
        disengage;
    }
}

walker ScheduleFounderMeeting {
    has prospect_id: str,
        reports: list[Meeting] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can hypothesis_to_signal with ProductHypothesis entry {
        visit [->:SupportedBySignal:->];
    }

    can signal_to_prospect with PainSignal entry {
        visit [->:RevealsProspect:->];
    }

    can schedule with Prospect entry {
        if jid(here) != self.prospect_id {
            skip;
        }
        drafts = [here->:PromptsOutreach:->];
        if not drafts {
            disengage;
        }
        threads = [drafts[0]->:OpensThread:->];
        if not threads {
            disengage;
        }
        here.status = "Booked";
        meeting = threads[0] +>:BooksMeeting:+> Meeting(
            starts_at="Tuesday, July 28 · 10:30 AM PT",
            calendar_url="https://calendar.google.com/calendar/u/0/r",
            zoom_url="https://zoom.us/j/1234567890",
            status="Booked"
        );
        threads[0] +>:LogsActivity:+> ExternalActivity(
            timestamp="Today · 1:04 PM",
            channel="Gmail",
            activity_type="email",
            identity="Becky Zhu <becky@traction.ai>",
            state="Replied",
            label="Interested reply received",
            link_label="Open reply",
            external_url="https://mail.google.com/mail/u/0/#inbox",
            prospect_name=here.name,
            hypothesis=here.assumption_challenged,
            is_demo=True
        );
        threads[0] +>:LogsActivity:+> ExternalActivity(
            timestamp="Today · 1:09 PM",
            channel="Phone",
            activity_type="call",
            identity="Becky Zhu <becky@traction.ai>",
            state="Completed",
            label="Interest confirmed on a 4-minute call",
            link_label="View call log",
            external_url="https://voice.google.com/u/0/calls",
            prospect_name=here.name,
            hypothesis=here.assumption_challenged,
            transcript_title="Scheduling call transcript",
            transcript="Becky: Hi Maya, thanks for calling back. I only need a minute to find a good time.\n\nMaya: Happy to help. Tuesday morning works, and I can give you about 25 minutes.\n\nBecky: Perfect—I’ll send a calendar invite and a Zoom link now.\n\nMaya: Sounds good. Looking forward to it.",
            learnable=False,
            is_demo=True
        );
        threads[0] +>:LogsActivity:+> ExternalActivity(
            timestamp="Today · 1:12 PM",
            channel="Google Calendar",
            activity_type="meeting",
            identity="Becky Zhu <becky@traction.ai>",
            state="Booked",
            label="25-minute founder research session booked",
            link_label="Open in Calendar",
            external_url=meeting.calendar_url,
            prospect_name=here.name,
            hypothesis=here.assumption_challenged,
            is_demo=True
        );
        threads[0] +>:LogsActivity:+> ExternalActivity(
            timestamp="Today · 1:12 PM",
            channel="Zoom",
            activity_type="meeting",
            identity="Becky Zhu <becky@traction.ai>",
            state="Ready",
            label="Zoom link attached to both calendars",
            link_label="Join Zoom",
            external_url=meeting.zoom_url,
            prospect_name=here.name,
            hypothesis=here.assumption_challenged,
            is_demo=True
        );
        report meeting;
        disengage;
    }
}

walker SynthesizeInterview {
    has prospect_id: str,
        reports: list[Insight] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can hypothesis_to_signal with ProductHypothesis entry {
        visit [->:SupportedBySignal:->];
    }

    can signal_to_prospect with PainSignal entry {
        visit [->:RevealsProspect:->];
    }

    can find_thread with Prospect entry {
        if jid(here) != self.prospect_id {
            skip;
        }
        drafts = [here->:PromptsOutreach:->];
        if drafts {
            visit [drafts[0]->:OpensThread:->];
        }
    }

    can find_meeting with OutreachThread entry {
        visit [->:BooksMeeting:->];
    }

    can synthesize with Meeting entry {
        existing = [here->:CapturesInterview:->];
        if existing {
            for old in [existing[0]->:ProducesInsight:->] {
                report old;
            }
            disengage;
        }
        interview = here +>:CapturesInterview:+> Interview(
            participant="Maya Chen",
            completed_at="Tuesday · 10:58 AM PT",
            transcript_excerpt="Becky: When you arrive somewhere alone, what feels hardest?\n\nMaya: I don’t need a local expert. I need one person who can make the first hour feel less anonymous.\n\nBecky: What would make you comfortable accepting that introduction?\n\nMaya: I want to know why they said yes to meeting me. Shared intent matters more than a long profile.\n\nBecky: Does a list of places help at all?\n\nMaya: It helps later. First I need to trust the person and understand what they get from the interaction too."
        );
        i1 = interview +>:ProducesInsight:+> Insight(
            label="Belonging starts with mutual intent",
            detail="The first product moment should explain why both people opted in, not lead with places or itineraries.",
            evidence="‘I want to know why they said yes to meeting me.’",
            impact="Move mutual context ahead of recommendations in the onboarding hypothesis."
        );
        i2 = interview +>:ProducesInsight:+> Insight(
            label="One warm hour beats a city directory",
            detail="The desired outcome is a less anonymous arrival, not comprehensive local discovery.",
            evidence="‘One person who can make the first hour feel less anonymous.’",
            impact="Narrow the promise from local discovery to a trusted first connection."
        );
        i3 = interview +>:ProducesInsight:+> Insight(
            label="Safety is reciprocal",
            detail="Traveler verification alone misses the local’s need to understand motivation and boundaries.",
            evidence="Maya asked what the local receives and what information they see before accepting.",
            impact="Search next for community hosts who reject low-context introductions."
        );
        report i1;
        report i2;
        report i3;
    }
}

walker UpdateProductHypothesis {
    has reports: list[ProductHypothesis] = [];

    can begin with Root entry {
        visit [-->[?:Founder]];
    }

    can founder_to_product with Founder entry {
        visit [->:OwnsProduct:->];
    }

    can product_to_hypothesis with Product entry {
        visit [->:SuggestsHypothesis:->];
    }

    can update with ProductHypothesis entry {
        here.version += 1;
        here.statement = "Travelers value one trusted, mutual-intent local connection at arrival more than broad local discovery or recommendation volume.";
        here.status = "updated from interview";
        report here;
        disengage;
    }
}

def:pub bootstrap_workspace() -> WorkspaceView {
    return _workspace();
}

def:pub reset_workspace() -> WorkspaceView {
    for entity in [root-->] {
        del entity;
    }
    return _workspace();
}

def:pub begin_product(description: str) -> WorkspaceView {
    for entity in [root-->] {
        del entity;
    }
    founder = root ++> Founder();
    founder +>:OwnsProduct:+> Product(
        description=description,
        job="Help a traveler turn local discovery into a comfortable in-person connection.",
        audience="Solo travelers and community-minded locals.",
        moment="The first hours in a new city, when recommendations are abundant but belonging is absent.",
        alternative="Tour marketplaces, dating apps, group meetups, saved maps, and asking friends for introductions.",
        difference="Mutual-intent introductions centered on people and context rather than transactions or content.",
        learning_goal="Test whether trust and reciprocal motivation are the binding constraints for both sides.",
        concepts=[
            "locals",
            "travelers",
            "solo travel",
            "non-transactional",
            "in-person",
            "local discovery"
        ]
    );
    root spawn UnderstandProduct();
    return _workspace();
}

def:pub confirm_understanding(
    job: str,
    audience: str,
    moment: str,
    alternative: str,
    difference: str,
    learning_goal: str,
    founder_note: str = ""
) -> WorkspaceView {
    root spawn ConfirmFounderUnderstanding(
        job=job,
        audience=audience,
        moment=moment,
        alternative=alternative,
        difference=difference,
        learning_goal=learning_goal,
        founder_note=founder_note,
        concepts=[
            "locals",
            "travelers",
            "solo travel",
            "non-transactional",
            "in-person",
            "local discovery"
        ]
    );
    return _workspace();
}

def:pub add_artifact(
    artifact_type: str, name: str, external_url: str
) -> WorkspaceView {
    root spawn IngestProductArtifact(
        artifact_type=artifact_type, name=name, external_url=external_url
    );
    return _workspace();
}

def:pub build_personas() -> WorkspaceView {
    root spawn ExtractProductAssumptions();
    root spawn BuildTargetPersonas();
    return _workspace();
}

def:pub save_persona_feedback(
    note: str, selected_ids: list[str] | None = None
) -> WorkspaceView {
    product = _product();
    if product is not None {
        hypotheses = [product->:SuggestsHypothesis:->];
        if hypotheses {
            hypotheses[0].founder_note = note;
            for persona in [hypotheses[0]->:TargetsUser:->] {
                persona.approved = True
                    if selected_ids is None or not selected_ids
                    else jid(persona) in selected_ids;
            }
        }
    }
    return _workspace();
}

def:pub run_signal_search() -> WorkspaceView {
    root spawn ExtractProductAssumptions();
    root spawn BuildTargetPersonas();
    root spawn FindLinkedInPainSignals();
    root spawn FindGitHubPainSignals();
    root spawn GenerateResearchQuestions();
    root spawn RankResearchProspects();
    return _workspace();
}

def:pub draft_outreach() -> WorkspaceView {
    root spawn FindLinkedInPainSignals();
    root spawn FindGitHubPainSignals();
    root spawn GenerateResearchQuestions();
    root spawn RankResearchProspects();
    root spawn DraftFounderOutreach();
    return _workspace();
}

def:pub send_outreach(prospect_id: str, revised_body: str) -> WorkspaceView {
    root spawn ApproveAndSendOutreach(
        prospect_id=prospect_id, revised_body=revised_body
    );
    return _workspace();
}

def:pub schedule_demo_meeting(prospect_id: str) -> WorkspaceView {
    root spawn ScheduleFounderMeeting(prospect_id=prospect_id);
    return _workspace();
}

def:pub synthesize_demo_interview(prospect_id: str) -> WorkspaceView {
    root spawn SynthesizeInterview(prospect_id=prospect_id);
    root spawn UpdateProductHypothesis();
    return _workspace();
}

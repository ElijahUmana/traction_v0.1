"""Wire views - the only types that cross the client/server boundary.

Split out of Becky's `becky_ui/traction/domain.jac` (kept in git history). That
file declared the objs below AND a mock graph: `node Founder`, `node Prospect`
and `node Insight` - the same three names `schema.jac` already declares.

Two modules declaring one node name produce two DISTINCT archetypes that
traversal matches BY NAME at runtime (docs/JAC_GOTCHAS.md 8d), so every
`[lane ->:Surfaced:->]` and `[root --> [?:Prospect]]` in the product would have
returned a mixture of her UI scaffolding and our researched nodes - silently,
with a clean `jac check`. Her nodes were placeholders for a standalone UI; ours
carry the real research. So the nodes and edges are gone and only the wire
views survive. Nothing else in the repo may declare an archetype either -
archetypes belong to schema.jac only.

The `sem` lines are load-bearing, not documentation: they are the prompts byLLM
reads when a field is produced by `by llm()`. Do not drop them.

CAUTION - `ProspectView` and `OutreachDraft` also exist in `contracts.jac` with
DIFFERENT shapes (contracts' carry `jid`/`tier`/`score` and the quote-provenance
fields; these carry the flat `id`/`draft_body` shape Becky's UI renders). They
are objs, not archetypes, so there is no runtime traversal hazard - but never
import both into one module, because the second import silently shadows the
first. `main.jac` takes `ProspectView`/`OutreachDraft` from `contracts` and only
`WorkspaceView` from here.
"""

obj ProductUnderstanding {
    has product: str,
        job: str,
        audience: str,
        moment: str,
        alternative: str,
        difference: str,
        learning_goal: str,
        concepts: list[str];
}

sem ProductUnderstanding.product = "A plain-language description of the product.";
sem ProductUnderstanding.job = "The human job the product helps someone complete.";
sem ProductUnderstanding.audience = "The people who feel the problem most acutely.";
sem ProductUnderstanding.moment = "The situation in which the pain is strongest.";
sem ProductUnderstanding.alternative = "The current workaround or substitute.";
sem ProductUnderstanding.difference = "What makes the product meaningfully different.";
sem ProductUnderstanding.learning_goal = "The most important risky assumption to test.";
sem ProductUnderstanding.concepts = "Concrete concepts that define the product hypothesis.";

obj PainSignalAnalysis {
    has summary: str,
        behavior: str,
        intensity: str,
        recency: str,
        assumption_challenged: str,
        confidence: float;
}

sem PainSignalAnalysis.summary = "A concise description of the observable pain signal.";
sem PainSignalAnalysis.behavior = "The behavior or workaround actually observed.";
sem PainSignalAnalysis.intensity = "How costly or urgent the signal appears.";
sem PainSignalAnalysis.recency = "How recently the evidence was expressed.";
sem PainSignalAnalysis.assumption_challenged = "The product assumption this evidence can confirm or challenge.";
sem PainSignalAnalysis.confidence = "Evidence confidence from 0.0 to 1.0.";

obj OutreachDraft {
    has subject: str,
        body: str,
        evidence_line: str,
        research_ask: str;
}

sem OutreachDraft.subject = "A short, specific email subject.";
sem OutreachDraft.body = "A brief first-person founder email grounded in the prospect's public signal.";
sem OutreachDraft.evidence_line = "The exact public signal referenced in the message.";
sem OutreachDraft.research_ask = "A non-sales research request that is easy to answer.";

obj InterviewSynthesis {
    has strongest_signal: str,
        surprise: str,
        pain_language: str,
        hypothesis_update: str,
        next_search: str;
}

sem InterviewSynthesis.strongest_signal = "The strongest behavioral evidence from the conversation.";
sem InterviewSynthesis.surprise = "What contradicted the current product hypothesis.";
sem InterviewSynthesis.pain_language = "The participant's own language for the problem.";
sem InterviewSynthesis.hypothesis_update = "A specific change to the product hypothesis.";
sem InterviewSynthesis.next_search = "Who or what evidence the agent should seek next.";

obj PersonaView {
    has id: str,
        title: str,
        description: str,
        pain: str,
        signal: str,
        research_goal: str,
        source_plan: str,
        approved: bool;
}

obj ProspectView {
    has id: str,
        name: str,
        initials: str,
        role: str,
        organization: str,
        email: str,
        phone: str,
        location: str,
        source: str,
        profile_url: str,
        evidence_url: str,
        evidence: str,
        evidence_date: str,
        why_useful: str,
        research_question: str,
        assumption_challenged: str,
        confidence: float,
        status: str,
        draft_subject: str,
        draft_body: str;
}

obj ActivityView {
    has id: str,
        timestamp: str,
        channel: str,
        activity_type: str,
        identity: str,
        state: str,
        label: str,
        link_label: str,
        external_url: str,
        prospect_name: str,
        hypothesis: str,
        transcript_title: str,
        transcript: str,
        learnable: bool,
        is_demo: bool;
}

obj InsightView {
    has id: str,
        label: str,
        detail: str,
        evidence: str,
        impact: str;
}

obj WorkspaceView {
    has founder_name: str,
        founder_email: str,
        company: str,
        gmail_connected: bool,
        calendar_connected: bool,
        zoom_connected: bool,
        product_description: str,
        understanding: ProductUnderstanding | None,
        understanding_confirmed: bool,
        understanding_note: str,
        artifact_names: list[str],
        personas: list[PersonaView],
        persona_note: str,
        prospects: list[ProspectView],
        activities: list[ActivityView],
        insights: list[InsightView],
        hypothesis_version: int;
}

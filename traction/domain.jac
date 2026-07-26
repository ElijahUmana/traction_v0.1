"""Typed graph schema and wire views for Traction."""

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

node TractionEntity {}

node Founder(TractionEntity) {
    has name: str = "Becky Zhu",
        email: str = "becky@traction.ai",
        company: str = "Traction",
        gmail_connected: bool = True,
        calendar_connected: bool = True,
        zoom_connected: bool = True;
}

node Product(TractionEntity) {
    has description: str = "",
        job: str = "",
        audience: str = "",
        moment: str = "",
        alternative: str = "",
        difference: str = "",
        learning_goal: str = "",
        concepts: list[str] = [],
        founder_note: str = "",
        understanding_confirmed: bool = False;
}

node ProductArtifact(TractionEntity) {
    has artifact_type: str = "",
        name: str = "",
        external_url: str = "",
        adapter: str = "Demo";
}

node ProductHypothesis(TractionEntity) {
    has title: str = "",
        statement: str = "",
        status: str = "proposed",
        version: int = 1,
        founder_note: str = "";
}

node TargetUser(TractionEntity) {
    has title: str = "",
        description: str = "",
        pain: str = "",
        signal: str = "",
        research_goal: str = "",
        source_plan: str = "LinkedIn + GitHub",
        approved: bool = True;
}

node PainSignal(TractionEntity) {
    has source: str = "",
        summary: str = "",
        behavior: str = "",
        intensity: str = "",
        recency: str = "",
        assumption_challenged: str = "",
        confidence: float = 0.0;
}

node Prospect(TractionEntity) {
    has name: str = "",
        initials: str = "",
        role: str = "",
        organization: str = "",
        email: str = "",
        phone: str = "",
        location: str = "",
        why_useful: str = "",
        research_question: str = "",
        assumption_challenged: str = "",
        confidence: float = 0.0,
        status: str = "Found";
}

node SourceProfile(TractionEntity) {
    has source: str = "",
        profile_url: str = "",
        evidence_url: str = "",
        excerpt: str = "",
        published_at: str = "";
}

node OutreachDraftNode(TractionEntity) {
    has subject: str = "",
        body: str = "",
        evidence_line: str = "",
        research_ask: str = "",
        approved: bool = False,
        sent: bool = False;
}

node OutreachThread(TractionEntity) {
    has channel: str = "Gmail",
        sender_identity: str = "Becky Zhu",
        state: str = "Draft";
}

node ExternalActivity(TractionEntity) {
    has timestamp: str = "",
        channel: str = "",
        activity_type: str = "general",
        identity: str = "",
        state: str = "",
        label: str = "",
        link_label: str = "",
        external_url: str = "",
        prospect_name: str = "",
        hypothesis: str = "",
        transcript_title: str = "",
        transcript: str = "",
        learnable: bool = False,
        is_demo: bool = True;
}

node Meeting(TractionEntity) {
    has starts_at: str = "",
        calendar_url: str = "",
        zoom_url: str = "",
        status: str = "Booked";
}

node Interview(TractionEntity) {
    has transcript_excerpt: str = "",
        participant: str = "",
        completed_at: str = "";
}

node Insight(TractionEntity) {
    has label: str = "",
        detail: str = "",
        evidence: str = "",
        impact: str = "";
}

edge OwnsProduct: Founder --> Product {}
edge IncludesArtifact: Product --> ProductArtifact {}
edge SuggestsHypothesis: Product --> ProductHypothesis {}
edge TargetsUser: ProductHypothesis --> TargetUser {}
edge SupportedBySignal: ProductHypothesis --> PainSignal {}
edge RevealsProspect: PainSignal --> Prospect {}
edge ObservedAt: Prospect --> SourceProfile {}
edge PromptsOutreach: Prospect --> OutreachDraftNode {}
edge OpensThread: OutreachDraftNode --> OutreachThread {}
edge LogsActivity: OutreachThread --> ExternalActivity {}
edge BooksMeeting: OutreachThread --> Meeting {}
edge CapturesInterview: Meeting --> Interview {}
edge ProducesInsight: Interview --> Insight {}
edge RevisesHypothesis: Insight --> ProductHypothesis {}

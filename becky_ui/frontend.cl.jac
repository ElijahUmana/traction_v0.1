"""Traction stateful client shell and editorial workflow UI."""

sv import from traction.domain {
    WorkspaceView,
    ProductUnderstanding,
    PersonaView,
    ProspectView,
    ActivityView,
    InsightView
}
sv import from traction.workflows {
    bootstrap_workspace,
    begin_product,
    confirm_understanding,
    add_artifact,
    build_personas,
    save_persona_feedback,
    run_signal_search,
    draft_outreach,
    send_outreach,
    schedule_demo_call,
    schedule_demo_meeting,
    synthesize_demo_interview,
    reset_workspace
}

def stage_index(phase: str) -> int {
    if phase in [
        "EMPTY",
        "MASCOT_ENTERING",
        "ANALYZING_PRODUCT",
        "ANALYZING_CONTEXT",
        "CONFIRMING_UNDERSTANDING",
        "WAITING_FOR_CHOICE",
        "REVIEWING_PERSONAS"
    ] {
        return 0;
    }
    if phase in ["SEARCHING", "REVIEWING_PROSPECTS"] {
        return 1;
    }
    if phase == "FIND_EMPTY" {
        return 1;
    }
    if phase in [
        "DRAFTING_OUTREACH",
        "WAITING_FOR_APPROVAL",
        "LEAD_LIBRARY",
        "TRACKING_EXTERNAL_ACTIVITY",
        "LIVE_AGENT_CALL",
        "CALENDAR_WORKSPACE"
    ] {
        return 2;
    }
    if phase == "REACH_EMPTY" {
        return 2;
    }
    return 3;
}

def status_tone(status: str) -> str {
    if status == "Booked" {
        return "green";
    }
    if status in ["Sent", "Call scheduled"] {
        return "blue";
    }
    return "neutral";
}

def find_prospect(workspace: WorkspaceView, prospect_id: str) -> ProspectView | None {
    for prospect in workspace.prospects {
        if prospect.id == prospect_id {
            return prospect;
        }
    }
    return workspace.prospects[0] if workspace.prospects else None;
}

async def demo_wait(milliseconds: int) -> None {
    await new(
        Promise,
        lambda (resolve: any, _reject: any) { setTimeout(
            lambda -> None { resolve.call(None, None); }, milliseconds
        ); }
    );
}

def:pub TractionApp -> JsxElement {
    has workspace: WorkspaceView | None = None,
        phase: str = "MASCOT_ENTERING",
        product_description: str = "",
        job: str = "",
        audience: str = "",
        moment: str = "",
        alternative: str = "",
        difference: str = "",
        learning_goal: str = "",
        understanding_input: str = "",
        understanding_note: str = "",
        artifact_mode: str = "",
        artifact_value: str = "",
        artifact_saved: bool = False,
        source_step: str = "github",
        github_input: str = "",
        document_value: str = "",
        warm_lead_input: str = "",
        github_answered: bool = False,
        document_answered: bool = False,
        warm_leads_answered: bool = False,
        persona_note: str = "",
        persona_input: str = "",
        selected_personas: list[str] = [],
        search_progress: int = 0,
        selected_prospect_id: str = "",
        profile_tab: str = "overview",
        draft_text: str = "",
        busy: bool = False,
        notice: str = "",
        live_call_prospect_id: str = "",
        live_call_step: int = 0,
        live_call_active: bool = False,
        calendar_notice: str = "";

    async can with entry {
        load_workspace();
    }

    can with [phase] entry {
        window.scrollTo(0, 0);
    }

    can with [phase, source_step, busy, understanding_note, persona_note] entry {
        setTimeout(
            lambda {
                target: any = document.getElementById("conversation-end");
                if target is not None {
                    target.scrollIntoView({"behavior": "smooth", "block": "end"});
                }
            },
            40
        );
    }

    async def load_workspace -> None;
    def apply_workspace(next_workspace: WorkspaceView) -> None;
    async def start_discovery(e: FormEvent) -> None;
    def use_demo_brief(_e: MouseEvent) -> None;
    def send_understanding_correction(e: FormEvent) -> None;
    async def save_understanding -> None;
    async def submit_github(e: FormEvent) -> None;
    async def skip_github -> None;
    def capture_conversation_file(_e: ChangeEvent) -> None;
    async def save_conversation_document -> None;
    async def skip_conversation_document -> None;
    def capture_warm_leads_file(_e: ChangeEvent) -> None;
    async def submit_warm_leads(e: FormEvent) -> None;
    async def skip_warm_leads -> None;
    def choose_artifact(mode: str) -> None;
    def capture_file(_e: ChangeEvent) -> None;
    async def save_artifact -> None;
    def add_another_artifact(_e: MouseEvent) -> None;
    async def continue_to_personas -> None;
    def toggle_persona(persona_id: str) -> None;
    def send_persona_correction(e: FormEvent) -> None;
    async def confirm_personas -> None;
    async def search_signals -> None;
    async def prepare_outreach -> None;
    def select_prospect(prospect_id: str) -> None;
    async def approve_and_send -> None;
    def skip_draft(_e: MouseEvent) -> None;
    async def schedule_agent_call -> None;
    async def open_live_call(prospect_id: str) -> None;
    def close_live_call -> None;
    async def book_demo_meeting -> None;
    async def learn_from_interview -> None;
    async def jump_to_stage(stage: int) -> None;
    def open_profile(prospect_id: str) -> None;
    def go_profiles -> None;
    def back_to_profiles -> None;
    def set_profile_tab(tab: str) -> None;
    def go_calendar -> None;
    def refresh_calendar -> None;
    def go_home(_e: MouseEvent) -> None;
    async def rerun -> None;

    current_stage = stage_index(phase);
    is_home = phase in ["EMPTY", "MASCOT_ENTERING"];
    return
        <div
            className={"traction-app home-mode"
                if is_home
                else "traction-app workspace-mode"}
        >
            <AppHeader
                stage={current_stage}
                compact={is_home}
                onHome={go_home}
                onRerun={rerun}
                onStage={jump_to_stage}
                busy={busy}
            />
            {if not is_home {
                <WorkspaceViewNav
                    phase={phase}
                    hasProfiles={workspace is not None and bool(workspace.prospects)}
                    onProfiles={go_profiles}
                    onDrafts={lambda { jump_to_stage(2); }}
                    onActivity={lambda { phase = "TRACKING_EXTERNAL_ACTIVITY"
                        if workspace is not None and workspace.prospects
                        else "REACH_EMPTY"; }}
                    onCalendar={go_calendar}
                    onLearn={lambda { phase = "LEARNING_FROM_MEETING"
                        if workspace is not None and workspace.prospects
                        else "LEARN_EMPTY"; }}
                    busy={busy}
                />
            }}
            <main className="app-main">
                {if is_home {
                    <HomeScreen
                        key="home"
                        description={product_description}
                        onDescription={lambda (value: str) { product_description = value; }}
                        onSubmit={start_discovery}
                        onDemo={use_demo_brief}
                        entering={phase == "MASCOT_ENTERING"}
                    />
                }}
                {if phase in [
                    "ANALYZING_PRODUCT",
                    "ANALYZING_CONTEXT",
                    "CONFIRMING_UNDERSTANDING",
                    "WAITING_FOR_CHOICE",
                    "REVIEWING_PERSONAS"
                ] {
                    <DiscoveryChat
                        key="discovery-conversation"
                        phase={phase}
                        description={product_description}
                        workspace={workspace}
                        understandingInput={understanding_input}
                        understandingNote={understanding_note}
                        onUnderstandingInput={lambda (value: str) { understanding_input = value; }}
                        onUnderstandingSend={send_understanding_correction}
                        onUnderstandingConfirm={save_understanding}
                        sourceStep={source_step}
                        githubInput={github_input}
                        githubAnswered={github_answered}
                        onGithubInput={lambda (value: str) { github_input = value; }}
                        onGithubSubmit={submit_github}
                        onGithubSkip={skip_github}
                        documentValue={document_value}
                        documentAnswered={document_answered}
                        onDocumentFile={capture_conversation_file}
                        onDocumentSave={save_conversation_document}
                        onDocumentSkip={skip_conversation_document}
                        warmLeadInput={warm_lead_input}
                        warmLeadsAnswered={warm_leads_answered}
                        onWarmLeadInput={lambda (value: str) { warm_lead_input = value; }}
                        onWarmLeadFile={capture_warm_leads_file}
                        onWarmLeadSubmit={submit_warm_leads}
                        onWarmLeadSkip={skip_warm_leads}
                        personaInput={persona_input}
                        personaNote={persona_note}
                        selectedPersonas={selected_personas}
                        onPersonaInput={lambda (value: str) { persona_input = value; }}
                        onPersonaSend={send_persona_correction}
                        onPersonaToggle={toggle_persona}
                        onPersonaConfirm={confirm_personas}
                        busy={busy}
                    />
                }}
                {if phase == "SEARCHING" {
                    <SearchScreen
                        key="search"
                        onSearch={search_signals}
                        busy={busy}
                        progress={search_progress}
                    />
                }}
                {if phase == "REVIEWING_PROSPECTS" and workspace is not None {
                    <ProspectResults
                        key="prospects"
                        prospects={workspace.prospects}
                        onPrepare={prepare_outreach}
                        onProfile={open_profile}
                        busy={busy}
                    />
                }}
                {if phase in ["FIND_EMPTY", "REACH_EMPTY", "LEARN_EMPTY"] {
                    <StageEmpty
                        key={phase}
                        stage={"Find"
                            if phase == "FIND_EMPTY"
                            else ("Reach" if phase == "REACH_EMPTY" else "Learn")}
                        onBack={lambda { jump_to_stage(0); }}
                    />
                }}
                {if phase == "DRAFTING_OUTREACH" {
                    <AgentTask
                        key="drafting"
                        state="typing"
                        eyebrow="Reach · active"
                        title="Writing from the evidence in the founder’s voice"
                        detail="Grounding each message in one observed behavior"
                    />
                }}
                {if phase == "WAITING_FOR_APPROVAL" and workspace is not None {
                    <OutreachWorkspace
                        key="outreach"
                        founderName={workspace.founder_name}
                        founderEmail={workspace.founder_email}
                        prospects={workspace.prospects}
                        selectedId={selected_prospect_id}
                        draftText={draft_text}
                        notice={notice}
                        onSelect={select_prospect}
                        onDraft={lambda (value: str) { draft_text = value; }}
                        onSend={approve_and_send}
                        onSkip={skip_draft}
                        onTrack={lambda { phase = "TRACKING_EXTERNAL_ACTIVITY"; }}
                        onProfile={open_profile}
                        busy={busy}
                    />
                }}
                {if phase == "LEAD_LIBRARY" and workspace is not None {
                    <LeadLibrary
                        key="lead-library"
                        prospects={workspace.prospects}
                        activities={workspace.activities}
                        selectedId={selected_prospect_id}
                        profileTab={profile_tab}
                        onSelect={select_prospect}
                        onBack={back_to_profiles}
                        onTab={set_profile_tab}
                        onOutreach={prepare_outreach}
                    />
                }}
                {if phase == "TRACKING_EXTERNAL_ACTIVITY" and workspace is not None {
                    <ActivityWorkspace
                        key="activity"
                        workspace={workspace}
                        onScheduleCall={schedule_agent_call}
                        onCall={open_live_call}
                        onOutreach={lambda { phase = "WAITING_FOR_APPROVAL"; }}
                        onCalendar={go_calendar}
                        onLearn={lambda { phase = "LEARNING_FROM_MEETING"; }}
                        busy={busy}
                    />
                }}
                {if phase == "LIVE_AGENT_CALL" and workspace is not None {
                    <LiveCallWorkspace
                        key="live-call"
                        workspace={workspace}
                        prospectId={live_call_prospect_id}
                        step={live_call_step}
                        active={live_call_active}
                        onBack={close_live_call}
                        onCalendar={go_calendar}
                    />
                }}
                {if phase == "CALENDAR_WORKSPACE" and workspace is not None {
                    <CalendarWorkspace
                        key="calendar"
                        workspace={workspace}
                        notice={calendar_notice}
                        onActivity={lambda { phase = "TRACKING_EXTERNAL_ACTIVITY"; }}
                        onProfile={open_profile}
                        onSync={refresh_calendar}
                    />
                }}
                {if phase == "LEARNING_FROM_MEETING" and workspace is not None {
                    <LearningWorkspace
                        key="learning"
                        workspace={workspace}
                        onActivity={lambda { phase = "TRACKING_EXTERNAL_ACTIVITY"; }}
                        onLearn={learn_from_interview}
                        busy={busy}
                    />
                }}
            </main>
        </div>;
}

def:pub Brand -> JsxElement {
    return
        <div className="brand" aria-label="Traction">
            <span className="brand-mark">
                <span className="brand-pupil"></span>
            </span>
            <span>Traction</span>
        </div>;
}

def:pub AppHeader(
    stage: int,
    compact: bool,
    onHome: Callable[[MouseEvent], None],
    onRerun: Callable[[], None],
    onStage: Callable[[int], None],
    busy: bool
) -> JsxElement {
    return
        <header className={"app-header compact" if compact else "app-header"}>
            <button className="brand-button" onClick={onHome}>
                <Brand/>
            </button>
            <nav className="stage-nav" aria-label="Workflow progress">
                <StageNavItem
                    key="stage-understand"
                    index={0}
                    label="Understand"
                    stage={stage}
                    onStage={onStage}
                    busy={busy}
                />
                <StageNavItem
                    key="stage-find"
                    index={1}
                    label="Find"
                    stage={stage}
                    onStage={onStage}
                    busy={busy}
                />
                <StageNavItem
                    key="stage-reach"
                    index={2}
                    label="Reach"
                    stage={stage}
                    onStage={onStage}
                    busy={busy}
                />
                <StageNavItem
                    key="stage-learn"
                    index={3}
                    label="Learn"
                    stage={stage}
                    onStage={onStage}
                    busy={busy}
                />
            </nav>
            <div className="header-actions">
                <button key="header-home" className="text-button" onClick={onHome}>
                    Home
                </button>
                <button
                    key="header-rerun"
                    className="button small"
                    onClick={onRerun}
                    disabled={busy}
                >
                    ↻ Re-run
                </button>
            </div>
        </header>;
}

def:pub WorkspaceViewNav(
    phase: str,
    hasProfiles: bool,
    onProfiles: Callable[[], None],
    onDrafts: Callable[[], None],
    onActivity: Callable[[], None],
    onCalendar: Callable[[], None],
    onLearn: Callable[[], None],
    busy: bool
) -> JsxElement {
    return
        <nav className="workspace-view-nav" aria-label="Workspace pages">
            <div className="workspace-view-nav-inner">
                <button
                    className={"workspace-view-link active"
                        if phase == "LEAD_LIBRARY"
                        else "workspace-view-link"}
                    onClick={onProfiles}
                    disabled={busy or not hasProfiles}
                >
                    Lead profiles
                </button>
                <button
                    className={"workspace-view-link active"
                        if phase in ["DRAFTING_OUTREACH", "WAITING_FOR_APPROVAL"]
                        else "workspace-view-link"}
                    onClick={onDrafts}
                    disabled={busy or not hasProfiles}
                >
                    Draft outreach
                </button>
                <button
                    className={"workspace-view-link active"
                        if phase in [
                            "TRACKING_EXTERNAL_ACTIVITY", "LIVE_AGENT_CALL"
                        ]
                        else "workspace-view-link"}
                    onClick={onActivity}
                    disabled={busy or not hasProfiles}
                >
                    Activity tracking
                </button>
                <button
                    className={"workspace-view-link active"
                        if phase == "CALENDAR_WORKSPACE"
                        else "workspace-view-link"}
                    onClick={onCalendar}
                    disabled={busy or not hasProfiles}
                >
                    Calendar
                </button>
                <button
                    className={"workspace-view-link active"
                        if phase == "LEARNING_FROM_MEETING"
                        else "workspace-view-link"}
                    onClick={onLearn}
                    disabled={busy or not hasProfiles}
                >
                    Learn{" "}
                    <span className="nav-status">Backlog</span>
                </button>
            </div>
        </nav>;
}

def:pub StageNavItem(
    index: int, label: str, stage: int, onStage: Callable[[int], None], busy: bool
) -> JsxElement {
    return
        <button
            className={"stage-item stage-jump active"
                if index == stage
                else (
                    "stage-item stage-jump done"
                        if index < stage
                        else "stage-item stage-jump"
                )}
            onClick={lambda { onStage(index); }}
            disabled={busy}
            aria-label={"Go to step " + str(index + 1) + ": " + label}
        >
            <span className="stage-dot">{str(index + 1)}</span>
            <span>{label}</span>
        </button>;
}

def:pub Mascot(state: str = "waiting") -> JsxElement {
    return
        <div className={"mascot mascot-" + state} aria-label={"Agent is " + state}>
            <div className="mascot-art" aria-hidden="true">
                <img
                    className="mascot-image"
                    src={"/public/traction-mascot-laptop-cutout.png"
                        if state in ["typing", "thinking"]
                        else "/public/traction-mascot-cutout.png"}
                    alt=""
                />
                <span className="mascot-complete-mark">✓</span>
                <span className="mascot-keyboard">
                    <span></span>
                    <span></span>
                    <span></span>
                    <span></span>
                    <span></span>
                    <span></span>
                </span>
            </div>
            <span className="mascot-shadow"></span>
        </div>;
}

def:pub WorkspaceMascot(pose: str) -> JsxElement {
    return
        <div
            className={"workspace-pose-mascot pose-" + pose}
            aria-label={"Traction agent " + pose + " pose"}
        >
            <img
                src={"/public/traction-mascot-pose-" + pose + ".png"}
                alt=""
                aria-hidden="true"
            />
        </div>;
}

def:pub HomeScreen(
    description: str,
    onDescription: Callable[[str], None],
    onSubmit: Callable[[FormEvent], None],
    onDemo: Callable[[MouseEvent], None],
    entering: bool
) -> JsxElement {
    return
        <section className="home-stage">
            <div className={"home-agent entering" if entering else "home-agent"}>
                <Mascot state="speaking"/>
                <div className="speech-bubble">
                    <span className="typing-line">What are you building?</span>
                </div>
            </div>
            <form className="home-composer" onSubmit={onSubmit}>
                <textarea
                    value={description}
                    onChange={lambda (e: ChangeEvent) { onDescription(
                        e.target.value
                    ); }}
                    placeholder="Describe your product..."
                    rows={3}
                    autoFocus={True}
                />
                <div className="composer-footer">
                    <button type="button" className="demo-link" onClick={onDemo}>
                        Use the locals + travelers demo brief
                    </button>
                    <button
                        type="submit"
                        className="send-button"
                        disabled={not description.strip()}
                        aria-label="Send product description"
                    >
                        →
                    </button>
                </div>
            </form>
            <p className="home-footnote">
                Private workspace · You approve every external action
            </p>
        </section>;
}

def:pub AgentTask(state: str, eyebrow: str, title: str, detail: str) -> JsxElement {
    return
        <section className="focused-task narrow">
            <div className="task-agent">
                <Mascot state={state}/>
            </div>
            <p className="eyebrow">{eyebrow}</p>
            <h1 className="editorial">{title}</h1>
            <div className="thinking-track">
                <span></span>
            </div>
            <div className="task-log">
                <span className="log-dot active"></span>
                <span>{detail}</span>
            </div>
        </section>;
}

def:pub ChatComposer(
    value: str,
    onValue: Callable[[str], None],
    onSubmit: Callable[[FormEvent], None],
    placeholder: str,
    busy: bool,
    label: str
) -> JsxElement {
    return
        <form className="chat-composer" onSubmit={onSubmit}>
            <textarea
                value={value}
                onChange={lambda (e: ChangeEvent) { onValue(e.target.value); }}
                placeholder={placeholder}
                rows={2}
            />
            <button
                type="submit"
                aria-label={label}
                disabled={busy or not value.strip()}
            >
                ↑
            </button>
        </form>;
}

def:pub DiscoveryChat(
    phase: str,
    description: str,
    workspace: WorkspaceView | None,
    understandingInput: str,
    understandingNote: str,
    onUnderstandingInput: Callable[[str], None],
    onUnderstandingSend: Callable[[FormEvent], None],
    onUnderstandingConfirm: Callable[[], None],
    sourceStep: str,
    githubInput: str,
    githubAnswered: bool,
    onGithubInput: Callable[[str], None],
    onGithubSubmit: Callable[[FormEvent], None],
    onGithubSkip: Callable[[], None],
    documentValue: str,
    documentAnswered: bool,
    onDocumentFile: Callable[[ChangeEvent], None],
    onDocumentSave: Callable[[], None],
    onDocumentSkip: Callable[[], None],
    warmLeadInput: str,
    warmLeadsAnswered: bool,
    onWarmLeadInput: Callable[[str], None],
    onWarmLeadFile: Callable[[ChangeEvent], None],
    onWarmLeadSubmit: Callable[[FormEvent], None],
    onWarmLeadSkip: Callable[[], None],
    personaInput: str,
    personaNote: str,
    selectedPersonas: list[str],
    onPersonaInput: Callable[[str], None],
    onPersonaSend: Callable[[FormEvent], None],
    onPersonaToggle: Callable[[str], None],
    onPersonaConfirm: Callable[[], None],
    busy: bool
) -> JsxElement {
    understanding = workspace.understanding if workspace is not None else None;
    personas = workspace.personas if workspace is not None else [];
    artifacts = workspace.artifact_names if workspace is not None else [];
    in_conversation = phase in [
        "WAITING_FOR_CHOICE",
        "ANALYZING_CONTEXT",
        "CONFIRMING_UNDERSTANDING",
        "REVIEWING_PERSONAS"
    ];
    show_github_answer = in_conversation
    and (githubAnswered or sourceStep != "github" or phase == "REVIEWING_PERSONAS");
    show_document = in_conversation
    and (
        sourceStep in ["documents", "inference", "leads", "complete"]
        or phase in ["CONFIRMING_UNDERSTANDING", "REVIEWING_PERSONAS"]
    );
    show_document_answer = show_document
    and (
        documentAnswered
        or sourceStep in ["inference", "leads", "complete"]
        or phase in ["CONFIRMING_UNDERSTANDING", "REVIEWING_PERSONAS"]
    );
    show_inference = phase == "CONFIRMING_UNDERSTANDING"
    or sourceStep in ["leads", "complete"]
    or phase == "REVIEWING_PERSONAS";
    show_warm_leads = sourceStep in ["leads", "complete"]
    or phase == "REVIEWING_PERSONAS";
    show_warm_leads_answer = warmLeadsAnswered
    or sourceStep == "complete"
    or phase == "REVIEWING_PERSONAS";

    return
        <section className="discovery-chat-shell">
            <div className="conversation-header">
                <p className="eyebrow">Understand · Product conversation</p>
            </div>
            <div className="conversation-thread" aria-label="Conversation history">
                <div className="chat-row founder-row discovery-opening">
                    <div className="chat-bubble founder-bubble">
                        <span className="chat-label">You</span>
                        <p>{description}</p>
                    </div>
                </div>
                {if phase == "ANALYZING_PRODUCT" {
                    <div
                        key="product-thinking"
                        className="chat-row agent-row current-agent-row"
                    >
                        <span className="conversation-mascot-slot">
                            <Mascot state="thinking"/>
                        </span>
                        <div className="chat-bubble agent-bubble thinking-bubble">
                            <span className="typing-dots">
                                <span></span>
                                <span></span>
                                <span></span>
                            </span>
                            Got it. Let me get a little context before I form a view…
                        </div>
                    </div>
                }}
                {if in_conversation {
                    <div key="github-question" className="chat-row agent-row">
                        <span className="conversation-mascot-slot">
                            {if phase == "WAITING_FOR_CHOICE"
                            and sourceStep == "github"
                            and not busy {
                                <Mascot key="github-mascot" state="speaking"/>
                            }}
                        </span>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            Great. Do you have a GitHub link I can look through?
                        </div>
                    </div>
                }}
                {if show_github_answer {
                    <div key="github-answer" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>
                                {githubInput if githubInput else "No GitHub link yet."}
                            </p>
                        </div>
                    </div>
                }}
                {if show_document {
                    <div key="document-question" className="chat-row agent-row">
                        <span className="conversation-mascot-slot">
                            {if phase == "WAITING_FOR_CHOICE"
                            and sourceStep == "documents"
                            and not busy {
                                <Mascot key="document-mascot" state="speaking"/>
                            }}
                        </span>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            Thanks. Is there a brief, deck, notes, or anything else I should read?
                        </div>
                    </div>
                }}
                {if show_document_answer {
                    <div key="document-answer" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>
                                {documentValue
                                    if documentValue
                                    else "No documents right now."}
                            </p>
                        </div>
                    </div>
                }}
                {if phase == "ANALYZING_CONTEXT" {
                    <div
                        key="context-thinking"
                        className="chat-row agent-row current-agent-row"
                    >
                        <span className="conversation-mascot-slot">
                            <Mascot state="thinking"/>
                        </span>
                        <div className="chat-bubble agent-bubble thinking-bubble">
                            <span className="typing-dots">
                                <span></span>
                                <span></span>
                                <span></span>
                            </span>
                            I’m connecting what you shared before I give you my read…
                        </div>
                    </div>
                }}
                {if understanding is not None and show_inference {
                    <div
                        key="understanding"
                        className="chat-row agent-row history-agent-row"
                    >
                        <span className="conversation-mascot-slot"></span>
                        <div
                            className="chat-bubble agent-bubble conversational-summary"
                        >
                            <p>
                                Okay—now that I’ve seen the context, I think the product is really about this: {understanding.job}
                            </p>
                            <p>
                                The people who feel it most are {understanding.audience} It shows up most when {understanding.moment}
                            </p>
                            <p>
                                They’re using {understanding.alternative} What feels different here is {understanding.difference}
                            </p>
                            <p>
                                The first thing I’d test is this: {understanding.learning_goal}
                            </p>
                        </div>
                    </div>
                }}
                {if understandingNote and show_inference {
                    <div key="understanding-note" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>{understandingNote}</p>
                        </div>
                    </div>
                }}
                {if phase == "CONFIRMING_UNDERSTANDING" {
                    <div
                        key="understanding-question"
                        className="chat-row agent-row current-agent-row"
                    >
                        <span className="conversation-mascot-slot">
                            {if not busy {
                                <Mascot state="speaking"/>
                            }}
                        </span>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            Does that sound right? Tell me what I missed, or we can keep going.
                        </div>
                    </div>
                }}
                {if show_warm_leads {
                    <div key="leads-question" className="chat-row agent-row">
                        <span className="conversation-mascot-slot">
                            {if phase == "WAITING_FOR_CHOICE"
                            and sourceStep == "leads"
                            and not busy {
                                <Mascot key="leads-mascot" state="speaking"/>
                            }}
                        </span>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            One last thing—do you already know anyone we should talk to? Names, phone numbers, or LinkedIn links are all useful.
                        </div>
                    </div>
                }}
                {if show_warm_leads_answer {
                    <div key="leads-answer" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>
                                {warmLeadInput
                                    if warmLeadInput
                                    else "No warm leads yet."}
                            </p>
                        </div>
                    </div>
                }}
                {if busy and phase not in ["ANALYZING_PRODUCT", "ANALYZING_CONTEXT"] {
                    <div
                        key="transition-thinking"
                        className="chat-row agent-row current-agent-row"
                    >
                        <span className="conversation-mascot-slot">
                            <Mascot state="typing"/>
                        </span>
                        <div className="chat-bubble agent-bubble thinking-bubble">
                            <span className="typing-dots">
                                <span></span>
                                <span></span>
                                <span></span>
                            </span>
                            One moment…
                        </div>
                    </div>
                }}
                {if phase == "REVIEWING_PERSONAS" {
                    <div
                        key="persona-message"
                        className="chat-row agent-row history-agent-row"
                    >
                        <span className="conversation-mascot-slot"></span>
                        <div className="chat-bubble agent-bubble persona-chat-bubble">
                            <p>
                                I have enough to suggest four kinds of people who could teach us something useful. Choose the ones that feel right.
                            </p>
                            <div className="conversation-personas">
                                {for persona in personas {
                                    <button
                                        key={persona.id}
                                        className={"conversation-persona selected"
                                            if persona.id in selectedPersonas
                                            else "conversation-persona"}
                                        onClick={lambda { onPersonaToggle(
                                            persona.id
                                        ); }}
                                    >
                                        <span className="card-select">
                                            {"✓"
                                                if persona.id in selectedPersonas
                                                else "+"}
                                        </span>
                                        <strong>{persona.title}</strong>
                                        <p>{persona.description}</p>
                                        <small>Signal · {persona.signal}</small>
                                    </button>
                                }}
                            </div>
                        </div>
                    </div>
                }}
                {if personaNote {
                    <div key="persona-note" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>{personaNote}</p>
                        </div>
                    </div>
                }}
                {if phase == "REVIEWING_PERSONAS" and not busy {
                    <div
                        key="persona-question"
                        className="chat-row agent-row current-agent-row"
                    >
                        <span className="conversation-mascot-slot">
                            <Mascot state="speaking"/>
                        </span>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            Anything you want me to change before I start searching?
                        </div>
                    </div>
                }}
                {if artifacts {
                    <div key="conversation-sources" className="conversation-sources">
                        {for name in artifacts {
                            <span key={name} className="source-chip">✓ {name}</span>
                        }}
                    </div>
                }}
                <div id="conversation-end" className="conversation-end"></div>
            </div>
            <div className="conversation-composer-dock">
                {if phase == "CONFIRMING_UNDERSTANDING" {
                    <div
                        key="understanding-composer"
                        className="conversation-dock-inner"
                    >
                        <ChatComposer
                            value={understandingInput}
                            onValue={onUnderstandingInput}
                            onSubmit={onUnderstandingSend}
                            placeholder="Reply with a correction or emphasis…"
                            busy={busy}
                            label="Send product correction"
                        />
                        <div className="conversation-inline-actions">
                            <span></span>
                            <button
                                className="button primary"
                                onClick={onUnderstandingConfirm}
                                disabled={busy}
                            >
                                Looks right →
                            </button>
                        </div>
                    </div>
                }}
                {if phase == "WAITING_FOR_CHOICE"
                and sourceStep == "github"
                and not busy {
                    <div key="github-composer" className="conversation-dock-inner">
                        <ChatComposer
                            value={githubInput}
                            onValue={onGithubInput}
                            onSubmit={onGithubSubmit}
                            placeholder="Paste a GitHub repository URL…"
                            busy={busy}
                            label="Send GitHub link"
                        />
                        <div className="conversation-inline-actions">
                            <span></span>
                            <button className="text-button" onClick={onGithubSkip}>
                                I don’t have one
                            </button>
                        </div>
                    </div>
                }}
                {if phase == "WAITING_FOR_CHOICE"
                and sourceStep == "documents"
                and not busy {
                    <div
                        key="document-composer"
                        className="conversation-dock-inner document-dock"
                    >
                        <label className="conversation-dropbox compact-dropbox">
                            <input
                                type="file"
                                onChange={onDocumentFile}
                                accept=".pdf,.doc,.docx,.txt,.md,.png,.jpg"
                            />
                            <span className="drop-icon">↑</span>
                            <span>
                                <strong>Drop a document</strong>
                                <small>
                                    {documentValue
                                        if documentValue
                                        else "or click to choose"}
                                </small>
                            </span>
                        </label>
                        <div className="conversation-inline-actions">
                            <button className="text-button" onClick={onDocumentSkip}>
                                Skip for now
                            </button>
                            <button
                                className="button primary"
                                onClick={onDocumentSave}
                                disabled={not documentValue}
                            >
                                Send document →
                            </button>
                        </div>
                    </div>
                }}
                {if phase == "WAITING_FOR_CHOICE"
                and sourceStep == "leads"
                and not busy {
                    <div key="leads-composer" className="conversation-dock-inner">
                        <ChatComposer
                            value={warmLeadInput}
                            onValue={onWarmLeadInput}
                            onSubmit={onWarmLeadSubmit}
                            placeholder="Name · phone · LinkedIn URL"
                            busy={busy}
                            label="Send warm leads"
                        />
                        <div className="conversation-inline-actions">
                            <label className="inline-file-link">
                                <input
                                    type="file"
                                    accept=".csv"
                                    onChange={onWarmLeadFile}
                                />
                                Upload CSV
                            </label>
                            <button className="text-button" onClick={onWarmLeadSkip}>
                                No warm leads yet
                            </button>
                        </div>
                    </div>
                }}
                {if phase == "REVIEWING_PERSONAS" {
                    <div key="persona-composer" className="conversation-dock-inner">
                        <ChatComposer
                            value={personaInput}
                            onValue={onPersonaInput}
                            onSubmit={onPersonaSend}
                            placeholder="Reply with a persona correction…"
                            busy={busy}
                            label="Send persona correction"
                        />
                        <div className="conversation-inline-actions">
                            <span className="muted-note">
                                {str(len(selectedPersonas))} selected
                            </span>
                            <button
                                className="button primary"
                                onClick={onPersonaConfirm}
                                disabled={busy}
                            >
                                Start search →
                            </button>
                        </div>
                    </div>
                }}
                {if busy {
                    <div key="busy-composer" className="composer-waiting">
                        Traction is replying…
                    </div>
                }}
            </div>
        </section>;
}

def:pub DiscoveryConversation(
    phase: str,
    description: str,
    workspace: WorkspaceView | None,
    understandingInput: str,
    understandingNote: str,
    onUnderstandingInput: Callable[[str], None],
    onUnderstandingSend: Callable[[FormEvent], None],
    onUnderstandingConfirm: Callable[[], None],
    sourceStep: str,
    githubInput: str,
    githubAnswered: bool,
    onGithubInput: Callable[[str], None],
    onGithubSubmit: Callable[[FormEvent], None],
    onGithubSkip: Callable[[], None],
    documentValue: str,
    documentAnswered: bool,
    onDocumentFile: Callable[[ChangeEvent], None],
    onDocumentSave: Callable[[], None],
    onDocumentSkip: Callable[[], None],
    warmLeadInput: str,
    warmLeadsAnswered: bool,
    onWarmLeadInput: Callable[[str], None],
    onWarmLeadFile: Callable[[ChangeEvent], None],
    onWarmLeadSubmit: Callable[[FormEvent], None],
    onWarmLeadSkip: Callable[[], None],
    personaInput: str,
    personaNote: str,
    selectedPersonas: list[str],
    onPersonaInput: Callable[[str], None],
    onPersonaSend: Callable[[FormEvent], None],
    onPersonaToggle: Callable[[str], None],
    onPersonaConfirm: Callable[[], None],
    busy: bool
) -> JsxElement {
    understanding = workspace.understanding if workspace is not None else None;
    personas = workspace.personas if workspace is not None else [];
    artifacts = workspace.artifact_names if workspace is not None else [];
    in_sources = phase in ["WAITING_FOR_CHOICE", "REVIEWING_PERSONAS"];
    show_github_answer = githubAnswered
    or sourceStep != "github"
    or phase == "REVIEWING_PERSONAS";
    show_document = sourceStep in ["documents", "leads", "complete"]
    or phase == "REVIEWING_PERSONAS";
    show_document_answer = documentAnswered
    or sourceStep in ["leads", "complete"]
    or phase == "REVIEWING_PERSONAS";
    show_warm_leads = sourceStep in ["leads", "complete"]
    or phase == "REVIEWING_PERSONAS";
    show_warm_leads_answer = warmLeadsAnswered
    or sourceStep == "complete"
    or phase == "REVIEWING_PERSONAS";

    return
        <section
            className="workspace-section conversation-screen discovery-conversation"
        >
            <p className="eyebrow">Understand · One conversation</p>
            <div className="conversation-thread">
                <div className="chat-row founder-row discovery-opening">
                    <div className="chat-bubble founder-bubble">
                        <span className="chat-label">You</span>
                        <p>{description}</p>
                    </div>
                </div>
                {if phase == "ANALYZING_PRODUCT" {
                    <div
                        key="product-thinking"
                        className="chat-row agent-row action-row"
                    >
                        <Mascot state="thinking"/>
                        <div className="chat-bubble agent-bubble thinking-bubble">
                            <span className="typing-dots">
                                <span></span>
                                <span></span>
                                <span></span>
                            </span>
                            Thinking through who feels this problem and what we should test first…
                        </div>
                    </div>
                }}
                {if understanding is not None {
                    <div key="understanding" className="chat-row agent-row">
                        <Mascot state="speaking"/>
                        <div
                            className="chat-bubble agent-bubble conversational-summary"
                        >
                            <span className="chat-label">My first read</span>
                            <h1 className="editorial">
                                Okay—here’s how I see your product.
                            </h1>
                            <p>{understanding.job}</p>
                            <p>
                                It seems most useful for{" "}
                                <strong>{understanding.audience}</strong>
                                , especially in this moment:{" "}
                                {understanding.moment}
                            </p>
                            <p>
                                The usual alternatives are {understanding.alternative}
                            </p>
                            <p>
                                What feels meaningfully different is {understanding.difference}
                            </p>
                            <p>
                                I’d test one belief first:{" "}
                                <strong>{understanding.learning_goal}</strong>
                            </p>
                            <div className="concept-tray">
                                {for concept in understanding.concepts {
                                    <span key={concept}>{concept}</span>
                                }}
                            </div>
                        </div>
                    </div>
                }}
                {if understandingNote {
                    <div key="understanding-note" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">Your correction</span>
                            <p>{understandingNote}</p>
                        </div>
                    </div>
                }}
                {if phase == "CONFIRMING_UNDERSTANDING" {
                    <div key="understanding-question" className="conversation-turn">
                        <div className="chat-row agent-row compact-row prompt-row">
                            <Mascot state="waiting"/>
                            <div className="chat-bubble agent-bubble prompt-bubble">
                                Did I get that right? Tell me what I missed, or we can keep going.
                            </div>
                        </div>
                        <ChatComposer
                            value={understandingInput}
                            onValue={onUnderstandingInput}
                            onSubmit={onUnderstandingSend}
                            placeholder="Reply with a correction or emphasis…"
                            busy={busy}
                            label="Send product correction"
                        />
                        <div className="conversation-inline-actions">
                            <span></span>
                            <button
                                className="button primary"
                                onClick={onUnderstandingConfirm}
                                disabled={busy}
                            >
                                Looks right →
                            </button>
                        </div>
                    </div>
                }}
                {if in_sources {
                    <div
                        key="github-question"
                        className="chat-row agent-row compact-row"
                    >
                        <Mascot state="speaking"/>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            That gives me the shape of it. Do you have a GitHub link I can read?
                        </div>
                    </div>
                }}
                {if show_github_answer {
                    <div key="github-answer" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>
                                {githubInput if githubInput else "No GitHub link yet."}
                            </p>
                        </div>
                    </div>
                }}
                {if phase == "WAITING_FOR_CHOICE"
                and sourceStep == "github"
                and not busy {
                    <div key="github-reply" className="conversation-turn">
                        <ChatComposer
                            value={githubInput}
                            onValue={onGithubInput}
                            onSubmit={onGithubSubmit}
                            placeholder="Paste a GitHub repository URL…"
                            busy={busy}
                            label="Send GitHub link"
                        />
                        <div className="conversation-inline-actions">
                            <span></span>
                            <button className="text-button" onClick={onGithubSkip}>
                                I don’t have one
                            </button>
                        </div>
                    </div>
                }}
                {if show_document {
                    <div
                        key="document-question"
                        className="chat-row agent-row compact-row"
                    >
                        <Mascot state="speaking"/>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            Thanks. A repo tells me how it works; the context tells me why. Do you have a brief, deck, notes, or screenshots?
                        </div>
                    </div>
                }}
                {if show_document_answer {
                    <div key="document-answer" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>
                                {documentValue
                                    if documentValue
                                    else "No documents right now."}
                            </p>
                        </div>
                    </div>
                }}
                {if phase == "WAITING_FOR_CHOICE"
                and sourceStep == "documents"
                and not busy {
                    <div key="document-reply" className="conversation-attachment">
                        <label className="conversation-dropbox">
                            <input
                                type="file"
                                onChange={onDocumentFile}
                                accept=".pdf,.doc,.docx,.txt,.md,.png,.jpg"
                            />
                            <span className="drop-icon">↑</span>
                            <strong>Drop product documents here</strong>
                            <span>
                                {documentValue
                                    if documentValue
                                    else "or click to choose a file"}
                            </span>
                        </label>
                        <div className="conversation-inline-actions">
                            <button className="text-button" onClick={onDocumentSkip}>
                                Skip for now
                            </button>
                            <button
                                className="button primary"
                                onClick={onDocumentSave}
                                disabled={not documentValue}
                            >
                                Send document →
                            </button>
                        </div>
                    </div>
                }}
                {if show_warm_leads {
                    <div
                        key="leads-question"
                        className="chat-row agent-row compact-row"
                    >
                        <Mascot state="speaking"/>
                        <div className="chat-bubble agent-bubble prompt-bubble">
                            One last thing before I suggest who to talk to: do you already have warm leads? Send any names, phone numbers, or LinkedIn URLs you know.
                        </div>
                    </div>
                }}
                {if show_warm_leads_answer {
                    <div key="leads-answer" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>
                                {warmLeadInput
                                    if warmLeadInput
                                    else "No warm leads yet."}
                            </p>
                        </div>
                    </div>
                }}
                {if phase == "WAITING_FOR_CHOICE"
                and sourceStep == "leads"
                and not busy {
                    <div key="leads-reply" className="conversation-turn">
                        <ChatComposer
                            value={warmLeadInput}
                            onValue={onWarmLeadInput}
                            onSubmit={onWarmLeadSubmit}
                            placeholder="Name · phone · LinkedIn URL"
                            busy={busy}
                            label="Send warm leads"
                        />
                        <div className="conversation-inline-actions">
                            <label className="inline-file-link">
                                <input
                                    type="file"
                                    accept=".csv"
                                    onChange={onWarmLeadFile}
                                />
                                Upload CSV
                            </label>
                            <button className="text-button" onClick={onWarmLeadSkip}>
                                No warm leads yet
                            </button>
                        </div>
                    </div>
                }}
                {if busy and phase != "ANALYZING_PRODUCT" {
                    <div
                        key="transition-thinking"
                        className="chat-row agent-row action-row"
                    >
                        <Mascot state="typing"/>
                        <div className="chat-bubble agent-bubble thinking-bubble">
                            <span className="typing-dots">
                                <span></span>
                                <span></span>
                                <span></span>
                            </span>
                            Give me a moment…
                        </div>
                    </div>
                }}
                {if phase == "REVIEWING_PERSONAS" {
                    <div
                        key="persona-message"
                        className="chat-row agent-row persona-chat-row"
                    >
                        <Mascot state="speaking"/>
                        <div className="chat-bubble agent-bubble persona-chat-bubble">
                            <span className="chat-label">A first pass</span>
                            <h2>
                                Perfect. I have enough to suggest who we should learn from first.
                            </h2>
                            <p>
                                These aren’t rigid personas—just four research lenses. Tap any one to include or exclude it.
                            </p>
                            <div className="conversation-personas">
                                {for persona in personas {
                                    <button
                                        key={persona.id}
                                        className={"conversation-persona selected"
                                            if persona.id in selectedPersonas
                                            else "conversation-persona"}
                                        onClick={lambda { onPersonaToggle(
                                            persona.id
                                        ); }}
                                    >
                                        <span className="card-select">
                                            {"✓"
                                                if persona.id in selectedPersonas
                                                else "+"}
                                        </span>
                                        <strong>{persona.title}</strong>
                                        <p>{persona.description}</p>
                                        <small>Signal · {persona.signal}</small>
                                    </button>
                                }}
                            </div>
                        </div>
                    </div>
                }}
                {if personaNote {
                    <div key="persona-note" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">Your emphasis</span>
                            <p>{personaNote}</p>
                        </div>
                    </div>
                }}
                {if phase == "REVIEWING_PERSONAS" {
                    <div key="persona-reply" className="conversation-turn">
                        <div className="chat-row agent-row compact-row prompt-row">
                            <Mascot state="waiting"/>
                            <div className="chat-bubble agent-bubble prompt-bubble">
                                Anything you want me to change or emphasize before I search?
                            </div>
                        </div>
                        <ChatComposer
                            value={personaInput}
                            onValue={onPersonaInput}
                            onSubmit={onPersonaSend}
                            placeholder="Reply with a persona correction…"
                            busy={busy}
                            label="Send persona correction"
                        />
                        <div className="conversation-inline-actions">
                            <span className="muted-note">
                                {str(len(selectedPersonas))} research lenses selected
                            </span>
                            <button
                                className="button primary"
                                onClick={onPersonaConfirm}
                                disabled={busy}
                            >
                                Start search →
                            </button>
                        </div>
                    </div>
                }}
                {if artifacts {
                    <div key="conversation-sources" className="conversation-sources">
                        <span>Context saved</span>
                        {for name in artifacts {
                            <span key={name} className="source-chip">✓ {name}</span>
                        }}
                    </div>
                }}
            </div>
        </section>;
}

def:pub UnderstandingScreen(
    understanding: ProductUnderstanding,
    founderNote: str,
    input: str,
    onInput: Callable[[str], None],
    onSend: Callable[[FormEvent], None],
    onConfirm: Callable[[], None],
    busy: bool
) -> JsxElement {
    return
        <section className="workspace-section conversation-screen">
            <p className="eyebrow">Understand · Conversation</p>
            <div className="conversation-thread">
                <div className="chat-row agent-row">
                    <Mascot state="speaking"/>
                    <div className="chat-bubble agent-bubble model-bubble">
                        <span className="chat-label">What I understand</span>
                        <h1 className="editorial">Here’s the product I’m hearing.</h1>
                        <div className="model-summary">
                            <div>
                                <span>Core job</span>
                                <p>{understanding.job}</p>
                            </div>
                            <div>
                                <span>Who feels it</span>
                                <p>{understanding.audience}</p>
                            </div>
                            <div>
                                <span>Painful moment</span>
                                <p>{understanding.moment}</p>
                            </div>
                            <div>
                                <span>Current alternative</span>
                                <p>{understanding.alternative}</p>
                            </div>
                            <div>
                                <span>Meaningful difference</span>
                                <p>{understanding.difference}</p>
                            </div>
                            <div>
                                <span>Riskiest belief</span>
                                <p>{understanding.learning_goal}</p>
                            </div>
                        </div>
                        <div className="concept-tray">
                            {for concept in understanding.concepts {
                                <span key={concept}>{concept}</span>
                            }}
                        </div>
                    </div>
                </div>
                {if founderNote {
                    <div
                        key="founder-understanding-note"
                        className="chat-row founder-row"
                    >
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>{founderNote}</p>
                        </div>
                    </div>
                }}
                {if founderNote {
                    <div
                        key="understanding-ack"
                        className="chat-row agent-row compact-row"
                    >
                        <Mascot state="completing"/>
                        <div className="chat-bubble agent-bubble acknowledgement">
                            Got it. I’ll carry that forward as a founder constraint.
                        </div>
                    </div>
                }}
                <div className="chat-row agent-row compact-row prompt-row">
                    <Mascot state="waiting"/>
                    <div className="chat-bubble agent-bubble prompt-bubble">
                        What should I correct or emphasize?
                    </div>
                </div>
            </div>
            <ChatComposer
                value={input}
                onValue={onInput}
                onSubmit={onSend}
                placeholder="Reply with a correction or emphasis…"
                busy={busy}
                label="Send product correction"
            />
            <div className="section-actions">
                <span className="muted-note">
                    Reply above, or continue if it’s right.
                </span>
                <button className="button primary" onClick={onConfirm} disabled={busy}>
                    {"Saving…" if busy else "Continue →"}
                </button>
            </div>
        </section>;
}

def:pub ArtifactScreen(
    artifacts: list[str],
    mode: str,
    value: str,
    saved: bool,
    onMode: Callable[[str], None],
    onValue: Callable[[str], None],
    onFile: Callable[[ChangeEvent], None],
    onSave: Callable[[], None],
    onAnother: Callable[[MouseEvent], None],
    onContinue: Callable[[], None],
    busy: bool
) -> JsxElement {
    return
        <section className="focused-task artifact-screen">
            <div className="task-agent">
                <Mascot state={"completing" if saved else "reading"}/>
            </div>
            <p className="eyebrow">Understand · Sources</p>
            <h1 className="editorial">What should I read before suggesting people?</h1>
            {if artifacts {
                <div key="saved-sources" className="saved-sources">
                    <span className="saved-label">Saved sources</span>
                    {for name in artifacts {
                        <span key={name} className="source-chip">
                            ✓{" "}
                            {name}{" "}
                            <em>Demo</em>
                        </span>
                    }}
                </div>
            }}
            {if not saved and not mode {
                <div key="artifact-choices" className="artifact-choices">
                    <button onClick={lambda { onMode("github"); }}>
                        <strong>GitHub repository</strong>
                        <span>Read the product and issue context</span>
                    </button>
                    <button onClick={lambda { onMode("files"); }}>
                        <strong>Docs or artifacts</strong>
                        <span>Briefs, notes, decks, screenshots</span>
                    </button>
                    <button onClick={lambda { onMode("contacts"); }}>
                        <strong>Warm lead contacts</strong>
                        <span>Keep for founder-approved outreach later</span>
                    </button>
                </div>
            }}
            {if not saved and mode == "github" {
                <div key="github-artifact" className="single-artifact-interface">
                    <button className="back-link" onClick={lambda { onMode(""); }}>
                        ← Choose another source
                    </button>
                    <label>
                        <span>Repository URL</span>
                        <input
                            value={value}
                            onChange={lambda (e: ChangeEvent) { onValue(
                                e.target.value
                            ); }}
                            placeholder="https://github.com/you/product"
                        />
                    </label>
                    <button
                        className="button primary"
                        onClick={onSave}
                        disabled={busy or not value.strip()}
                    >
                        Save repository
                    </button>
                </div>
            }}
            {if not saved and mode in ["files", "contacts"] {
                <div key="file-artifact" className="single-artifact-interface">
                    <button className="back-link" onClick={lambda { onMode(""); }}>
                        ← Choose another source
                    </button>
                    <label className="dropbox">
                        <input
                            type="file"
                            onChange={onFile}
                            accept={".csv"
                                if mode == "contacts"
                                else ".pdf,.doc,.docx,.txt,.md,.png,.jpg"}
                        />
                        <span className="drop-icon">↑</span>
                        <strong>
                            {"Drop a CSV of warm leads"
                                if mode == "contacts"
                                else "Drop product documents here"}
                        </strong>
                        <span>{value if value else "or click to choose a file"}</span>
                    </label>
                    <button
                        className="button primary"
                        onClick={onSave}
                        disabled={busy or not value}
                    >
                        Save source
                    </button>
                </div>
            }}
            {if saved {
                <div key="artifact-saved" className="completion-note">
                    <span>✓</span>
                    <p>
                        <strong>Source saved.</strong>{" "}
                        I’ll use it as supporting context—not as permission to contact anyone.
                    </p>
                </div>
            }}
            <div className="section-actions">
                {if saved {
                    <button key="add-another" className="button" onClick={onAnother}>
                        Add another source
                    </button>
                }}
                {if not saved {
                    <span key="action-spacer"></span>
                }}
                <button className="button primary" onClick={onContinue} disabled={busy}>
                    {"Creating personas…"
                        if busy
                        else (
                            "Skip for now →"
                                if not artifacts
                                else "Create potential personas →"
                        )}
                </button>
            </div>
        </section>;
}

def:pub PersonaScreen(
    personas: list[PersonaView],
    selected: list[str],
    note: str,
    input: str,
    onToggle: Callable[[str], None],
    onInput: Callable[[str], None],
    onSend: Callable[[FormEvent], None],
    onConfirm: Callable[[], None],
    busy: bool
) -> JsxElement {
    return
        <section className="workspace-section persona-screen">
            <p className="eyebrow">Understand · Conversation</p>
            <div className="chat-row agent-row persona-intro">
                <Mascot state="speaking"/>
                <div className="chat-bubble agent-bubble">
                    <span className="chat-label">Potential personas</span>
                    <h1 className="editorial">I found four useful research lenses.</h1>
                    <p>Select any card to include or exclude it.</p>
                </div>
            </div>
            <div className="persona-grid">
                {for persona in personas {
                    <button
                        key={persona.id}
                        className={"persona-card selected"
                            if persona.id in selected
                            else "persona-card"}
                        onClick={lambda { onToggle(persona.id); }}
                    >
                        <span className="card-select">
                            {"✓" if persona.id in selected else "+"}
                        </span>
                        <span className="persona-number">
                            Persona {str(personas.index(persona) + 1).zfill(2)}
                        </span>
                        <strong>{persona.title}</strong>
                        <p>{persona.description}</p>
                        <dl>
                            <dt>Pain</dt>
                            <dd>{persona.pain}</dd>
                            <dt>Observable signal</dt>
                            <dd>{persona.signal}</dd>
                            <dt>Learn</dt>
                            <dd>{persona.research_goal}</dd>
                        </dl>
                        <span className="source-plan">LinkedIn + GitHub only</span>
                    </button>
                }}
            </div>
            <div className="persona-conversation">
                {if note {
                    <div key="founder-persona-note" className="chat-row founder-row">
                        <div className="chat-bubble founder-bubble">
                            <span className="chat-label">You</span>
                            <p>{note}</p>
                        </div>
                    </div>
                }}
                {if note {
                    <div key="persona-ack" className="chat-row agent-row compact-row">
                        <Mascot state="completing"/>
                        <div className="chat-bubble agent-bubble acknowledgement">
                            Got it. I’ll use that when ranking who can teach us fastest.
                        </div>
                    </div>
                }}
                <div className="chat-row agent-row compact-row prompt-row">
                    <Mascot state="waiting"/>
                    <div className="chat-bubble agent-bubble prompt-bubble">
                        Anything to change or emphasize before I search?
                    </div>
                </div>
                <ChatComposer
                    value={input}
                    onValue={onInput}
                    onSubmit={onSend}
                    placeholder="Reply with a persona correction…"
                    busy={busy}
                    label="Send persona correction"
                />
            </div>
            <div className="section-actions">
                <span className="muted-note">
                    {str(len(selected))} research lenses selected
                </span>
                <button className="button primary" onClick={onConfirm} disabled={busy}>
                    {"Saving…" if busy else "Continue to search →"}
                </button>
            </div>
        </section>;
}

def:pub SearchScreen(
    onSearch: Callable[[], None], busy: bool, progress: int
) -> JsxElement {
    can with entry {
        onSearch();
    }

    return
        <section className="workspace-section search-screen">
            <div className="search-progress">
                <div>
                    <p className="eyebrow">Find · Public evidence</p>
                    <h1 className="editorial">Search for behavior</h1>
                </div>
                <div className="search-live-agent">
                    <Mascot state="searching"/>
                    <div className="stage-pulse">
                        <span></span>
                        {"Searching public pain signals"
                            if busy
                            else "Starting LinkedIn + GitHub search"}
                    </div>
                </div>
            </div>
            <div
                className="search-meter"
                role="progressbar"
                aria-label="Evidence search progress"
                aria-valuemin="0"
                aria-valuemax="100"
                aria-valuenow={progress}
            >
                <div className="search-meter-track">
                    <span
                        className="search-meter-fill"
                        style={{"width": str(progress) + "%"}}
                    ></span>
                </div>
                <strong>{str(progress)}%</strong>
            </div>
            <div className="search-grid">
                <SearchTask
                    icon="LinkedIn"
                    title="First-person pain posts"
                    detail="Scanning recent LinkedIn posts for moments where the problem is described in the person’s own words"
                    state={"searching" if progress < 30 else "complete"}
                    variant="linkedin"
                />
                <SearchTask
                    icon="LinkedIn"
                    title="Repeated workarounds"
                    detail="Looking for people who repeatedly use tours, meetups, saved maps, or introductions to solve the same need"
                    state={"queued"
                        if progress < 15
                        else ("searching" if progress < 52 else "complete")}
                    variant="linkedin"
                />
                <SearchTask
                    icon="LinkedIn"
                    title="Recent behavior signals"
                    detail="Checking recency, specificity, and whether the behavior is strong enough to ground a research conversation"
                    state={"queued"
                        if progress < 35
                        else ("reading" if progress < 74 else "complete")}
                    variant="linkedin"
                />
                <SearchTask
                    icon="LinkedIn"
                    title="Research usefulness"
                    detail="Ranking LinkedIn candidates by what each person can teach, not by a generic lead score"
                    state={"queued"
                        if progress < 55
                        else ("ranking" if progress < 92 else "complete")}
                    variant="linkedin"
                />
                <SearchTask
                    icon="GitHub"
                    title="GitHub behavior scan"
                    detail="Searching issues, discussions, prototypes, and abandoned workarounds for technical evidence close to the hypothesis"
                    state={"queued"
                        if progress < 25
                        else ("searching" if progress < 100 else "complete")}
                    variant="github wide"
                />
            </div>
            <div className="search-guardrail">
                <strong>Discovery boundary</strong>
                <span>
                    Only LinkedIn and GitHub are searched. No enrichment, purchased data, or guessed inboxes.
                </span>
            </div>
        </section>;
}

def:pub SearchTask(
    icon: str, title: str, detail: str, state: str, variant: str
) -> JsxElement {
    return
        <div className={"search-task " + variant + " " + state}>
            <div className="search-task-top">
                <span className="search-icon">{icon}</span>
                <span className="search-state">{state}</span>
            </div>
            <h2>{title}</h2>
            <p>{detail}</p>
            <div className="scan-lines">
                <span></span>
                <span></span>
                <span></span>
            </div>
        </div>;
}

def:pub ProspectResults(
    prospects: list[ProspectView],
    onPrepare: Callable[[], None],
    onProfile: Callable[[str], None],
    busy: bool
) -> JsxElement {
    return
        <section className="workspace-section prospect-results">
            <div className="section-heading split-heading">
                <div>
                    <p className="eyebrow">Find · 4 research prospects</p>
                    <h1 className="editorial">
                        Four people with evidence close to the hypothesis.
                    </h1>
                </div>
                <Mascot state="finding"/>
            </div>
            <div className="prospect-grid">
                {for (index, prospect) in enumerate(prospects) {
                    <article key={prospect.id} className="prospect-card">
                        <div className="prospect-head">
                            <span className="avatar">{prospect.initials}</span>
                            <div>
                                <h2>{prospect.name}</h2>
                                <p>{prospect.role}</p>
                                <span>{prospect.organization}</span>
                            </div>
                            <span className={"source-badge " + prospect.source.lower()}>
                                {prospect.source}
                            </span>
                        </div>
                        <blockquote>“{prospect.evidence}”</blockquote>
                        <a
                            className="evidence-link"
                            href={prospect.evidence_url}
                            target="_blank"
                            rel="noreferrer"
                        >
                            View original {prospect.source} evidence ↗
                        </a>
                        <div className="evidence-meta">
                            <span>{prospect.evidence_date}</span>
                            <span>
                                {str(
                                    int(prospect.confidence * 100.0)
                                )}% evidence confidence
                            </span>
                        </div>
                        <dl>
                            <dt>Why this person</dt>
                            <dd>{prospect.why_useful}</dd>
                            <dt>Research question</dt>
                            <dd>{prospect.research_question}</dd>
                            <dt>Assumption challenged</dt>
                            <dd>{prospect.assumption_challenged}</dd>
                        </dl>
                        <button
                            className="profile-link-button"
                            onClick={lambda { onProfile(prospect.id); }}
                        >
                            View full profile →
                        </button>
                    </article>
                }}
            </div>
            <div className="section-actions">
                <span className="muted-note">No one has been contacted.</span>
                <button className="button primary" onClick={onPrepare} disabled={busy}>
                    {"Drafting…" if busy else "Draft founder outreach →"}
                </button>
            </div>
        </section>;
}

def:pub StageEmpty(stage: str, onBack: Callable[[], None]) -> JsxElement {
    return
        <section className="focused-task stage-empty">
            <div className="task-agent">
                <Mascot state="waiting"/>
            </div>
            <p className="eyebrow">{stage} · Not ready yet</p>
            <h1 className="editorial">Let’s finish understanding the product first.</h1>
            <p className="lede">
                Once the conversation is complete, this step will be ready to open.
            </p>
            <button className="button primary" onClick={onBack}>
                Return to conversation →
            </button>
        </section>;
}

def:pub LeadLibrary(
    prospects: list[ProspectView],
    activities: list[ActivityView],
    selectedId: str,
    profileTab: str,
    onSelect: Callable[[str], None],
    onBack: Callable[[], None],
    onTab: Callable[[str], None],
    onOutreach: Callable[[], None]
) -> JsxElement {
    selected = find_prospect_from_list(prospects, selectedId) if selectedId else None;
    return
        <section className="workspace-section lead-library">
            {if selected is None {
                <div key="lead-directory">
                    <div className="section-heading split-heading">
                        <div>
                            <p className="eyebrow">Reach · Lead profiles</p>
                            <h1 className="editorial">People worth learning from.</h1>
                        </div>
                        <div className="workspace-heading-side">
                            <WorkspaceMascot pose="inspect"/>
                            <span className="directory-count">
                                {str(len(prospects))} profiles
                            </span>
                        </div>
                    </div>
                    <div className="lead-card-grid">
                        {for prospect in prospects {
                            <button
                                key={prospect.id}
                                className="lead-directory-card"
                                onClick={lambda {
                                    onSelect(prospect.id);
                                    onTab("overview");
                                }}
                            >
                                <div className="lead-card-topline">
                                    <span className="avatar lead-card-avatar">
                                        {prospect.initials}
                                    </span>
                                    <span
                                        className={"profile-status " + status_tone(
                                            prospect.status
                                        )}
                                    >
                                        {prospect.status}
                                    </span>
                                </div>
                                <div className="lead-card-identity">
                                    <h2>{prospect.name}</h2>
                                    <p>{prospect.role}</p>
                                    <span>{prospect.organization}</span>
                                </div>
                                <div className="lead-card-reason">
                                    <span>Why this person</span>
                                    <p>{prospect.why_useful}</p>
                                </div>
                                <div className="lead-card-footer">
                                    <span>{prospect.email}</span>
                                    <strong>Open profile →</strong>
                                </div>
                            </button>
                        }}
                    </div>
                </div>
            }}
            {if selected is not None {
                <article key={selected.id} className="lead-profile-page">
                    <button className="profile-back-button" onClick={onBack}>
                        ← All profiles
                    </button>
                    <div className="lead-profile-header profile-page-header">
                        <span className="avatar profile-avatar">
                            {selected.initials}
                        </span>
                        <div>
                            <span className="profile-kicker">Research prospect</span>
                            <h2>{selected.name}</h2>
                            <p>{selected.role} · {selected.organization}</p>
                        </div>
                        <div className="profile-header-side">
                            <WorkspaceMascot pose="inspect"/>
                            <div className="profile-header-actions">
                                <span
                                    className={"profile-status " + status_tone(
                                        selected.status
                                    )}
                                >
                                    {selected.status}
                                </span>
                                <button
                                    className="button primary profile-draft-cta"
                                    onClick={onOutreach}
                                >
                                    Draft outreach for {selected.name} →
                                </button>
                            </div>
                        </div>
                    </div>
                    <div className="profile-page-tabs" role="tablist">
                        <button
                            className={"profile-tab active"
                                if profileTab == "overview"
                                else "profile-tab"}
                            onClick={lambda { onTab("overview"); }}
                            role="tab"
                            aria-selected={profileTab == "overview"}
                        >
                            Overview
                        </button>
                        <button
                            className={"profile-tab active"
                                if profileTab == "activity"
                                else "profile-tab"}
                            onClick={lambda { onTab("activity"); }}
                            role="tab"
                            aria-selected={profileTab == "activity"}
                        >
                            Activity
                        </button>
                    </div>
                    {if profileTab == "overview" {
                        <div key="profile-overview" className="profile-tab-panel">
                            <div className="profile-overview-heading">
                                <div>
                                    <span className="profile-section-label">
                                        Contact
                                    </span>
                                    <h3>How to reach {selected.name}</h3>
                                </div>
                                <div className="profile-links compact-profile-links">
                                    <a
                                        href={selected.profile_url}
                                        target="_blank"
                                        rel="noreferrer"
                                    >
                                        {selected.source} profile ↗
                                    </a>
                                    <a
                                        href={selected.evidence_url}
                                        target="_blank"
                                        rel="noreferrer"
                                    >
                                        Source evidence ↗
                                    </a>
                                </div>
                            </div>
                            <div className="profile-contact-grid">
                                <div>
                                    <span>Email</span>
                                    <a href={"mailto:" + selected.email}>
                                        {selected.email}
                                    </a>
                                </div>
                                <div>
                                    <span>Phone</span>
                                    <a href={"tel:" + selected.phone}>
                                        {selected.phone}
                                    </a>
                                </div>
                                <div>
                                    <span>Location</span>
                                    <strong>{selected.location}</strong>
                                </div>
                            </div>
                            <div className="profile-overview-heading why-heading">
                                <div>
                                    <span className="profile-section-label">
                                        Research fit
                                    </span>
                                    <h3>Why this person</h3>
                                </div>
                            </div>
                            <div className="profile-evidence">
                                <span>
                                    Observed behavior · {selected.evidence_date}
                                </span>
                                <blockquote>“{selected.evidence}”</blockquote>
                                <strong>
                                    {str(int(selected.confidence * 100.0))}% confidence
                                </strong>
                            </div>
                            <dl className="profile-facts">
                                <div>
                                    <dt>Why this person</dt>
                                    <dd>{selected.why_useful}</dd>
                                </div>
                                <div>
                                    <dt>Question to ask</dt>
                                    <dd>{selected.research_question}</dd>
                                </div>
                                <div>
                                    <dt>Assumption challenged</dt>
                                    <dd>{selected.assumption_challenged}</dd>
                                </div>
                            </dl>
                        </div>
                    }}
                    {if profileTab == "activity" {
                        <LeadActivityPanel
                            key="profile-activity"
                            prospect={selected}
                            activities={activities}
                        />
                    }}
                </article>
            }}
        </section>;
}

def:pub LeadActivityPanel(
    prospect: ProspectView, activities: list[ActivityView]
) -> JsxElement {
    lead_activities = [
        activity
        for activity in activities
        if activity.prospect_name == prospect.name
    ];
    email_count = len(
        [
            activity
            for activity in lead_activities
            if activity.activity_type == "email"
        ]
    );
    call_count = len(
        [
            activity
            for activity in lead_activities
            if activity.activity_type == "call"
        ]
    );
    meeting_count = len(
        [
            activity
            for activity in lead_activities
            if activity.activity_type == "meeting"
        ]
    );
    return
        <div className="profile-tab-panel profile-activity-panel">
            <div className="profile-activity-summary">
                <div>
                    <span>Email</span>
                    <strong>{str(email_count)}</strong>
                </div>
                <div>
                    <span>Calls</span>
                    <strong>{str(call_count)}</strong>
                </div>
                <div>
                    <span>Meetings</span>
                    <strong>{str(meeting_count)}</strong>
                </div>
            </div>
            {if not lead_activities {
                <div key="profile-no-activity" className="profile-activity-empty">
                    <span>○</span>
                    <div>
                        <h3>No activity yet</h3>
                        <p>Email, call, and meeting history will appear here.</p>
                    </div>
                </div>
            }}
            {if lead_activities {
                <div key="profile-history" className="profile-history">
                    {for activity in lead_activities {
                        <article key={activity.id} className="profile-history-event">
                            <span
                                className={"history-event-icon " + activity.activity_type}
                            >
                                {"@"
                                    if activity.activity_type == "email"
                                    else (
                                        "☎"
                                            if activity.activity_type == "call"
                                            else "31"
                                    )}
                            </span>
                            <div className="history-event-content">
                                <div className="history-event-heading">
                                    <div>
                                        <span>{activity.channel}</span>
                                        <h3>{activity.label}</h3>
                                    </div>
                                    <span className="history-event-state">
                                        {activity.state}
                                    </span>
                                </div>
                                <p>{activity.timestamp} · {activity.identity}</p>
                                <div className="history-event-actions">
                                    {if activity.external_url {
                                        <a
                                            href={activity.external_url}
                                            target="_blank"
                                            rel="noreferrer"
                                        >
                                            {activity.link_label} ↗
                                        </a>
                                    }}
                                    {if activity.transcript {
                                        <span
                                            className={"learning-policy included"
                                                if activity.learnable
                                                else "learning-policy excluded"}
                                        >
                                            {"Feeds Learn"
                                                if activity.learnable
                                                else "Scheduling only"}
                                        </span>
                                    }}
                                </div>
                                {if activity.transcript {
                                    <details className="transcript-disclosure">
                                        <summary>{activity.transcript_title}</summary>
                                        <pre>{activity.transcript}</pre>
                                    </details>
                                }}
                            </div>
                        </article>
                    }}
                </div>
            }}
        </div>;
}

def:pub ActivityTimeline(activities: list[ActivityView]) -> JsxElement {
    return
        <div className="activity-timeline">
            {if not activities {
                <div key="timeline-empty" className="timeline-empty">
                    No external actions yet. Nothing is sent without founder approval.
                </div>
            }}
            {for activity in activities {
                <article key={activity.id} className="activity-row">
                    <span className="timeline-dot"></span>
                    <div className="activity-main">
                        <div>
                            <strong>{activity.label}</strong>
                            <span className="demo-pill">Demo</span>
                        </div>
                        <p>
                            {activity.prospect_name} · {activity.channel} · {activity.identity}
                        </p>
                        <small>{activity.timestamp} · {activity.state}</small>
                    </div>
                    <a href={activity.external_url} target="_blank" rel="noreferrer">
                        {activity.link_label} ↗
                    </a>
                </article>
            }}
        </div>;
}

def:pub OutreachWorkspace(
    founderName: str,
    founderEmail: str,
    prospects: list[ProspectView],
    selectedId: str,
    draftText: str,
    notice: str,
    onSelect: Callable[[str], None],
    onDraft: Callable[[str], None],
    onSend: Callable[[], None],
    onSkip: Callable[[MouseEvent], None],
    onTrack: Callable[[], None],
    onProfile: Callable[[str], None],
    busy: bool
) -> JsxElement {
    selected = find_prospect_from_list(prospects, selectedId);
    return
        <section className="workspace-section outreach-screen">
            <div className="section-heading split-heading outreach-heading">
                <div>
                    <p className="eyebrow">Reach · Founder approval</p>
                    <h1 className="editorial">
                        Write from the signal. Send as the founder.
                    </h1>
                </div>
                <div className="workspace-heading-side">
                    <WorkspaceMascot pose="send"/>
                    <button className="button" onClick={onTrack}>
                        Activity tracking →
                    </button>
                </div>
            </div>
            <div className="identity-strip">
                <span className="identity-avatar">BZ</span>
                <div>
                    <strong>Send as {founderName} via Gmail</strong>
                    <small>{founderEmail} · Founder, Traction</small>
                </div>
                <span className="connected">● Connected</span>
                <span className="demo-pill">Demo adapter</span>
            </div>
            <div className="outreach-layout">
                <aside className="prospect-queue">
                    {for prospect in prospects {
                        <button
                            key={prospect.id}
                            className={"queue-person active"
                                if selected is not None and prospect.id == selected.id
                                else "queue-person"}
                            onClick={lambda { onSelect(prospect.id); }}
                        >
                            <span className="avatar small-avatar">
                                {prospect.initials}
                            </span>
                            <span>
                                <strong>{prospect.name}</strong>
                                <small>{prospect.status} · {prospect.source}</small>
                            </span>
                            <span
                                className={"status-dot " + status_tone(prospect.status)}
                            ></span>
                        </button>
                    }}
                </aside>
                {if selected is not None {
                    <div key="draft-editor" className="draft-editor">
                        <div className="draft-context">
                            <div className="draft-context-heading">
                                <span>Grounded in</span>
                                <button
                                    className="profile-link-button compact"
                                    onClick={lambda { onProfile(selectedId); }}
                                >
                                    Open {selected.name}’s profile →
                                </button>
                            </div>
                            <blockquote>“{selected.evidence}”</blockquote>
                            <a
                                href={selected.evidence_url}
                                target="_blank"
                                rel="noreferrer"
                            >
                                View original post ↗
                            </a>
                        </div>
                        <div className="draft-lead-summary">
                            <div>
                                <span>Contact</span>
                                <a href={"mailto:" + selected.email}>
                                    {selected.email}
                                </a>
                                <a href={"tel:" + selected.phone}>{selected.phone}</a>
                                <small>{selected.location}</small>
                            </div>
                            <div>
                                <span>Why this lead</span>
                                <p>{selected.why_useful}</p>
                            </div>
                        </div>
                        <label>
                            <span>Subject</span>
                            <input value={selected.draft_subject} readOnly={True}/>
                        </label>
                        <label>
                            <span>Message</span>
                            <textarea
                                value={draftText}
                                onChange={lambda (e: ChangeEvent) { onDraft(
                                    e.target.value
                                ); }}
                                rows={12}
                            />
                        </label>
                        <div className="draft-checks">
                            <span>✓ First-person founder voice</span>
                            <span>✓ One specific signal</span>
                            <span>✓ Research ask, not sales</span>
                        </div>
                        {if notice {
                            <p key="outreach-notice" className="notice">{notice}</p>
                        }}
                        <div className="draft-actions">
                            <button className="button" onClick={onSkip}>Skip</button>
                            <button
                                className="button primary"
                                onClick={onSend}
                                disabled={busy or selected.status in ["Sent", "Booked"]}
                            >
                                {"Sending…"
                                    if busy
                                    else (
                                        "Already sent"
                                            if selected.status in ["Sent", "Booked"]
                                            else "Approve & send as Becky →"
                                    )}
                            </button>
                        </div>
                    </div>
                }}
            </div>
        </section>;
}

def find_prospect_from_list(
    prospects: list[ProspectView], selected_id: str
) -> ProspectView | None {
    for prospect in prospects {
        if prospect.id == selected_id {
            return prospect;
        }
    }
    return prospects[0] if prospects else None;
}

def pipeline_status(kind: str, status: str) -> str {
    if kind == "email" {
        if status in ["Call scheduled", "Booked"] {
            return "Replied";
        }
        if status == "Sent" {
            return "Sent";
        }
        return "Draft ready";
    }
    if kind == "call" {
        if status == "Booked" {
            return "Completed";
        }
        if status == "Call scheduled" {
            return "Scheduled";
        }
        if status == "Sent" {
            return "Ready after reply";
        }
        return "Waiting";
    }
    return "Booked" if status == "Booked" else "Not scheduled";
}

def:pub ActivityChannelColumn(
    kind: str,
    icon: str,
    title: str,
    prospects: list[ProspectView],
    activities: list[ActivityView]
) -> JsxElement {
    channel_activities: list[ActivityView] = [];
    completed = 0;
    for activity in activities {
        if (kind == "email" and activity.channel == "Gmail")
        or (kind == "call" and activity.channel == "Phone")
        or (kind == "meeting" and activity.channel in ["Google Calendar", "Zoom"]) {
            channel_activities.append(activity);
        }
    }
    for prospect in prospects {
        if (
            kind == "email"
            and prospect.status in ["Sent", "Call scheduled", "Booked"]
        )
        or (kind in ["call", "meeting"] and prospect.status == "Booked") {
            completed += 1;
        }
    }
    total = len(prospects);
    progress = int(float(completed) * 100.0 / float(total)) if total else 0;
    return
        <article className="activity-channel-column">
            <div className="channel-column-header">
                <span className="channel-icon">{icon}</span>
                <div>
                    <span className="channel-kicker">
                        {str(completed)} of {str(total)}
                    </span>
                    <h2>{title}</h2>
                </div>
                <strong>{str(progress)}%</strong>
            </div>
            <div className="channel-progress">
                <span style={{"width": str(progress) + "%"}}></span>
            </div>
            <div className="channel-leads">
                {for prospect in prospects {
                    <div key={prospect.id} className="channel-lead-row">
                        <span className="avatar tiny-avatar">{prospect.initials}</span>
                        <span>
                            <strong>{prospect.name}</strong>
                            <small>{pipeline_status(kind, prospect.status)}</small>
                        </span>
                        <span
                            className={"pipeline-state done"
                                if (
                                    kind == "email"
                                    and prospect.status in [
                                        "Sent", "Call scheduled", "Booked"
                                    ]
                                )
                                or (
                                    kind in ["call", "meeting"]
                                    and prospect.status == "Booked"
                                )
                                else (
                                    "pipeline-state active"
                                        if kind == "call"
                                        and prospect.status in [
                                            "Sent", "Call scheduled"
                                        ]
                                        else "pipeline-state"
                                )}
                        ></span>
                    </div>
                }}
            </div>
            <div className="channel-events">
                <span className="channel-events-label">Latest activity</span>
                {if not channel_activities {
                    <p key="empty-channel">Nothing recorded yet.</p>
                }}
                {for activity in channel_activities {
                    <div key={activity.id} className="channel-event">
                        <span className="timeline-dot"></span>
                        <div>
                            <strong>{activity.label}</strong>
                            <small>
                                {activity.prospect_name} · {activity.timestamp}
                            </small>
                        </div>
                    </div>
                }}
            </div>
        </article>;
}

def scheduled_call_time(name: str) -> str {
    if name == "Priya Shah" {
        return "Today · 2:40 PM PT";
    }
    if name == "Jordan Lee" {
        return "Tomorrow · 9:15 AM PT";
    }
    return "Today · 1:10 PM PT";
}

def:pub AgentCallOperations(
    prospects: list[ProspectView],
    onSchedule: Callable[[], None],
    onCall: Callable[[str], None],
    busy: bool
) -> JsxElement {
    sent: ProspectView | None = None;
    scheduled: ProspectView | None = None;
    booked: ProspectView | None = None;
    scheduled_id = "";
    scheduled_name = "";
    scheduled_time = "";
    for prospect in prospects {
        if prospect.status == "Call scheduled" and scheduled is None {
            scheduled = prospect;
            scheduled_id = prospect.id;
            scheduled_name = prospect.name;
            scheduled_time = scheduled_call_time(prospect.name);
        } elif prospect.status == "Sent" and sent is None {
            sent = prospect;
        } elif prospect.status == "Booked" and booked is None {
            booked = prospect;
        }
    }
    focus = scheduled if scheduled is not None else (
        sent if sent is not None else booked
    );
    return
        <div className="agent-call-operations">
            <div className="call-operations-heading">
                <div>
                    <span className="profile-section-label">Agent call queue</span>
                    <h2>Upcoming and live scheduling calls</h2>
                </div>
                <span className="call-automation-badge">Agent books the calls</span>
            </div>
            <div className="call-operations-grid">
                <article className="upcoming-call-card">
                    <div className="call-card-topline">
                        <span className="call-card-icon">☎</span>
                        <span className={"call-state ready"
                            if scheduled is not None
                            else (
                                "call-state complete"
                                    if booked is not None
                                    else "call-state waiting"
                            )}
                        >
                            {"Scheduled"
                                if scheduled is not None
                                else (
                                    "Completed"
                                        if booked is not None
                                        else "Waiting for reply"
                                )}
                        </span>
                    </div>
                    <span className="profile-section-label">Upcoming call</span>
                    {if focus is not None {
                        <div key={focus.id} className="upcoming-call-person">
                            <span className="avatar">{focus.initials}</span>
                            <div>
                                <h3>{focus.name}</h3>
                                <p>{focus.role}</p>
                            </div>
                        </div>
                    }}
                    {if scheduled is not None {
                        <div key="scheduled-call-detail" className="call-schedule-detail">
                            <strong>{scheduled_time}</strong>
                            <span>4-minute scheduling call · Phone</span>
                            <p>
                                Reply detected. Traction immediately placed this call on the queue.
                            </p>
                        </div>
                    }}
                    {if sent is not None and scheduled is None {
                        <div key="reply-wait" className="call-schedule-detail">
                            <strong>Monitoring the email thread</strong>
                            <span>Traction will book the call when a reply arrives.</span>
                            <button
                                className="button primary"
                                onClick={onSchedule}
                                disabled={busy}
                            >
                                {"Booking…"
                                    if busy
                                    else "Simulate reply → book call"}
                            </button>
                        </div>
                    }}
                    {if booked is not None and scheduled is None and sent is None {
                        <div key="call-complete" className="call-schedule-detail">
                            <strong>Scheduling call completed</strong>
                            <span>The transcript is saved in the lead’s Activity tab.</span>
                        </div>
                    }}
                </article>
                <article className="live-call-monitor-card">
                    <div className="live-monitor-status" aria-hidden="true">
                        <span className="live-monitor-phone">☎</span>
                        <span className={"live-monitor-dot active"
                            if scheduled is not None
                            else "live-monitor-dot"}
                        ></span>
                    </div>
                    <div>
                        <span className="profile-section-label">Live call monitor</span>
                        <h3>
                            {"Ready to call " + scheduled_name
                                if scheduled is not None
                                else (
                                    "Last call completed"
                                        if booked is not None
                                        else "No call is live yet"
                                )}
                        </h3>
                        <p>
                            Watch both sides speak as a live transcript. Scheduling calls are saved, but never used by Learn.
                        </p>
                    </div>
                    {if scheduled is not None {
                        <button
                            className="button primary"
                            onClick={lambda { onCall(scheduled_id); }}
                        >
                            Start & watch live →
                        </button>
                    }}
                </article>
            </div>
        </div>;
}

def:pub ActivityWorkspace(
    workspace: WorkspaceView,
    onScheduleCall: Callable[[], None],
    onCall: Callable[[str], None],
    onOutreach: Callable[[], None],
    onCalendar: Callable[[], None],
    onLearn: Callable[[], None],
    busy: bool
) -> JsxElement {
    has_booked = False;
    has_sent = False;
    for prospect in workspace.prospects {
        if prospect.status == "Booked" {
            has_booked = True;
            has_sent = True;
        } elif prospect.status in ["Sent", "Call scheduled"] {
            has_sent = True;
        }
    }
    return
        <section className="workspace-section activity-workspace">
            <div className="section-heading split-heading activity-heading">
                <div>
                    <p className="eyebrow">Reach · Activity tracking</p>
                    <h1 className="editorial">Outreach activity</h1>
                </div>
                <div className="workspace-heading-side">
                    <WorkspaceMascot pose="writing"/>
                    <div className="activity-total">
                        <strong>{str(len(workspace.activities))}</strong>
                        <span>recorded events</span>
                    </div>
                </div>
            </div>
            {if has_sent {
                <AgentCallOperations
                    key="agent-call-operations"
                    prospects={workspace.prospects}
                    onSchedule={onScheduleCall}
                    onCall={onCall}
                    busy={busy}
                />
            }}
            <div className="activity-channel-grid">
                <ActivityChannelColumn
                    kind="email"
                    icon="@"
                    title="Emails"
                    prospects={workspace.prospects}
                    activities={workspace.activities}
                />
                <ActivityChannelColumn
                    kind="call"
                    icon="☎"
                    title="Calls"
                    prospects={workspace.prospects}
                    activities={workspace.activities}
                />
                <ActivityChannelColumn
                    kind="meeting"
                    icon="31"
                    title="Meetings"
                    prospects={workspace.prospects}
                    activities={workspace.activities}
                />
            </div>
            {if not has_sent {
                <div key="activity-needs-outreach" className="next-action-card">
                    <div>
                        <span className="eyebrow">No outreach sent yet</span>
                        <h2>Approve a founder email to start tracking activity.</h2>
                    </div>
                    <button className="button primary" onClick={onOutreach}>
                        Review drafts →
                    </button>
                </div>
            }}
            {if has_booked {
                <div
                    key="activity-to-calendar"
                    className="next-action-card completed-next-action"
                >
                    <div>
                        <span className="eyebrow">Meeting booked</span>
                        <h2>The demo meeting is on both calendars.</h2>
                        <p>
                            Open Calendar for the schedule, or continue to Learn after the meeting.
                        </p>
                    </div>
                    <div className="next-action-buttons">
                        <button className="button primary" onClick={onCalendar}>
                            Open Calendar →
                        </button>
                        <button className="button" onClick={onLearn}>
                            Learn backlog
                        </button>
                    </div>
                </div>
            }}
        </section>;
}

def:pub LiveCallWorkspace(
    workspace: WorkspaceView,
    prospectId: str,
    step: int,
    active: bool,
    onBack: Callable[[], None],
    onCalendar: Callable[[], None]
) -> JsxElement {
    prospect = find_prospect(workspace, prospectId);
    prospect_name = "the lead";
    if prospect is not None {
        prospect_name = prospect.name;
    }
    timer = "00:0" + str(step + 1) if step < 9 else "00:10";
    return
        <section className="workspace-section live-call-workspace">
            <div className="live-call-topbar">
                <button className="back-link" onClick={onBack} disabled={active}>
                    ← Activity tracking
                </button>
                <div className={"live-call-status on-air" if active else "live-call-status"}>
                    <span></span>
                    {"Live · " + timer if active else "Call complete · 04:08"}
                </div>
            </div>
            <div className="live-call-shell">
                <div className="live-call-people">
                    <div className="call-agent-portrait">
                        <Mascot state={"speaking" if active else "completing"}/>
                        <span>Traction agent</span>
                        <strong>Calling for Becky</strong>
                    </div>
                    <div className="call-connection-line">
                        <span></span>
                        <small>Phone · secure line</small>
                    </div>
                    {if prospect is not None {
                        <div key={prospect.id} className="call-participant-portrait">
                            <span className="avatar">{prospect.initials}</span>
                            <span>{prospect.name}</span>
                            <strong>{prospect.role}</strong>
                        </div>
                    }}
                </div>
                <div className="live-transcript-panel">
                    <div className="live-transcript-header">
                        <div>
                            <span className="profile-section-label">Live transcript</span>
                            <h1>Scheduling the founder demo</h1>
                        </div>
                        <span className="learning-policy excluded">
                            Scheduling only · Excluded from Learn
                        </span>
                    </div>
                    <div className="live-transcript-thread" aria-live="polite">
                        {if step >= 1 {
                            <div key="call-line-1" className="live-transcript-row agent-speaking">
                                <span>Traction</span>
                                <p>
                                    Hi {prospect_name}—this is Traction calling on Becky’s behalf. You replied about a short research chat. Do you have a minute to find a time?
                                </p>
                            </div>
                        }}
                        {if step >= 2 {
                            <div key="call-line-2" className="live-transcript-row participant-speaking">
                                <span>{prospect_name}</span>
                                <p>Yes. Tuesday morning would work well.</p>
                            </div>
                        }}
                        {if step >= 3 {
                            <div key="call-line-3" className="live-transcript-row agent-speaking">
                                <span>Traction</span>
                                <p>
                                    Becky has 10:30 AM Pacific open for 25 minutes. Should I book that?
                                </p>
                            </div>
                        }}
                        {if step >= 4 {
                            <div key="call-line-4" className="live-transcript-row participant-speaking">
                                <span>{prospect_name}</span>
                                <p>10:30 works. Please send me the invite.</p>
                            </div>
                        }}
                        {if step >= 5 {
                            <div key="call-line-5" className="live-transcript-row agent-speaking">
                                <span>Traction</span>
                                <p>
                                    Done. I’ve added the calendar invite and Zoom link to both calendars. See you Tuesday.
                                </p>
                            </div>
                        }}
                        {if active and step < 5 {
                            <div
                                key="live-typing"
                                className={"live-transcript-typing participant-speaking"
                                    if step in [1, 3]
                                    else "live-transcript-typing agent-speaking"}
                            >
                                <span>{prospect_name if step in [1, 3] else "Traction"}</span>
                                <div className="typing-dots">
                                    <span></span><span></span><span></span>
                                </div>
                            </div>
                        }}
                        {if active and step >= 5 {
                            <div key="booking-typing" className="live-booking-status">
                                <span className="typing-dots">
                                    <span></span><span></span><span></span>
                                </span>
                                Booking the meeting and syncing calendars…
                            </div>
                        }}
                    </div>
                    {if not active and step >= 6 {
                        <div key="call-booked" className="live-call-complete">
                            <div>
                                <span className="profile-section-label">Booked</span>
                                <h2>Tuesday, July 28 · 10:30 AM PT</h2>
                                <p>25-minute founder demo · Calendar invite and Zoom link sent.</p>
                            </div>
                            <div className="next-action-buttons">
                                <button className="button" onClick={onBack}>
                                    Back to activity
                                </button>
                                <button className="button primary" onClick={onCalendar}>
                                    View in Calendar →
                                </button>
                            </div>
                        </div>
                    }}
                </div>
            </div>
        </section>;
}

def:pub CalendarDay(
    label: str,
    date: str,
    active: bool,
    prospects: list[ProspectView],
    onProfile: Callable[[str], None]
) -> JsxElement {
    return
        <div className={"calendar-day active-day" if active else "calendar-day"}>
            <div className="calendar-day-heading">
                <span>{label}</span>
                <strong>{date}</strong>
            </div>
            <div className="calendar-slot"></div>
            <div className="calendar-slot"></div>
            <div className="calendar-slot"></div>
            <div className="calendar-slot"></div>
            {if active {
                <div key="calendar-events" className="calendar-events-layer">
                    {for prospect in prospects {
                        <button
                            key={prospect.id}
                            className="calendar-meeting-event"
                            onClick={lambda { onProfile(prospect.id); }}
                        >
                            <span>10:30–10:55</span>
                            <strong>Founder demo · {prospect.name}</strong>
                            <small>Zoom · Traction research</small>
                        </button>
                    }}
                </div>
            }}
        </div>;
}

def:pub CalendarWorkspace(
    workspace: WorkspaceView,
    notice: str,
    onActivity: Callable[[], None],
    onProfile: Callable[[str], None],
    onSync: Callable[[], None]
) -> JsxElement {
    booked: list[ProspectView] = [];
    for prospect in workspace.prospects {
        if prospect.status == "Booked" {
            booked.append(prospect);
        }
    }
    return
        <section className="workspace-section calendar-workspace">
            <div className="section-heading split-heading calendar-heading">
                <div>
                    <p className="eyebrow">Reach · Calendar</p>
                    <h1 className="editorial">Founder demo schedule</h1>
                </div>
                <div className="workspace-heading-side calendar-heading-side">
                    <WorkspaceMascot pose="coffee"/>
                    <div className="calendar-connection-card">
                        <span className="calendar-provider-icon">31</span>
                        <div>
                            <span>Google Calendar</span>
                            <strong>
                                {workspace.founder_email}
                                {" · Connected" if workspace.calendar_connected else ""}
                            </strong>
                        </div>
                        <button className="button small" onClick={onSync}>
                            {"Synced ✓"
                                if notice
                                else (
                                    "Sync now"
                                        if workspace.calendar_connected
                                        else "Connect Google Calendar"
                                )}
                        </button>
                    </div>
                </div>
            </div>
            <div className="calendar-toolbar">
                <div>
                    <button className="button small">Today</button>
                    <button className="calendar-arrow" aria-label="Previous week">←</button>
                    <button className="calendar-arrow" aria-label="Next week">→</button>
                    <strong>July 27–31, 2026</strong>
                </div>
                <span>{str(len(booked))} booked demo meeting{"s" if len(booked) != 1 else ""}</span>
            </div>
            <div className="calendar-layout">
                <div className="calendar-week">
                    <div className="calendar-time-column">
                        <span></span>
                        <span>9 AM</span>
                        <span>10 AM</span>
                        <span>11 AM</span>
                        <span>12 PM</span>
                    </div>
                    <CalendarDay
                        label="Mon" date="27" active={False}
                        prospects={booked} onProfile={onProfile}
                    />
                    <CalendarDay
                        label="Tue" date="28" active={True}
                        prospects={booked} onProfile={onProfile}
                    />
                    <CalendarDay
                        label="Wed" date="29" active={False}
                        prospects={booked} onProfile={onProfile}
                    />
                    <CalendarDay
                        label="Thu" date="30" active={False}
                        prospects={booked} onProfile={onProfile}
                    />
                    <CalendarDay
                        label="Fri" date="31" active={False}
                        prospects={booked} onProfile={onProfile}
                    />
                    {if not booked {
                        <div key="calendar-empty" className="calendar-empty-state">
                            <span>○</span>
                            <strong>No demo meetings booked yet</strong>
                            <p>Confirmed calls will appear here automatically.</p>
                        </div>
                    }}
                </div>
                <aside className="calendar-agenda">
                    <div className="calendar-agenda-heading">
                        <span className="profile-section-label">Upcoming</span>
                        <h2>Demo meetings</h2>
                    </div>
                    {if not booked {
                        <div key="agenda-empty" className="agenda-empty">
                            <p>Traction adds meetings here when a scheduling call confirms a time.</p>
                            <button className="button" onClick={onActivity}>
                                Open activity tracking →
                            </button>
                        </div>
                    }}
                    {for prospect in booked {
                        <article key={prospect.id} className="agenda-meeting-card">
                            <div className="agenda-date">
                                <span>JUL</span>
                                <strong>28</strong>
                            </div>
                            <div>
                                <span>Tuesday · 10:30 AM PT</span>
                                <h3>Founder demo with {prospect.name}</h3>
                                <p>25 minutes · Zoom · Both calendars confirmed</p>
                                <button
                                    className="profile-link-button"
                                    onClick={lambda { onProfile(prospect.id); }}
                                >
                                    Open lead profile →
                                </button>
                            </div>
                        </article>
                    }}
                </aside>
            </div>
        </section>;
}

def:pub LearningWorkspace(
    workspace: WorkspaceView,
    onActivity: Callable[[], None],
    onLearn: Callable[[], None],
    busy: bool
) -> JsxElement {
    has_booked = False;
    learn_sources: list[ActivityView] = [];
    for prospect in workspace.prospects {
        if prospect.status == "Booked" {
            has_booked = True;
        }
    }
    for activity in workspace.activities {
        if activity.learnable and activity.transcript {
            learn_sources.append(activity);
        }
    }
    return
        <section className="workspace-section learning-screen">
            <div className="section-heading split-heading">
                <div>
                    <p className="eyebrow">Learn · Backlog</p>
                    <h1 className="editorial">
                        Turn the conversation into a better next search.
                    </h1>
                </div>
                <div className="workspace-heading-side">
                    <WorkspaceMascot pose={"writing"
                        if workspace.insights else "inspect"}/>
                </div>
            </div>
            {if not has_booked {
                <div key="learn-waiting" className="learn-waiting-card">
                    <span className="learn-waiting-icon">○</span>
                    <div>
                        <h2>No completed conversation yet.</h2>
                        <p>
                            Book a research meeting from Activity tracking before generating insights.
                        </p>
                    </div>
                    <button className="button" onClick={onActivity}>
                        Open activity tracking →
                    </button>
                </div>
            }}
            {if has_booked and not workspace.insights {
                <div key="synthesize-interview" className="meeting-ready-card">
                    <div className="meeting-ready-meta">
                        <span>Research session</span>
                        <strong>Tuesday · 10:30 AM PT</strong>
                        <small>
                            Only the research meeting will be used for learning.
                        </small>
                    </div>
                    <div>
                        <h2>
                            The meeting is booked. Process the conversation when it ends.
                        </h2>
                        <p>
                            For this demo, the agent will generate interview insights and update the working hypothesis.
                        </p>
                    </div>
                    <button
                        className="button primary"
                        onClick={onLearn}
                        disabled={busy}
                    >
                        {"Processing…" if busy else "Process demo meeting →"}
                    </button>
                </div>
            }}
            {if not learn_sources {
                <div key="learn-preview" className="learn-preview">
                    <div className="learn-preview-heading">
                        <div>
                            <span className="profile-section-label">
                                Preview · Sample data
                            </span>
                            <h2>What Learn will produce after a research meeting</h2>
                        </div>
                        <span className="learning-policy excluded">Placeholder</span>
                    </div>
                    <div className="learn-preview-grid">
                        <article className="sample-transcript-card">
                            <span>Sample meeting transcript</span>
                            <div className="sample-transcript">
                                <p>
                                    <strong>Founder</strong>
                                    What makes arriving somewhere alone feel difficult?
                                </p>
                                <p>
                                    <strong>Participant</strong>
                                    Recommendations are easy to find. Trusting the first introduction is harder.
                                </p>
                                <p>
                                    <strong>Founder</strong>
                                    What would make you accept one?
                                </p>
                                <p>
                                    <strong>Participant</strong>
                                    I’d want to know why both of us opted in before we met.
                                </p>
                            </div>
                        </article>
                        <div className="learn-placeholder-list">
                            <article>
                                <span>Strongest signal</span>
                                <h3>Waiting for a completed research meeting</h3>
                                <div className="learn-placeholder-line"></div>
                            </article>
                            <article>
                                <span>Hypothesis change</span>
                                <h3>What the conversation changes</h3>
                                <div className="learn-placeholder-line"></div>
                            </article>
                            <article>
                                <span>Next search</span>
                                <h3>Which behavior to look for next</h3>
                                <div className="learn-placeholder-line"></div>
                            </article>
                        </div>
                    </div>
                    <p className="learn-preview-policy">
                        Calls remain in the profile Activity log. Only research meetings populate Learn.
                    </p>
                </div>
            }}
            {if learn_sources {
                <div key="learn-sources" className="learn-source-section">
                    <div className="learn-source-heading">
                        <div>
                            <span className="profile-section-label">
                                Meeting sources
                            </span>
                            <h2>Research used for this update</h2>
                        </div>
                        <span>{str(len(learn_sources))} included</span>
                    </div>
                    {for source in learn_sources {
                        <article key={source.id} className="learn-source-card">
                            <div className="learn-source-meta">
                                <span className="history-event-icon meeting">31</span>
                                <div>
                                    <span>
                                        {source.prospect_name} · {source.timestamp}
                                    </span>
                                    <h3>{source.label}</h3>
                                </div>
                                <span className="learning-policy included">
                                    Meeting · Included
                                </span>
                            </div>
                            <details className="transcript-disclosure learn-transcript">
                                <summary>{source.transcript_title}</summary>
                                <pre>{source.transcript}</pre>
                            </details>
                        </article>
                    }}
                    <p className="learn-source-policy">
                        Scheduling-call transcripts stay in each lead’s Activity tab and are not used for synthesis.
                    </p>
                </div>
            }}
            {if workspace.insights {
                <div key="insights" className="insights-section">
                    <div className="insight-summary">
                        <span className="version-badge">
                            Hypothesis v{str(workspace.hypothesis_version)}
                        </span>
                        <div>
                            <h2>Updated: mutual intent before local discovery</h2>
                            <p>
                                Travelers value one trusted, mutual-intent local connection at arrival more than recommendation volume.
                            </p>
                        </div>
                    </div>
                    <div className="insight-grid">
                        {for insight in workspace.insights {
                            <article key={insight.id}>
                                <span>Interview insight</span>
                                <h3>{insight.label}</h3>
                                <p>{insight.detail}</p>
                                <blockquote>“{insight.evidence}”</blockquote>
                                <footer>{insight.impact}</footer>
                            </article>
                        }}
                    </div>
                    <div className="loop-visual">
                        <span>Hypothesis</span>
                        <span className="loop-arrow">→</span>
                        <span>Signal</span>
                        <span className="loop-arrow">→</span>
                        <span>Person</span>
                        <span className="loop-arrow">→</span>
                        <span>Conversation</span>
                        <span className="loop-arrow">→</span>
                        <span className="active">Better next search</span>
                    </div>
                </div>
            }}
        </section>;
}

def:pub LegacyLearningWorkspace(
    workspace: WorkspaceView,
    onBook: Callable[[], None],
    onLearn: Callable[[], None],
    busy: bool
) -> JsxElement {
    has_booked = False;
    for prospect in workspace.prospects {
        if prospect.status == "Booked" {
            has_booked = True;
        }
    }
    return
        <section className="workspace-section learning-screen">
            <div className="section-heading split-heading">
                <div>
                    <p className="eyebrow">Reach → Learn</p>
                    <h1 className="editorial">External activity</h1>
                </div>
                <Mascot state={"completing" if workspace.insights else "waiting"}/>
            </div>
            <div className="integration-row">
                <div>
                    <span className="integration-icon">M</span>
                    <strong>Gmail</strong>
                    <small>Send as Becky Zhu</small>
                    <em>Connected · Demo</em>
                </div>
                <div>
                    <span className="integration-icon">31</span>
                    <strong>Google Calendar</strong>
                    <small>Book both sides</small>
                    <em>Connected · Demo</em>
                </div>
                <div>
                    <span className="integration-icon">Z</span>
                    <strong>Zoom</strong>
                    <small>Meeting link + agent notes</small>
                    <em>Connected · Demo</em>
                </div>
            </div>
            <div className="subheading">
                <h2>Activity timeline</h2>
                <span>{str(len(workspace.activities))} tracked events</span>
            </div>
            <ActivityTimeline activities={workspace.activities}/>
            {if not has_booked {
                <div key="book-meeting" className="next-action-card">
                    <div>
                        <span className="eyebrow">Demo next action</span>
                        <h2>Simulate an interested reply and book the meeting</h2>
                    </div>
                    <button className="button primary" onClick={onBook} disabled={busy}>
                        {"Booking…" if busy else "Book demo meeting →"}
                    </button>
                </div>
            }}
            {if has_booked and not workspace.insights {
                <div key="synthesize-interview" className="next-action-card">
                    <div>
                        <span className="eyebrow">Meeting booked</span>
                        <h2>Let the agent join, listen, and update the hypothesis</h2>
                    </div>
                    <button
                        className="button primary"
                        onClick={onLearn}
                        disabled={busy}
                    >
                        {"Synthesizing…" if busy else "Synthesize demo interview →"}
                    </button>
                </div>
            }}
            {if workspace.insights {
                <div key="insights" className="insights-section">
                    <div className="insight-summary">
                        <span className="version-badge">
                            Hypothesis v{str(workspace.hypothesis_version)}
                        </span>
                        <div>
                            <h2>Updated: mutual intent before local discovery</h2>
                            <p>
                                Travelers value one trusted, mutual-intent local connection at arrival more than recommendation volume.
                            </p>
                        </div>
                    </div>
                    <div className="insight-grid">
                        {for insight in workspace.insights {
                            <article key={insight.id}>
                                <span>Interview insight</span>
                                <h3>{insight.label}</h3>
                                <p>{insight.detail}</p>
                                <blockquote>“{insight.evidence}”</blockquote>
                                <footer>{insight.impact}</footer>
                            </article>
                        }}
                    </div>
                    <div className="loop-visual">
                        <span>Hypothesis</span>
                        <span className="loop-arrow">→</span>
                        <span>Signal</span>
                        <span className="loop-arrow">→</span>
                        <span>Person</span>
                        <span className="loop-arrow">→</span>
                        <span>Conversation</span>
                        <span className="loop-arrow">→</span>
                        <span className="active">Updated hypothesis</span>
                    </div>
                </div>
            }}
        </section>;
}

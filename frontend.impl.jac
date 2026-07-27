"""Event and RPC implementations for the Traction stateful shell."""

impl TractionApp.load_workspace -> None {
    next_workspace = await bootstrap_workspace();
    workspace = next_workspace;
    if next_workspace.product_description {
        apply_workspace(next_workspace);
        if next_workspace.insights {
            phase = "LEARNING_FROM_MEETING";
        } elif next_workspace.activities {
            phase = "TRACKING_EXTERNAL_ACTIVITY";
        } elif next_workspace.prospects and next_workspace.prospects[0].draft_body {
            phase = "WAITING_FOR_APPROVAL";
            selected_prospect_id = next_workspace.prospects[0].id;
            draft_text = next_workspace.prospects[0].draft_body;
        } elif next_workspace.prospects {
            phase = "REVIEWING_PROSPECTS";
        } elif next_workspace.personas {
            source_step = "complete";
            github_answered = True;
            document_answered = True;
            warm_leads_answered = True;
            phase = "REVIEWING_PERSONAS";
        } elif next_workspace.understanding_confirmed {
            source_step = "leads";
            github_answered = True;
            document_answered = True;
            phase = "WAITING_FOR_CHOICE";
        } else {
            source_step = "github";
            phase = "WAITING_FOR_CHOICE";
        }
    } else {
        phase = "EMPTY";
    }
}

impl TractionApp.apply_workspace(next_workspace: WorkspaceView) -> None {
    workspace = next_workspace;
    product_description = next_workspace.product_description;
    understanding_note = next_workspace.understanding_note;
    persona_note = next_workspace.persona_note;
    if next_workspace.personas {
        selected_personas = [
            persona.id
            for persona in next_workspace.personas
            if persona.approved
        ];
    }
    if next_workspace.understanding is not None {
        job = next_workspace.understanding.job;
        audience = next_workspace.understanding.audience;
        moment = next_workspace.understanding.moment;
        alternative = next_workspace.understanding.alternative;
        difference = next_workspace.understanding.difference;
        learning_goal = next_workspace.understanding.learning_goal;
    }
}

impl TractionApp.start_discovery(e: FormEvent) -> None {
    e.preventDefault();
    if not product_description.strip() {
        return;
    }
    busy = True;
    understanding_input = "";
    understanding_note = "";
    source_step = "github";
    github_input = "";
    document_value = "";
    warm_lead_input = "";
    github_answered = False;
    document_answered = False;
    warm_leads_answered = False;
    persona_input = "";
    persona_note = "";
    phase = "ANALYZING_PRODUCT";
    await demo_wait(1200);
    next_workspace = await begin_product(product_description);
    apply_workspace(next_workspace);
    busy = False;
    phase = "WAITING_FOR_CHOICE";
}

impl TractionApp.use_demo_brief(_e: MouseEvent) -> None {
    product_description = "A social app that helps solo travelers meet locals for thoughtful, non-transactional in-person experiences. Instead of another guide or tour marketplace, it uses shared interests and mutual context to make the first connection in a new city feel natural.";
}

impl TractionApp.send_understanding_correction(e: FormEvent) -> None {
    e.preventDefault();
    if not understanding_input.strip() {
        return;
    }
    understanding_note = understanding_input.strip();
    understanding_input = "";
}

impl TractionApp.save_understanding -> None {
    if understanding_input.strip() {
        understanding_note = understanding_input.strip();
        understanding_input = "";
    }
    busy = True;
    next_workspace = await confirm_understanding(
        job,
        audience,
        moment,
        alternative,
        difference,
        learning_goal,
        understanding_note
    );
    apply_workspace(next_workspace);
    artifact_mode = "";
    artifact_saved = False;
    source_step = "leads";
    warm_leads_answered = False;
    busy = False;
    phase = "WAITING_FOR_CHOICE";
}

impl TractionApp.submit_github(e: FormEvent) -> None {
    e.preventDefault();
    if not github_input.strip() {
        return;
    }
    busy = True;
    github_input = github_input.strip();
    github_answered = True;
    next_workspace = await add_artifact("GitHub", github_input, github_input);
    apply_workspace(next_workspace);
    await demo_wait(520);
    source_step = "documents";
    busy = False;
}

impl TractionApp.skip_github -> None {
    busy = True;
    github_answered = True;
    await demo_wait(420);
    source_step = "documents";
    busy = False;
}

impl TractionApp.capture_conversation_file(_e: ChangeEvent) -> None {
    document_value = "product-brief.pdf";
}

impl TractionApp.save_conversation_document -> None {
    if not document_value {
        return;
    }
    busy = True;
    document_answered = True;
    next_workspace = await add_artifact("Document", document_value, "");
    apply_workspace(next_workspace);
    await demo_wait(520);
    source_step = "inference";
    phase = "ANALYZING_CONTEXT";
    await demo_wait(1000);
    busy = False;
    phase = "CONFIRMING_UNDERSTANDING";
}

impl TractionApp.skip_conversation_document -> None {
    busy = True;
    document_answered = True;
    await demo_wait(420);
    source_step = "inference";
    phase = "ANALYZING_CONTEXT";
    await demo_wait(1000);
    busy = False;
    phase = "CONFIRMING_UNDERSTANDING";
}

impl TractionApp.capture_warm_leads_file(_e: ChangeEvent) -> None {
    warm_lead_input = "warm-leads.csv";
}

impl TractionApp.submit_warm_leads(e: FormEvent) -> None {
    e.preventDefault();
    if not warm_lead_input.strip() {
        return;
    }
    busy = True;
    warm_lead_input = warm_lead_input.strip();
    warm_leads_answered = True;
    source_step = "complete";
    next_workspace = await add_artifact("Warm contacts", warm_lead_input, "");
    apply_workspace(next_workspace);
    await demo_wait(650);
    next_workspace = await build_personas();
    apply_workspace(next_workspace);
    selected_personas = [persona.id for persona in next_workspace.personas];
    busy = False;
    phase = "REVIEWING_PERSONAS";
}

impl TractionApp.skip_warm_leads -> None {
    busy = True;
    warm_leads_answered = True;
    source_step = "complete";
    await demo_wait(650);
    next_workspace = await build_personas();
    apply_workspace(next_workspace);
    selected_personas = [persona.id for persona in next_workspace.personas];
    busy = False;
    phase = "REVIEWING_PERSONAS";
}

impl TractionApp.choose_artifact(mode: str) -> None {
    artifact_mode = mode;
    artifact_value = "";
}

impl TractionApp.capture_file(_e: ChangeEvent) -> None {
    artifact_value = "warm-leads.csv"
        if artifact_mode == "contacts"
        else "product-brief.pdf";
}

impl TractionApp.save_artifact -> None {
    if not artifact_value {
        return;
    }
    busy = True;
    artifact_type = "GitHub"
        if artifact_mode == "github"
        else ("Warm contacts" if artifact_mode == "contacts" else "Document");
    external_url = artifact_value if artifact_mode == "github" else "";
    next_workspace = await add_artifact(artifact_type, artifact_value, external_url);
    apply_workspace(next_workspace);
    artifact_saved = True;
    busy = False;
}

impl TractionApp.add_another_artifact(_e: MouseEvent) -> None {
    artifact_saved = False;
    artifact_mode = "";
    artifact_value = "";
}

impl TractionApp.continue_to_personas -> None {
    busy = True;
    next_workspace = await build_personas();
    apply_workspace(next_workspace);
    selected_personas = [persona.id for persona in next_workspace.personas];
    source_step = "complete";
    busy = False;
    phase = "REVIEWING_PERSONAS";
}

impl TractionApp.toggle_persona(persona_id: str) -> None {
    if persona_id in selected_personas {
        selected_personas = [
            item
            for item in selected_personas
            if item != persona_id
        ];
    } else {
        selected_personas = selected_personas + [persona_id];
    }
}

impl TractionApp.send_persona_correction(e: FormEvent) -> None {
    e.preventDefault();
    if not persona_input.strip() {
        return;
    }
    persona_note = persona_input.strip();
    persona_input = "";
}

impl TractionApp.confirm_personas -> None {
    if persona_input.strip() {
        persona_note = persona_input.strip();
        persona_input = "";
    }
    approved_ids = selected_personas;
    if not approved_ids and workspace is not None {
        approved_ids = [persona.id for persona in workspace.personas];
    }
    busy = True;
    next_workspace = await save_persona_feedback(persona_note, approved_ids);
    apply_workspace(next_workspace);
    busy = False;
    search_progress = 0;
    phase = "SEARCHING";
}

impl TractionApp.search_signals -> None {
    if busy {
        return;
    }
    busy = True;
    search_progress = 6;
    await demo_wait(500);
    search_progress = 15;
    await demo_wait(500);
    search_progress = 26;
    await demo_wait(500);
    search_progress = 38;
    await demo_wait(500);
    search_progress = 49;
    await demo_wait(500);
    search_progress = 61;
    await demo_wait(500);
    search_progress = 72;
    await demo_wait(500);
    search_progress = 83;
    await demo_wait(500);
    search_progress = 92;
    await demo_wait(500);
    search_progress = 97;
    await demo_wait(500);
    next_workspace = await run_signal_search();
    apply_workspace(next_workspace);
    search_progress = 100;
    busy = False;
    phase = "REVIEWING_PROSPECTS";
}

impl TractionApp.prepare_outreach -> None {
    busy = True;
    phase = "DRAFTING_OUTREACH";
    await demo_wait(1200);
    next_workspace = await draft_outreach();
    apply_workspace(next_workspace);
    if next_workspace.prospects {
        target_id = selected_prospect_id
            if selected_prospect_id
            else next_workspace.prospects[0].id;
        selected = find_prospect(next_workspace, target_id);
        if selected is not None {
            selected_prospect_id = selected.id;
            draft_text = selected.draft_body;
        }
    }
    busy = False;
    phase = "WAITING_FOR_APPROVAL";
}

impl TractionApp.select_prospect(prospect_id: str) -> None {
    selected_prospect_id = prospect_id;
    if workspace is not None {
        selected = find_prospect(workspace, prospect_id);
        if selected is not None {
            draft_text = selected.draft_body;
        }
    }
    notice = "";
}

impl TractionApp.approve_and_send -> None {
    if not selected_prospect_id or not draft_text.strip() {
        return;
    }
    busy = True;
    next_workspace = await send_outreach(selected_prospect_id, draft_text);
    apply_workspace(next_workspace);
    notice = "Sent as Becky Zhu through the Gmail demo adapter. The external event is now in the audit trail.";
    busy = False;
}

impl TractionApp.skip_draft(_e: MouseEvent) -> None {
    notice = "Skipped. No external action was taken.";
}

impl TractionApp.schedule_agent_call -> None {
    if workspace is None {
        return;
    }
    target_id = "";
    for prospect in workspace.prospects {
        if prospect.status == "Sent" and not target_id {
            target_id = prospect.id;
        }
    }
    if not target_id {
        return;
    }
    busy = True;
    notice = "";
    await demo_wait(650);
    next_workspace = await schedule_demo_call(target_id);
    apply_workspace(next_workspace);
    selected_prospect_id = target_id;
    live_call_prospect_id = target_id;
    busy = False;
}

impl TractionApp.open_live_call(prospect_id: str) -> None {
    if workspace is None or not prospect_id {
        return;
    }
    selected = find_prospect(workspace, prospect_id);
    if selected is None {
        return;
    }
    live_call_prospect_id = prospect_id;
    live_call_step = 0;
    live_call_active = True;
    notice = "";
    busy = True;
    phase = "LIVE_AGENT_CALL";
    if selected.status == "Sent" {
        next_workspace = await schedule_demo_call(prospect_id);
        apply_workspace(next_workspace);
    }
    await demo_wait(550);
    live_call_step = 1;
    await demo_wait(800);
    live_call_step = 2;
    await demo_wait(800);
    live_call_step = 3;
    await demo_wait(800);
    live_call_step = 4;
    await demo_wait(800);
    live_call_step = 5;
    await demo_wait(850);
    next_workspace = await schedule_demo_meeting(prospect_id);
    apply_workspace(next_workspace);
    selected_prospect_id = prospect_id;
    live_call_step = 6;
    live_call_active = False;
    busy = False;
}

impl TractionApp.close_live_call -> None {
    if live_call_active {
        return;
    }
    phase = "TRACKING_EXTERNAL_ACTIVITY";
}

impl TractionApp.book_demo_meeting -> None {
    if workspace is None {
        return;
    }
    target_id = "";
    for prospect in workspace.prospects {
        if prospect.status in ["Call scheduled", "Sent"] and not target_id {
            target_id = prospect.id;
        }
    }
    if not target_id and workspace.prospects {
        target_id = workspace.prospects[0].id;
    }
    if not target_id {
        return;
    }
    busy = True;
    next_workspace = await schedule_demo_meeting(target_id);
    apply_workspace(next_workspace);
    selected_prospect_id = target_id;
    busy = False;
}

impl TractionApp.learn_from_interview -> None {
    if workspace is None {
        return;
    }
    target_id = "";
    for prospect in workspace.prospects {
        if prospect.status == "Booked" {
            target_id = prospect.id;
        }
    }
    if not target_id {
        return;
    }
    busy = True;
    next_workspace = await synthesize_demo_interview(target_id);
    apply_workspace(next_workspace);
    busy = False;
}

impl TractionApp.jump_to_stage(stage: int) -> None {
    notice = "";
    if stage == 0 {
        if workspace is None or not product_description {
            phase = "EMPTY";
        } elif workspace.personas {
            source_step = "complete";
            phase = "REVIEWING_PERSONAS";
        } elif workspace.understanding_confirmed {
            source_step = "leads";
            phase = "WAITING_FOR_CHOICE";
        } else {
            source_step = "github";
            phase = "WAITING_FOR_CHOICE";
        }
        return;
    }
    if stage == 1 {
        if workspace is not None and workspace.prospects {
            phase = "REVIEWING_PROSPECTS";
        } elif workspace is not None and workspace.personas {
            search_progress = 0;
            phase = "SEARCHING";
        } else {
            phase = "FIND_EMPTY";
        }
        return;
    }
    if stage == 2 {
        if workspace is None or not workspace.prospects {
            phase = "REACH_EMPTY";
        } elif workspace.prospects[0].draft_body {
            select_prospect(
                selected_prospect_id
                    if selected_prospect_id
                    else workspace.prospects[0].id
            );
            phase = "WAITING_FOR_APPROVAL";
        } else {
            await prepare_outreach();
        }
        return;
    }
    if workspace is not None and workspace.prospects {
        phase = "LEARNING_FROM_MEETING";
    } else {
        phase = "LEARN_EMPTY";
    }
}

impl TractionApp.open_profile(prospect_id: str) -> None {
    select_prospect(prospect_id);
    profile_tab = "overview";
    phase = "LEAD_LIBRARY";
}

impl TractionApp.go_profiles -> None {
    if workspace is None or not workspace.prospects {
        return;
    }
    selected_prospect_id = "";
    profile_tab = "overview";
    phase = "LEAD_LIBRARY";
}

impl TractionApp.back_to_profiles -> None {
    selected_prospect_id = "";
    profile_tab = "overview";
}

impl TractionApp.set_profile_tab(tab: str) -> None {
    profile_tab = tab;
}

impl TractionApp.go_calendar -> None {
    calendar_notice = "";
    phase = "CALENDAR_WORKSPACE";
}

impl TractionApp.refresh_calendar -> None {
    calendar_notice = "Google Calendar is connected and up to date.";
}

impl TractionApp.go_home(_e: MouseEvent) -> None {
    phase = "EMPTY";
    search_progress = 0;
    notice = "";
    calendar_notice = "";
    live_call_prospect_id = "";
    live_call_step = 0;
    live_call_active = False;
}

impl TractionApp.rerun -> None {
    busy = True;
    next_workspace = await reset_workspace();
    workspace = next_workspace;
    product_description = "";
    job = "";
    audience = "";
    moment = "";
    alternative = "";
    difference = "";
    learning_goal = "";
    understanding_input = "";
    understanding_note = "";
    artifact_mode = "";
    artifact_value = "";
    artifact_saved = False;
    source_step = "github";
    github_input = "";
    document_value = "";
    warm_lead_input = "";
    github_answered = False;
    document_answered = False;
    warm_leads_answered = False;
    persona_note = "";
    persona_input = "";
    selected_personas = [];
    search_progress = 0;
    selected_prospect_id = "";
    profile_tab = "overview";
    draft_text = "";
    notice = "";
    live_call_prospect_id = "";
    live_call_step = 0;
    live_call_active = False;
    calendar_notice = "";
    busy = False;
    phase = "EMPTY";
}

"""Graph workflow acceptance tests for the deterministic demo path."""

test "product understanding persists on the founder graph" {
    reset_workspace();
    workspace = begin_product("A social app for travelers and locals.");
    assert workspace.product_description == "A social app for travelers and locals.";
    assert workspace.understanding is not None;
    assert "travelers" in workspace.understanding.concepts;

    confirmed = confirm_understanding(
        workspace.understanding.job,
        workspace.understanding.audience,
        workspace.understanding.moment,
        workspace.understanding.alternative,
        workspace.understanding.difference,
        workspace.understanding.learning_goal,
        "Prioritize mutual intent over recommendation volume."
    );
    assert confirmed.understanding_confirmed;
    assert confirmed.understanding_note == "Prioritize mutual intent over recommendation volume.";
}

test "evidence loop reaches an updated hypothesis" {
    reset_workspace();
    begin_product("A social app for travelers and locals.");
    prepared = build_personas();
    assert len(prepared.personas) == 4;

    corrected = save_persona_feedback(
        "Prioritize people who already host trusted gatherings.",
        [prepared.personas[3].id]
    );
    assert corrected.persona_note == "Prioritize people who already host trusted gatherings.";
    assert len(
        [
            persona
            for persona in corrected.personas
            if persona.approved
        ]
    ) == 1;

    restored = save_persona_feedback("", []);
    assert len(
        [
            persona
            for persona in restored.personas
            if persona.approved
        ]
    ) == 4;

    found = run_signal_search();
    assert len(found.prospects) == 4;
    assert found.prospects[0].source in ["LinkedIn", "GitHub"];
    assert found.prospects[0].evidence_url;

    drafted = draft_outreach();
    assert drafted.prospects[0].draft_body;
    target_id = drafted.prospects[0].id;

    sent = send_outreach(target_id, drafted.prospects[0].draft_body);
    assert len(sent.activities) == 1;
    assert sent.activities[0].identity == "Becky Zhu <becky@traction.ai>";
    assert sent.activities[0].is_demo;

    booked = schedule_demo_meeting(target_id);
    assert len(booked.activities) == 5;
    assert "Gmail" in [activity.channel for activity in booked.activities];
    assert "Phone" in [activity.channel for activity in booked.activities];
    assert "Google Calendar" in [activity.channel for activity in booked.activities];
    assert "Zoom" in [activity.channel for activity in booked.activities];

    learned = synthesize_demo_interview(target_id);
    assert len(learned.insights) == 3;
    assert learned.hypothesis_version == 2;
    call_transcripts = [
        activity
        for activity in learned.activities
        if activity.activity_type == "call" and activity.transcript
    ];
    meeting_transcripts = [
        activity
        for activity in learned.activities
        if activity.activity_type == "meeting" and activity.transcript
    ];
    assert len(call_transcripts) == 1;
    assert not call_transcripts[0].learnable;
    assert len(meeting_transcripts) == 1;
    assert meeting_transcripts[0].learnable;
}

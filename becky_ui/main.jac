"""Traction — graph-native founder research agent."""

import from traction.workflows {
    bootstrap_workspace,
    begin_product,
    confirm_understanding,
    add_artifact,
    build_personas,
    save_persona_feedback,
    run_signal_search,
    draft_outreach,
    send_outreach,
    schedule_demo_meeting,
    synthesize_demo_interview,
    reset_workspace,
    UnderstandProduct,
    IngestProductArtifact,
    ExtractProductAssumptions,
    ConfirmFounderUnderstanding,
    FindLinkedInPainSignals,
    FindGitHubPainSignals,
    RankResearchProspects,
    GenerateResearchQuestions,
    DraftFounderOutreach,
    ApproveAndSendOutreach,
    RecordExternalEvent,
    ScheduleFounderMeeting,
    SynthesizeInterview,
    UpdateProductHypothesis
}

cl {
    import "./styles.global.css";
    import from .frontend { TractionApp }

    def:pub app -> JsxElement {
        return <TractionApp/>;
    }
}

"""Typed AI contracts. Demo workflows use deterministic adapters by default."""

import from .domain {
    ProductUnderstanding,
    PainSignalAnalysis,
    OutreachDraft,
    InterviewSynthesis
}

def understand_product_ai(description: str) -> ProductUnderstanding by llm(
    temperature=0.2, max_tokens=900
);

sem understand_product_ai = "Turn a founder's product description into a specific, falsifiable product understanding.";
sem understand_product_ai.description = "The founder's own description of the product and the user problem.";

def analyze_pain_signal_ai(
    source: str, excerpt: str, hypothesis: str
) -> PainSignalAnalysis by llm(temperature=0.1, max_tokens=600);

sem analyze_pain_signal_ai = "Analyze public behavioral evidence without inventing facts.";
sem analyze_pain_signal_ai.source = "LinkedIn or GitHub.";
sem analyze_pain_signal_ai.excerpt = "The exact public excerpt to analyze.";
sem analyze_pain_signal_ai.hypothesis = "The assumption being tested.";

def draft_founder_outreach_ai(
    founder: str, prospect: str, evidence: str, question: str
) -> OutreachDraft by llm(temperature=0.3, max_tokens=500);

sem draft_founder_outreach_ai = "Write a short first-person research email from the actual founder. It must not sound like a sales pitch.";
sem draft_founder_outreach_ai.founder = "The founder's real name.";
sem draft_founder_outreach_ai.prospect = "The prospect's name.";
sem draft_founder_outreach_ai.evidence = "The exact public behavior that made the founder reach out.";
sem draft_founder_outreach_ai.question = "The one assumption the founder wants help testing.";

def synthesize_interview_ai(transcript: str, hypothesis: str) -> InterviewSynthesis by llm(
    temperature=0.2, max_tokens=800
);

sem synthesize_interview_ai = "Synthesize a founder research interview into evidence and a concrete hypothesis update.";
sem synthesize_interview_ai.transcript = "The meeting transcript.";
sem synthesize_interview_ai.hypothesis = "The product hypothesis before the interview.";

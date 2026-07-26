import from schema { Founder, ICP, Targets }
import from plan { PlanCampaign }
with entry {
    root ++> Founder(
        name="Ada Umana", email="ada@traction.dev",
        one_liner="Find the human, not the market.",
        product_summary="A prospect graph that finds beta testers for solo founders shipping retrieval augmented generation apps, by mining public comments and github issues.",
        github_repo="ElijahUmana/traction_v0.1"
    );
    r = root spawn PlanCampaign();
    rep = r.reports[0];
    print("SOURCE   :", rep["source"]);
    print("HYPOTH   :", rep["hypothesis"]);
    print("KEYWORDS :", rep["keywords"]);
    print("NEGATIVES:", rep["negative_keywords"]);
    print("PAINS    :", rep["pain_phrases"]);
}

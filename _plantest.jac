import from schema { Founder, ICP, Targets }
import from plan { PlanCampaign, fallback_draft, draft_is_usable, IcpDraft }
with entry {
    root ++> Founder(
        name="Ada Umana",
        email="ada@traction.dev",
        one_liner="Find the human, not the market.",
        product_summary="A prospect graph that finds beta testers for solo founders shipping retrieval augmented generation apps, by mining public comments and github issues.",
        github_repo="ElijahUmana/traction_v0.1"
    );
    r = root spawn PlanCampaign(offline=True);
    rep = r.reports[0];
    print("ok       :", rep["ok"]);
    print("source   :", rep["source"]);
    print("hypoth   :", rep["hypothesis"]);
    print("keywords :", rep["keywords"]);
    print("negatives:", len(rep["negative_keywords"]));
    print("pains    :", rep["pain_phrases"][:3]);

    f = [root --> [?:Founder]][0];
    icps = [f ->:Targets:->];
    print("ICP attached  :", len(icps));
    print("keywords live :", len(icps[0].keywords) > 0);
    print("pains live    :", len(icps[0].pain_phrases) > 0);

    r2 = root spawn PlanCampaign(offline=True);
    print("idempotent    :", r2.reports[0]["source"]);
    print("no duplicate  :", len([f ->:Targets:->]) == 1);

    r3 = root spawn PlanCampaign(offline=True, replace=True);
    print("replace works :", len([f ->:Targets:->]) == 1, r3.reports[0]["source"]);
}

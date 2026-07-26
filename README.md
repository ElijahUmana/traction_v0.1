# Traction

Traction is a graph-native founder research agent built primarily in Jac/Jaseci. It turns a product hypothesis into a traceable learning loop:

```text
hypothesis → signal → person → outreach → conversation → insight → updated hypothesis
```

The current build is an honest interactive demo. LinkedIn, GitHub, Gmail, Google Calendar, and Zoom use deterministic demo adapters; every simulated external event is labeled **Demo** in the UI. No internal inbox is fabricated, and no connector is presented as live.

## Architecture

- `main.jac` is the application entry point.
- `frontend.cl.jac` and `frontend.impl.jac` contain the stateful Jac client and event implementations.
- `traction/domain.jac` defines typed graph nodes, edges, workspace views, and AI output objects.
- `traction/workflows.jac` contains the server functions and walkers that mutate and traverse the research graph.
- `traction/intelligence.jac` declares typed `by llm` product-understanding, signal-analysis, outreach, and interview-synthesis contracts.
- `traction/workflows.test.jac` exercises the deterministic product-understanding and complete evidence-loop paths.

The browser is a projection of the graph. The canonical product, hypothesis, signal, prospect, outreach, meeting, interview, and insight state lives in Jac graph objects rather than a parallel JavaScript state machine.

## Run locally

Install Jac and project dependencies, then start the full-stack app:

```bash
python -m pip install "jaclang==0.34.7"
jac install
jac start main.jac
```

Open [http://127.0.0.1:4173](http://127.0.0.1:4173). The API runs on port `4174`.

## Verify

```bash
jac fmt .
jac check .
jac test traction/workflows.jac -v
```

## Demo controls

- **Home** returns to the opening prompt without erasing the current graph.
- **Re-run** clears the demo graph and returns to a blank opening prompt.
- The founder must approve outreach before a demo external event is recorded.

## Live adapter seam

The deterministic adapter functions intentionally share the typed contracts used by the declared `by llm` functions and graph walkers. Replacing demo data with live APIs should happen at that boundary; the graph model and founder-approval flow should remain unchanged.

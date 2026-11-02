// Troupe playground: every action below is a call into Elixir running in the
// browser (Popcorn), handled by Troupe.Playground with the same library code
// that runs on a server.
import { Popcorn } from "./out/index.mjs";

const $ = (id) => document.getElementById(id);
const state = { examples: [], validated: null, lastRunId: null };
let popcorn;

async function call(request) {
  const reply = await popcorn.call("troupe_playground", request, { timeoutMs: 120000 });
  return JSON.parse(reply);
}

function pretty(value) {
  return JSON.stringify(value, null, 2);
}

function errorList(errors) {
  const list = document.createElement("ul");
  list.className = "errors";
  for (const error of errors) {
    const item = document.createElement("li");
    item.textContent = `${error.kind}${error.path ? ` at ${error.path}` : ""}: ${error.message}`;
    list.append(item);
  }
  return list;
}

function loadExample(id) {
  const example = state.examples.find((e) => e.id === id);
  $("definition").value = example.json;
  $("inputs").value = pretty(example.inputs);
  $("example-source").textContent =
    example.source === "spark"
      ? "Authored with the Spark DSL; shown as its canonical JSON export (the same definition)."
      : "Authored as JSON (examples/" + example.id + ".json).";
  state.validated = null;
  $("validation").replaceChildren();
  renderGrants([], example.grant);
}

function renderGrants(capabilities, suggested = []) {
  const fieldset = $("grants");
  fieldset.querySelectorAll("label, p").forEach((node) => node.remove());
  if (capabilities.length === 0) {
    const hint = document.createElement("p");
    hint.className = "hint";
    hint.textContent = "Validate to list the capabilities this definition uses.";
    fieldset.append(hint);
    return;
  }
  for (const capability of capabilities) {
    const label = document.createElement("label");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.value = capability.name;
    box.dataset.capability = capability.name;
    label.append(box, ` ${capability.name} ${capability.version}`);
    fieldset.append(label);
  }
  fieldset.dataset.suggested = suggested.join(",");
}

function granted() {
  return [...$("grants").querySelectorAll("input:checked")].map((box) => box.value);
}

async function validate() {
  const reply = await call(["validate", $("definition").value]);
  const panel = $("validation");
  panel.replaceChildren();
  if (!reply.ok) {
    state.validated = null;
    const heading = document.createElement("p");
    heading.className = "bad";
    heading.textContent = `Invalid definition (${reply.errors.length} problem(s)):`;
    panel.append(heading, errorList(reply.errors));
    renderGrants([]);
    return reply;
  }
  state.validated = reply;
  const heading = document.createElement("p");
  heading.className = reply.check.length ? "bad" : "good";
  heading.textContent = `Valid: ${reply.id}@${reply.version}` + (reply.check.length ? " — but not runnable here:" : "");
  panel.append(heading);
  if (reply.check.length) panel.append(errorList(reply.check));
  const outline = document.createElement("ul");
  outline.className = "outline";
  for (const row of reply.outline) {
    const item = document.createElement("li");
    item.style.paddingLeft = `${row.depth * 1.5}em`;
    item.textContent = `${row.kind} ${row.id} — ${row.detail}`;
    outline.append(item);
  }
  panel.append(outline);
  const previous = new Set(granted());
  renderGrants(reply.capabilities);
  $("grants").querySelectorAll("input").forEach((box) => (box.checked = previous.has(box.value)));
  return reply;
}

function renderRun(reply) {
  state.lastRunId = reply.run_id;
  $("resume").disabled = !(reply.status === "interrupted" || reply.status === "failed");
  $("run-status").textContent = `Run ${reply.run_id}: ${reply.status}`;
  $("run-status").className = reply.status === "completed" ? "good" : "bad";
  const output = $("output");
  output.replaceChildren();
  if (reply.status === "completed") output.textContent = pretty(reply.output);
  else if (reply.errors && reply.errors.length) output.append(errorList(reply.errors));
  else output.textContent = "(interrupted — resume to continue from the last checkpoint)";

  const steps = $("steps").querySelector("tbody");
  steps.replaceChildren();
  for (const step of reply.steps) {
    const row = document.createElement("tr");
    row.dataset.node = step.node;
    for (const value of [step.activation, step.node, step.attempts, step.status ?? "", step.error ?? (step.result === undefined ? "" : JSON.stringify(step.result))]) {
      const cell = document.createElement("td");
      cell.textContent = String(value);
      row.append(cell);
    }
    steps.append(row);
  }

  const loops = $("loops").querySelector("tbody");
  loops.replaceChildren();
  for (const loop of reply.loops) {
    const row = document.createElement("tr");
    for (const value of [loop.loop, loop.iteration, JSON.stringify(loop.next_state)]) {
      const cell = document.createElement("td");
      cell.textContent = String(value);
      row.append(cell);
    }
    loops.append(row);
  }

  $("stats").textContent = pretty(reply.stats);
  $("events").textContent = reply.events.map((e) => `${e.seq} ${e.type} ${e.activation ?? ""}${e.attempt ? "@" + e.attempt : ""}`).join("\n");
}

async function run() {
  $("run-status").textContent = "Running…";
  const reply = await call(["run", $("definition").value, $("inputs").value, granted(), Number($("interrupt").value) || 0]);
  renderRun(reply);
  return reply;
}

async function resume() {
  $("run-status").textContent = "Resuming…";
  const reply = await call(["resume", state.lastRunId, granted()]);
  renderRun(reply);
  return reply;
}

async function exportAs(format) {
  const reply = await call(["export", $("definition").value, format]);
  const panel = $("export-output");
  panel.replaceChildren();
  if (!reply.ok) {
    panel.append(errorList(reply.errors));
    return reply;
  }
  panel.textContent = reply.content;
  if (format === "json") {
    const id = state.validated?.id ?? "workflow";
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([reply.content], { type: "application/json" }));
    link.download = `${id}.json`;
    link.id = "download-link";
    link.textContent = `Download ${id}.json`;
    panel.prepend(link, document.createElement("br"));
    link.click();
  }
  return reply;
}

function guard(fn) {
  return async () => {
    try {
      await fn();
    } catch (error) {
      $("run-status").textContent = `Bridge error: ${error}`;
      $("run-status").className = "bad";
    }
  };
}

// Scripted end-to-end check through the real UI controls: load, edit,
// validate, permission denial, run, interrupt + resume, export.
async function selftest() {
  const log = [];
  const check = (name, ok, detail = "") => log.push(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " — " + detail : ""}`);
  const tick = (names) => $("grants").querySelectorAll("input").forEach((box) => (box.checked = names.includes(box.value)));

  $("example").value = "calculator_agent";
  loadExample("calculator_agent");
  let v = await validate();
  check("validate example", v.ok && v.outline.length === 6);

  const reply0 = await run();
  check("run without grant is refused", reply0.status === "failed" && reply0.errors.some((e) => e.kind === "not_granted"));

  tick(v.capabilities.map((c) => c.name));
  const reply1 = await run();
  check("run agent loop", reply1.status === "completed" && reply1.output.value === 35, JSON.stringify(reply1.output?.value));

  const edited = JSON.parse($("definition").value);
  edited.nodes[0].max_iterations = 2;
  $("definition").value = JSON.stringify(edited, null, 2);
  $("inputs").value = JSON.stringify({ start: 1, plan: [{ tool: "add", operand: 1 }, { tool: "add", operand: 1 }, { tool: "add", operand: 1 }] });
  v = await validate();
  tick(v.capabilities.map((c) => c.name));
  const reply2 = await run();
  check("edited definition runs with new limit", reply2.status === "completed" && reply2.loops.length === 2 && reply2.output.value === 3);

  const broken = JSON.parse($("definition").value);
  broken.output = { result: "nowhere" };
  $("definition").value = JSON.stringify(broken);
  v = await validate();
  check("invalid edit reports located error", !v.ok && v.errors[0].path === "/output");

  $("example").value = "ticket_triage";
  loadExample("ticket_triage");
  v = await validate();
  tick(v.capabilities.map((c) => c.name));
  $("interrupt").value = "2";
  const reply3 = await run();
  check("interrupt after 2 completions", reply3.status === "interrupted");
  $("interrupt").value = "0";
  const reply4 = await resume();
  const statuses = Object.fromEntries(reply4.steps.map((s) => [s.node, s.status]));
  check("resume replays checkpoints", reply4.status === "completed" && statuses.urgent === "replayed" && statuses.escalate === "completed", JSON.stringify(statuses));

  const exported = await exportAs("json");
  const reimported = await call(["validate", exported.content]);
  check("export json round-trips", exported.ok && reimported.ok && reimported.json === exported.content);
  const etf = await exportAs("etf");
  check("export term binary", etf.ok && etf.content.length > 0);

  const passed = log.every((line) => line.startsWith("PASS"));
  $("selftest").hidden = false;
  $("selftest").textContent = log.join("\n");
  document.body.dataset.selftest = passed ? "pass" : "fail";
}

async function main() {
  if (!self.crossOriginIsolated) {
    // coi-serviceworker.js is installing and will reload the page.
    if (window.__troupeIsolating) {
      $("vm-status").textContent = "Enabling cross-origin isolation (one-time reload)…";
      return;
    }
    throw new Error("this page is not cross-origin isolated; serve it with COOP/COEP headers or allow service workers");
  }

  popcorn = await Popcorn.init({
    // Remote hosts (GitHub Pages) can take well over the 10 s default to
    // deliver the VM and OTP archives on a first, uncached visit.
    timeoutsMs: { boot: 180000, appStartup: 180000 },
    onStdout: (text) => console.log(text),
    onStderr: (text) => console.warn(text),
  });
  const init = await call(["init"]);
  state.examples = init.examples;
  const select = $("example");
  for (const example of init.examples) {
    const option = document.createElement("option");
    option.value = example.id;
    option.textContent = example.title;
    select.append(option);
  }
  select.addEventListener("change", () => loadExample(select.value));
  loadExample(init.examples[0].id);

  $("validate").addEventListener("click", guard(validate));
  $("canonical").addEventListener("click", guard(async () => {
    const reply = await validate();
    if (reply.ok) $("definition").value = reply.json;
  }));
  $("run").addEventListener("click", guard(run));
  $("resume").addEventListener("click", guard(resume));
  $("export-json").addEventListener("click", guard(() => exportAs("json")));
  $("export-etf").addEventListener("click", guard(() => exportAs("etf")));
  $("export-elixir").addEventListener("click", guard(() => exportAs("elixir")));

  for (const id of ["example", "validate", "canonical", "run", "export-json", "export-etf", "export-elixir"]) $(id).disabled = false;
  $("vm-status").textContent = `Elixir VM ready — Troupe schema v${init.schema_version}, ${init.capabilities.length} installed capabilities.`;
  document.body.dataset.ready = "true";

  if (new URLSearchParams(location.search).has("selftest")) await selftest();
}

main().catch((error) => {
  $("vm-status").textContent = `Failed to start: ${error}`;
  document.body.dataset.ready = "error";
});

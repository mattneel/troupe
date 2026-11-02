// Troupe playground: every action below is a call into Elixir running in the
// browser (Popcorn), handled by Troupe.Playground with the same library code
// that runs on a server. The editor is Monaco; Elixir DSL source is parsed by
// Troupe.Workflow.Source (Code.string_to_quoted + Macro), never evaluated.
import { Popcorn } from "./out/index.mjs";

const $ = (id) => document.getElementById(id);
const state = { examples: [], validated: null, lastRunId: null, format: "elixir", validateTimer: null, validateSeq: 0 };
let popcorn;
let editor;

async function call(request) {
  const reply = await popcorn.call("troupe_playground", request, { timeoutMs: 120000 });
  return JSON.parse(reply);
}

const pretty = (value) => JSON.stringify(value, null, 2);
const source = () => editor.getValue();
const definitionRequest = () => [state.format, source()];

function errorList(errors) {
  const list = document.createElement("ul");
  list.className = "errors";
  for (const error of errors) {
    const item = document.createElement("li");
    const line = errorLine(error);
    item.textContent = `${error.kind}${error.path ? ` at ${error.path}` : ""}${line ? ` (line ${line})` : ""}: ${error.message}`;
    if (line) {
      item.className = "jump";
      item.addEventListener("click", () => {
        editor.revealLineInCenter(line);
        editor.setPosition({ lineNumber: line, column: 1 });
        editor.focus();
      });
    }
    list.append(item);
  }
  return list;
}

// ---- error locations -----------------------------------------------------

// Line of an error: given by the server for Elixir source; for JSON, derived
// from the JSON pointer (or the parser position) against the editor text.
function errorLine(error) {
  if (error.details && Number.isInteger(error.details.line)) return error.details.line;
  if (state.format !== "json") return null;
  const text = source();
  if (error.details && Number.isInteger(error.details.position)) return offsetLine(text, error.details.position);
  if (error.path != null) {
    const offset = jsonPointerOffset(text, error.path);
    if (offset != null) return offsetLine(text, offset);
  }
  return null;
}

function offsetLine(text, offset) {
  let line = 1;
  for (let i = 0; i < Math.min(offset, text.length); i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

// Offset of the deepest existing value along a JSON pointer, via a small
// tolerant recursive-descent scan (no full parse needed).
function jsonPointerOffset(text, pointer) {
  const segments = pointer.split("/").slice(1).map((s) => s.replace(/~1/g, "/").replace(/~0/g, "~"));
  let i = 0;
  const ws = () => {
    while (i < text.length && /\s/.test(text[i])) i++;
  };
  const string = () => {
    const start = ++i;
    while (i < text.length && text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
    return text.slice(start, i++);
  };
  const skip = () => {
    ws();
    const c = text[i];
    if (c === '"') return string();
    if (c === "{" || c === "[") {
      const close = c === "{" ? "}" : "]";
      i++;
      ws();
      while (i < text.length && text[i] !== close) {
        if (c === "{") {
          ws();
          string();
          ws();
          i++;
        }
        skip();
        ws();
        if (text[i] === ",") i++;
        ws();
      }
      i++;
      return;
    }
    while (i < text.length && !/[,\]}\s]/.test(text[i])) i++;
  };
  const descend = (depth, found) => {
    ws();
    if (depth === segments.length) return i;
    const target = segments[depth];
    const c = text[i];
    if (c !== "{" && c !== "[") return found;
    const at = i;
    i++;
    let index = 0;
    ws();
    while (i < text.length && text[i] !== (c === "{" ? "}" : "]")) {
      let key = String(index++);
      if (c === "{") {
        ws();
        key = string();
        ws();
        i++;
      }
      ws();
      if (key === target) return descend(depth + 1, i);
      skip();
      ws();
      if (text[i] === ",") i++;
      ws();
    }
    return found ?? at;
  };
  try {
    return descend(0, 0);
  } catch {
    return null;
  }
}

function setMarkers(errors) {
  const model = editor.getModel();
  const markers = errors
    .map((error) => ({ error, line: errorLine(error) }))
    .filter(({ line }) => line)
    .map(({ error, line }) => ({
      severity: monaco.MarkerSeverity.Error,
      message: `${error.kind}: ${error.message}`,
      startLineNumber: line,
      startColumn: 1,
      endLineNumber: line,
      endColumn: model.getLineMaxColumn(line),
    }));
  monaco.editor.setModelMarkers(model, "troupe", markers);
}

// ---- examples, grants, validation ------------------------------------------

function loadExample(id) {
  const example = state.examples.find((e) => e.id === id);
  setSource(state.format === "elixir" ? example.elixir : example.json);
  $("inputs").value = pretty(example.inputs);
  $("example-source").textContent =
    example.source === "spark"
      ? `The real Spark DSL module (lib/troupe/examples/${example.id}.ex); its JSON twin is examples/${example.id}.json.`
      : `Authored as JSON (examples/${example.id}.json); the Elixir view is rendered from it.`;
  state.validated = null;
  $("validation").replaceChildren();
  renderGrants([]);
}

function setSource(text) {
  editor.setValue(text);
  monaco.editor.setModelLanguage(editor.getModel(), state.format === "elixir" ? "elixir" : "json");
}

function renderGrants(capabilities) {
  const fieldset = $("grants");
  const previous = new Set(granted());
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
    box.checked = previous.has(capability.name);
    label.append(box, ` ${capability.name} ${capability.version}`);
    fieldset.append(label);
  }
}

function granted() {
  return [...$("grants").querySelectorAll("input:checked")].map((box) => box.value);
}

async function validate() {
  const seq = ++state.validateSeq;
  const reply = await call(["validate", ...definitionRequest()]);
  if (seq !== state.validateSeq) return reply; // a newer edit superseded this one
  const panel = $("validation");
  panel.replaceChildren();
  if (!reply.ok) {
    state.validated = null;
    setMarkers(reply.errors);
    const heading = document.createElement("p");
    heading.className = "bad";
    heading.textContent = `Invalid definition (${reply.errors.length} problem(s)):`;
    panel.append(heading, errorList(reply.errors));
    renderGrants([]);
    return reply;
  }
  state.validated = reply;
  setMarkers(reply.check);
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
  renderGrants(reply.capabilities);
  return reply;
}

function scheduleValidate() {
  clearTimeout(state.validateTimer);
  state.validateTimer = setTimeout(() => validate().catch(reportBridgeError), 400);
}

// Switching format converts the current definition through the VM, so the
// other view is always the same definition. Invalid source blocks the switch.
async function switchFormat(format) {
  if (format === state.format) return;
  const reply = await call(["export", ...definitionRequest(), format === "elixir" ? "source" : "json"]);
  if (!reply.ok) {
    $(`fmt-${state.format}`).checked = true;
    setMarkers(reply.errors);
    $("validation").replaceChildren(Object.assign(document.createElement("p"), { className: "bad", textContent: "Fix these problems before switching format:" }), errorList(reply.errors));
    return reply;
  }
  state.format = format;
  setSource(reply.content);
  await validate();
  return reply;
}

// ---- run -------------------------------------------------------------------

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
  const reply = await call(["run", ...definitionRequest(), $("inputs").value, granted(), Number($("interrupt").value) || 0]);
  renderRun(reply);
  return reply;
}

async function resume() {
  $("run-status").textContent = "Resuming…";
  const reply = await call(["resume", state.lastRunId, granted()]);
  renderRun(reply);
  return reply;
}

const downloads = { json: ["application/json", "json"], elixir: ["text/x-elixir", "ex"] };

async function exportAs(as) {
  const reply = await call(["export", ...definitionRequest(), as]);
  const panel = $("export-output");
  panel.replaceChildren();
  if (!reply.ok) {
    panel.append(errorList(reply.errors));
    return reply;
  }
  panel.textContent = reply.content;
  if (downloads[as]) {
    const [type, extension] = downloads[as];
    const id = state.validated?.id ?? "workflow";
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([reply.content], { type }));
    link.download = `${id}.${extension}`;
    link.id = "download-link";
    link.textContent = `Download ${id}.${extension}`;
    panel.prepend(link, document.createElement("br"));
  }
  return reply;
}

function reportBridgeError(error) {
  $("run-status").textContent = `Bridge error: ${error}`;
  $("run-status").className = "bad";
}

const guard = (fn) => () => fn().catch(reportBridgeError);

// ---- self-test ---------------------------------------------------------------

// Scripted end-to-end check through the real editor and controls: Elixir DSL
// and JSON authoring, editor markers, permission denial, runs, format
// switching, interrupt + resume, and every export.
async function selftest() {
  const log = [];
  const check = (name, ok, detail = "") => log.push(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " — " + detail : ""}`);
  const tick = (names) => $("grants").querySelectorAll("input").forEach((box) => (box.checked = names.includes(box.value)));
  const markers = () => monaco.editor.getModelMarkers({ owner: "troupe" });
  const choose = async (format) => {
    $(`fmt-${format}`).checked = true;
    return switchFormat(format);
  };

  check("Monaco editor with Elixir highlighting", typeof monaco !== "undefined" && editor.getModel().getLanguageId() === "elixir");

  $("example").value = "calculator_agent";
  loadExample("calculator_agent");
  check("Spark example shown as real DSL source", source().includes("use Troupe.Workflow") && source().includes("loop :agent do"));
  let v = await validate();
  check("validate Elixir DSL source", v.ok && v.outline.length === 6);

  const reply0 = await run();
  check("run without grant is refused", reply0.status === "failed" && reply0.errors.some((e) => e.kind === "not_granted"));

  tick(v.capabilities.map((c) => c.name));
  const reply1 = await run();
  check("run agent loop from Elixir source", reply1.status === "completed" && reply1.output.value === 35, JSON.stringify(reply1.output?.value));

  editor.setValue(source().replace("max_iterations 20", "max_iterations 2"));
  $("inputs").value = JSON.stringify({ start: 1, plan: [{ tool: "add", operand: 1 }, { tool: "add", operand: 1 }, { tool: "add", operand: 1 }] });
  v = await validate();
  const reply2 = await run();
  check("edited DSL runs with new limit", reply2.status === "completed" && reply2.loops.length === 2 && reply2.output.value === 3);

  const lines = source().split("\n");
  const target = lines.findIndex((line) => line.includes("arg :plan, input(:plan)"));
  editor.setValue(source().replace("arg :plan, input(:plan)", "arg :plan, input(:planz)"));
  v = await validate();
  check("DSL error marked on its line", !v.ok && markers().some((m) => m.startLineNumber === target + 1), JSON.stringify(markers().map((m) => m.startLineNumber)));

  editor.setValue(source().replace("input(:planz)", "System.cmd(\"rm\", [\"-rf\", \"/\"])"));
  v = await validate();
  check("code in DSL is rejected, not evaluated", !v.ok && v.errors[0].message.includes("never evaluated"));

  $("example").value = "greeting";
  loadExample("greeting");
  await validate();
  const toJson = await choose("json");
  check("switch Elixir -> JSON", toJson.ok && state.format === "json" && JSON.parse(source()).id === "greeting");
  const parsed = JSON.parse(source());
  parsed.nodes[1].args.vars.object.name = { result: "shot" };
  editor.setValue(JSON.stringify(parsed, null, 2));
  v = await validate();
  // The error's pointer is the whole argument (/nodes/1/args/vars).
  const jsonLine = source().split("\n").findIndex((line) => line.includes('"vars"')) + 1;
  check("JSON error marked on its line", !v.ok && markers().some((m) => m.startLineNumber === jsonLine), `want ${jsonLine}, got ${JSON.stringify(markers().map((m) => m.startLineNumber))}`);
  const blocked = await choose("elixir");
  check("invalid source blocks format switch", !blocked.ok && state.format === "json");
  parsed.nodes[1].args.vars.object.name = { result: "shout" };
  editor.setValue(JSON.stringify(parsed));
  const toElixir = await choose("elixir");
  check("switch JSON -> Elixir", toElixir.ok && state.format === "elixir" && source().includes('action :shout, "text.upcase"'));

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

  const asJson = await exportAs("json");
  const asElixir = await exportAs("elixir");
  const fromJson = await call(["validate", "json", asJson.content]);
  const fromElixir = await call(["validate", "elixir", asElixir.content]);
  check("JSON and Elixir module exports are the same definition", fromJson.ok && fromElixir.ok && fromJson.json === fromElixir.json && asElixir.content.startsWith("defmodule MyApp.Workflows.TicketTriage do"));
  const etf = await exportAs("etf");
  check("export term binary", etf.ok && etf.content.length > 0);

  const passed = log.every((line) => line.startsWith("PASS"));
  $("selftest").hidden = false;
  $("selftest").textContent = log.join("\n");
  document.body.dataset.selftest = passed ? "pass" : "fail";
}

// ---- boot --------------------------------------------------------------------

function loadMonaco() {
  return new Promise((resolve, reject) => {
    require.config({ paths: { vs: "./vendor/monaco/vs" } });
    require(["vs/editor/editor.main"], () => resolve(), reject);
  });
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

  const [, vm] = await Promise.all([
    loadMonaco(),
    Popcorn.init({
      // Remote hosts (GitHub Pages) can take well over the 10 s default to
      // deliver the VM and OTP archives on a first, uncached visit.
      timeoutsMs: { boot: 180000, appStartup: 180000 },
      onStdout: (text) => console.log(text),
      onStderr: (text) => console.warn(text),
    }),
  ]);
  popcorn = vm;

  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  editor = monaco.editor.create($("editor"), {
    value: "",
    language: "elixir",
    theme: dark ? "vs-dark" : "vs",
    automaticLayout: true,
    minimap: { enabled: false },
    fontSize: 13,
    tabSize: 2,
    scrollBeyondLastLine: false,
  });
  window.troupeEditor = editor;

  const init = await call(["init"]);
  state.examples = init.examples;
  const select = $("example");
  for (const example of init.examples) {
    const option = document.createElement("option");
    option.value = example.id;
    option.textContent = example.title;
    select.append(option);
  }
  select.addEventListener("change", () => {
    loadExample(select.value);
    scheduleValidate();
  });
  loadExample(init.examples[0].id);
  editor.onDidChangeModelContent(scheduleValidate);

  for (const format of ["elixir", "json"]) $(`fmt-${format}`).addEventListener("change", guard(() => switchFormat(format)));
  $("validate").addEventListener("click", guard(validate));
  $("canonical").addEventListener("click", guard(async () => {
    const reply = await validate();
    if (reply.ok) editor.setValue(state.format === "elixir" ? reply.elixir : reply.json);
  }));
  $("run").addEventListener("click", guard(run));
  $("resume").addEventListener("click", guard(resume));
  for (const as of ["elixir", "json", "etf", "app"]) $(`export-${as}`).addEventListener("click", guard(() => exportAs(as)));

  for (const id of ["example", "fmt-elixir", "fmt-json", "validate", "canonical", "run", "export-elixir", "export-json", "export-etf", "export-app"]) $(id).disabled = false;
  $("vm-status").textContent = `Elixir VM ready — Troupe schema v${init.schema_version}, ${init.capabilities.length} installed capabilities.`;
  document.body.dataset.ready = "true";

  if (new URLSearchParams(location.search).has("selftest")) await selftest();
}

main().catch((error) => {
  $("vm-status").textContent = `Failed to start: ${error}`;
  document.body.dataset.ready = "error";
});

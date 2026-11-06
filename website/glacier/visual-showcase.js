(() => {
  "use strict";

  const root = document.querySelector(".vs-showcase");
  if (!root || root.dataset.vsReady === "true") return;
  root.dataset.vsReady = "true";

  const tabs = Array.from(root.querySelectorAll("[data-vs-tab]"));
  const panels = Array.from(root.querySelectorAll("[data-vs-panel]"));
  const formButtons = Array.from(root.querySelectorAll("[data-vs-form]"));
  const formInput = root.querySelector("#vs-map-input");
  const graph = root.querySelector("#vs-map-graph");
  const route = root.querySelector("#vs-map-route");
  const meaning = root.querySelector("#vs-map-meaning");
  const limit = root.querySelector("#vs-map-limit");
  const summary = root.querySelector("#vs-map-summary");

  const centerDiagram = (viewport) => {
    requestAnimationFrame(() => { viewport.scrollLeft = Math.max(0, (viewport.scrollWidth - viewport.clientWidth) / 2); });
  };

  function showTab(name, focus = false) {
    for (const tab of tabs) {
      const selected = tab.dataset.vsTab === name;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focus) tab.focus();
    }
    for (const panel of panels) {
      panel.hidden = panel.dataset.vsPanel !== name;
      if (!panel.hidden) panel.querySelectorAll('.vs-graph-viewport').forEach(centerDiagram);
    }
  }

  for (const tab of tabs) {
    tab.addEventListener("click", () => showTab(tab.dataset.vsTab));
    tab.addEventListener("keydown", (event) => {
      const index = tabs.indexOf(tab);
      let next = index;
      if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
      else if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = tabs.length - 1;
      else return;
      event.preventDefault();
      showTab(tabs[next].dataset.vsTab, true);
    });
  }

  document.querySelectorAll('[data-open-visual]').forEach(link => {
    link.addEventListener('click', () => showTab(link.dataset.openVisual));
  });

  const box = (x, y, w, h, label, core = false) =>
    `<rect class="${core ? "vs-gfx-core" : "vs-gfx-node"}" x="${x}" y="${y}" width="${w}" height="${h}" rx="9"/><text class="${core ? "vs-gfx-core-text" : "vs-gfx-text"}" x="${x + w / 2}" y="${y + h / 2 + 5}" text-anchor="middle">${label}</text>`;
  const line = (d, dashed = false) => `<path class="${dashed ? "vs-gfx-dash" : "vs-gfx-line"}" d="${d}"/>`;
  const label = (x, y, value, className = "vs-gfx-cap", anchor = "middle") =>
    `<text class="${className}" x="${x}" y="${y}" text-anchor="${anchor}">${value}</text>`;

  // All diagrams are fixed editorial examples. No user input enters this markup.
  const forms = {
    tree: {
      input: "What makes a useful library?", meaning: "solid lines: kinds of contribution",
      limit: "Funding, staffing, and how different readers use the space.",
      summary: "Illustrated example: a library connects access, discovery, and care for its collection.",
      description: "A useful library branches into access, discovery and care, with examples beneath each.",
      drawing: [
        line("M310 64V90M105 90H515M105 90V119M310 90V119M515 90V119"),
        line("M105 154V183M310 154V183M515 154V183"),
        box(218, 25, 184, 39, "Useful library", true),
        box(35, 119, 140, 35, "Access"), box(240, 119, 140, 35, "Discovery"), box(445, 119, 140, 35, "Care"),
        box(35, 183, 140, 34, "Open hours"), box(240, 183, 140, 34, "Catalog"), box(445, 183, 140, 34, "Preservation"),
        label(310, 259, "WHAT PARTS MAKE THE WHOLE?"),
      ].join(""),
    },
    radial: {
      input: "What does a community garden support?", meaning: "spokes: related contributions",
      limit: "Seasonal work, land access, and who maintains the garden.",
      summary: "Illustrated example: a community garden can connect food, habitat, learning and neighbors.",
      description: "Community garden at the center, with spokes to food, habitat, learning and neighbors.",
      drawing: [
        line("M310 125V78M380 143L458 92M380 171L458 218M240 171L162 218M240 143L162 92"),
        box(210, 125, 200, 55, "Community garden", true),
        box(240, 35, 140, 38, "Food"), box(458, 67, 136, 38, "Habitat"),
        box(458, 210, 136, 38, "Learning"), box(26, 210, 136, 38, "Neighbors"), box(26, 67, 136, 38, "Shared space"),
      ].join(""),
    },
    bridge: {
      input: "Explain a search index as a library catalog", meaning: "rungs: points of comparison",
      limit: "Search ranking, live updates, and the physical work of shelving.",
      summary: "Illustrated analogy: catalog entries correspond to indexed records; subject headings to searchable terms.",
      description: "A bridge compares a library catalog with a search index: entries with records and subject headings with searchable terms.",
      drawing: [
        label(150, 42, "FAMILIAR: CATALOG"), label(470, 42, "NEW: SEARCH INDEX"),
        line("M229 104H391M229 184H391"),
        box(20, 82, 209, 43, "Catalog entry"), box(391, 82, 209, 43, "Indexed record"),
        box(20, 162, 209, 43, "Subject heading"), box(391, 162, 209, 43, "Searchable term"),
        label(310, 94, "describes", "vs-gfx-small"), label(310, 174, "helps find", "vs-gfx-small"),
      ].join(""),
    },
    matrix: {
      input: "Walk vs bike vs train for a city trip", meaning: "columns: shared criteria",
      limit: "Local prices, routes, accessibility needs, and weather on the day.",
      summary: "Illustrated matrix: walking, cycling and rail compared on range, capacity and schedule.",
      description: "A matrix compares walking, cycling and rail on range, capacity and schedule.",
      drawing: [
        label(310, 35, "SAME QUESTIONS, THREE OPTIONS"),
        line("M120 77H594M120 126H594M120 175H594M120 224H594M120 77V224M278 77V224M436 77V224M594 77V224"),
        label(199, 65, "RANGE"), label(357, 65, "CAPACITY"), label(515, 65, "SCHEDULE"),
        label(102, 106, "Walk", "vs-gfx-text", "end"), label(199, 106, "short", "vs-gfx-text"), label(357, 106, "one", "vs-gfx-text"), label(515, 106, "anytime", "vs-gfx-text"),
        label(102, 155, "Bike", "vs-gfx-text", "end"), label(199, 155, "medium", "vs-gfx-text"), label(357, 155, "one or two", "vs-gfx-text"), label(515, 155, "anytime", "vs-gfx-text"),
        label(102, 204, "Train", "vs-gfx-text", "end"), label(199, 204, "long", "vs-gfx-text"), label(357, 204, "many", "vs-gfx-text"), label(515, 204, "timetable", "vs-gfx-text"),
      ].join(""),
    },
    spectrum: {
      input: "Place communication channels by audience size", meaning: "axis: narrower to wider audience",
      limit: "Privacy settings, who forwards a message, and actual readership.",
      summary: "Illustrated spectrum: a direct message, team chat and public post along a narrower-to-wider audience axis.",
      description: "A spectrum places direct message, team chat and public post between narrower and wider audiences.",
      drawing: [
        label(310, 48, "POTENTIAL AUDIENCE"), line("M67 152H553M67 141V163M553 141V163"),
        `<circle class="vs-gfx-end" cx="112" cy="152" r="7"/><circle class="vs-gfx-end" cx="310" cy="152" r="7"/><circle class="vs-gfx-end" cx="508" cy="152" r="7"/>`,
        label(112, 119, "Direct message", "vs-gfx-text"), label(310, 119, "Team chat", "vs-gfx-text"), label(508, 119, "Public post", "vs-gfx-text"),
        label(67, 190, "NARROWER", "vs-gfx-cap", "start"), label(553, 190, "WIDER", "vs-gfx-cap", "end"),
      ].join(""),
    },
    loop: {
      input: "How does practice improve a skill?", meaning: "arrows: one step informs the next",
      limit: "Fatigue, weak feedback, and pauses between practice sessions.",
      summary: "Illustrated loop: practice leads to feedback, feedback to adjustment, adjustment to further practice.",
      description: "A loop follows practice to feedback to adjustment and back to practice.",
      drawing: [
        line("M398 75C478 72 528 113 520 149M517 145L520 151L526 146"),
        line("M461 210C394 261 235 261 167 210M174 211L165 211L169 218"),
        line("M100 149C92 112 143 72 222 75M216 70L224 74L216 79"),
        box(222, 48, 176, 45, "Practice"), box(441, 149, 166, 45, "Feedback"), box(13, 149, 166, 45, "Adjustment"),
        `<circle class="vs-gfx-core" cx="310" cy="162" r="25"/>`, label(310, 168, "↻", "vs-gfx-core-text"),
      ].join(""),
    },
    flow: {
      input: "What happens when a note is published?", meaning: "arrows: next step",
      limit: "Revisions after publication and the different people who may approve it.",
      summary: "Illustrated flow: draft, review, publish and archive, in sequence.",
      description: "A flow shows draft followed by review, publish and archive.",
      drawing: [
        line("M157 143H178M299 143H320M441 143H462"),
        label(168, 135, "→", "vs-gfx-text"), label(310, 135, "→", "vs-gfx-text"), label(452, 135, "→", "vs-gfx-text"),
        box(25, 119, 132, 47, "Draft"), box(178, 119, 121, 47, "Review"),
        box(320, 119, 121, 47, "Publish", true), box(462, 119, 132, 47, "Archive"),
        label(310, 207, "WHAT HAPPENS NEXT?"),
      ].join(""),
    },
  };

  function showForm(name) {
    const form = forms[name];
    if (!form || !graph) return;
    for (const button of formButtons) button.setAttribute("aria-pressed", String(button.dataset.vsForm === name));
    formInput.innerHTML = `${form.input} <span class="vs-mode">as ${name}</span>`;
    graph.innerHTML = `<svg class="vs-gfx" viewBox="0 0 620 280" role="img" aria-label="${form.description}">${form.drawing}</svg>`;
    route.textContent = name[0].toUpperCase() + name.slice(1);
    meaning.textContent = `· ${form.meaning}`;
    limit.textContent = form.limit;
    summary.textContent = form.summary;
    centerDiagram(graph);
  }

  for (const button of formButtons) button.addEventListener("click", () => showForm(button.dataset.vsForm));
  showForm("matrix");
})();
